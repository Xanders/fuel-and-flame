import 'dart:async';
import 'dart:convert';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('a command is immutable even when nested caller data changes', () {
    final original = <String, dynamic>{
      'move': {'x': 1},
    };
    final command = FuelCommand('id', 'epoch', BigInt.zero, original);
    (original['move'] as Map)['x'] = 2;
    (command.action['move'] as Map)['x'] = 3;
    expect(command.toJson()['action']['move']['x'], 1);
  });
  test(
    'native bootstrap saves credentials before any network write and preserves them after 503',
    () async {
      final vault = TestVault();
      var calls = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          calls++;
          expect(vault.slots['active'], isNotNull);
          expect(
            request.headers['Authorization'],
            contains(vault.slots['active']!.secret),
          );
          return http.Response('{"wire_version":1,"error":"unavailable"}', 503);
        }),
      );
      await expectLater(
        client.bootstrapNative(vault),
        throwsA(isA<FuelException>()),
      );
      final id = vault.slots['active']!.id;
      await expectLater(
        client.bootstrapNative(vault),
        throwsA(isA<FuelException>()),
      );
      expect(vault.slots['active']!.id, id);
      expect(calls, 2);
      client.close();
    },
  );
  test('retries preserve exact semantic command and explicit ID', () async {
    final requests = <String>[];
    final client = FuelClient(
      Uri.parse('https://game.example'),
      httpClient: MockClient((request) async {
        requests.add(request.body);
        if (requests.length == 1) throw http.ClientException('offline');
        return http.Response(
          jsonEncode({
            'wire_version': 1,
            'data': {'status': 'ok'},
          }),
          200,
        );
      }),
    );
    final command = FuelCommand('move-1', 'epoch', BigInt.zero, {'amount': 1});
    await expectLater(
      client.command('room', command),
      throwsA(isA<http.ClientException>()),
    );
    await client.command('room', command);
    expect(requests[0], requests[1]);
    expect(jsonDecode(requests[1])['id'], 'move-1');
    client.close();
  });

  test('late poll completion cannot publish after changing session', () async {
    final pending = Completer<http.Response>();
    final transport = MockClient((_) => pending.future);
    final client = FuelClient(
      Uri.parse('https://game.example'),
      httpClient: transport,
    );
    final session = FuelSession(client);
    session.select('room');
    final values = <FuelSnapshot>[];
    session.snapshots.listen(values.add);
    final poll = session.poll();
    session.select('other');
    pending.complete(
      http.Response(
        jsonEncode({
          'wire_version': 1,
          'data': {
            'session_id': 'room',
            'epoch': 'e',
            'revision': '9007199254740993',
            'state': {'value': 1},
            'server_time': '2026-10-25T00:00:00Z',
            'last_input': '-1',
          },
        }),
        200,
      ),
    );
    await poll;
    expect(values, isEmpty);
    await session.dispose();
    client.close();
  });

  test(
    'one poll in flight and explicit session_lost without guest replacement',
    () async {
      var calls = 0;
      final response = Completer<http.Response>();
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((_) {
          calls++;
          return response.future;
        }),
      );
      final session = FuelSession(client)..select('room');
      final one = session.poll();
      final two = session.poll();
      response.complete(
        http.Response('{"wire_version":1,"error":"session_lost"}', 409),
      );
      await expectLater(one, throwsA(isA<FuelException>()));
      await expectLater(two, throwsA(isA<FuelException>()));
      expect(calls, 1);
      expect(session.status, FuelSessionStatus.lost);
      await session.dispose();
      client.close();
    },
  );

  test('transfer and invite normalization reject Unicode lookalikes', () {
    expect(normalizeCode('acd- efh'), 'ACDEFH');
    expect(() => normalizeCode('АCDEFH'), throwsFormatException);
    expect(
      inviteCode(Uri.parse('https://game.example/join?invite=ACDEFH')),
      'ACDEFH',
    );
  });
}

class TestVault extends MemoryFuelJournal implements CredentialVault {
  @override
  bool get durable => true;
  final slots = <String, FuelCredential>{};
  bool failActivate = false;
  Future<void> activate(
    FuelCredential value, {
    String? accountId,
    String? selectionId,
  }) async {
    if (failActivate) throw StateError('storage failed');
    if (selectionId != null)
      await completeSelection(selectionId, {
        'kind': 'active',
        'account_id': accountId,
      });
    final old = slots['active'];
    if (old != null && old.id != value.id) slots['previous'] = old;
    slots['active'] = value;
    await writeEntry('identity', {
      'kind': 'active',
      if (accountId != null) 'account_id': accountId,
    });
  }

  @override
  Future<void> completeDeletion(
    String accountId,
    List<String> removedBindings,
  ) async {
    slots.removeWhere((_, proof) => removedBindings.contains(proof.id));
    await super.completeDeletion(accountId, removedBindings);
  }

  @override
  Future<FuelCredential?> read(String slot) async {
    if (!slot.startsWith('binding:')) return slots[slot];
    for (final proof in slots.values) {
      if (proof.id == slot.substring(8)) return proof;
    }
    return null;
  }

  @override
  Future<void> write(String slot, FuelCredential credential) async {
    slots[slot] = credential;
  }
}
