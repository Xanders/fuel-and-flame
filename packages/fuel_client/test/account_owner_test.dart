import 'dart:async';
import 'dart:convert';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'client_test.dart' show TestVault;

const accountA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const accountB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Json accountData(String id, [int coins = 1]) => {
  'account_id': id,
  'progress': {'coins': coins},
  'analytics_enabled': true,
  'analytics_revision': '0',
  'server_time': 1800000000,
};
http.Response fuelReply(dynamic data, {String? actor}) => http.Response(
  jsonEncode({'wire_version': 1, 'data': data}),
  200,
  headers: {if (actor != null) 'X-Fuel-Account': actor},
);

void main() {
  test(
    'revocation clears private account and session state without generating another guest',
    () async {
      var reads = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient(
          (_) async => ++reads == 1
              ? fuelReply(accountData(accountA))
              : http.Response('{"wire_version":1,"error":"unauthorized"}', 401),
        ),
      );
      await client.refreshAccount();
      final session = FuelSession(client)..select('room');
      session.accept(
        FuelSnapshot.fromJson({
          'session_id': 'room',
          'epoch': 'e',
          'revision': '0',
          'server_time': '2026-10-25T00:00:00Z',
          'state': {'private': 'old'},
        }),
      );
      await expectLater(
        client.postChat('global', '', 'hello'),
        throwsA(isA<FuelException>()),
      );
      expect(client.account, isNull);
      expect(session.current, isNull);
      expect(client.accountStatus, FuelAccountStatus.unauthorized);
      expect(reads, 2);
      await session.dispose();
      client.close();
    },
  );
  test(
    'native bootstrap admits one identity before any storage await and owns its profile',
    () async {
      final vault = BarrierVault();
      final credential = FuelCredential.create();
      vault.slots['active'] = credential;
      var calls = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          calls++;
          return request.url.path.endsWith('auth/bootstrap')
              ? fuelReply({'account_id': accountA})
              : fuelReply(accountData(accountA));
        }),
      );
      final first = client.bootstrapNative(vault);
      await expectLater(
        client.bootstrapNative(TestVault()),
        throwsA(
          isA<FuelException>().having(
            (e) => e.code,
            'code',
            'identity_changing',
          ),
        ),
      );
      expect(calls, 0);
      vault.barrier.complete(credential);
      await first;
      expect(client.account!.id, accountA);
      expect(calls, 2);
      client.close();
    },
  );

  test('owns account state and resolves the configured API prefix', () async {
    final paths = <String>[];
    final client = FuelClient(
      Uri.parse('https://game.example/title/fuel/v1'),
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        return fuelReply(accountData(accountA));
      }),
    );
    final account = await client.refreshAccount();
    expect(paths, ['/title/fuel/v1/account']);
    expect(client.account!.id, accountA);
    expect(client.accountStatus, FuelAccountStatus.ready);
    (account.progress as Json)['coins'] = 999;
    expect((client.account!.progress as Json)['coins'], 1);
    client.close();
  });

  test(
    'single-flights profile reads and rejects a late old identity response',
    () async {
      final a = Completer<http.Response>(), b = Completer<http.Response>();
      var calls = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((_) => ++calls == 1 ? a.future : b.future),
      );
      final old = client.refreshAccount();
      expect(identical(client.refreshAccount(), old), isTrue);
      client.credential = FuelCredential.create();
      final fresh = client.refreshAccount();
      b.complete(fuelReply(accountData(accountB)));
      await fresh;
      a.complete(fuelReply(accountData(accountA)));
      await expectLater(
        old,
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      expect(client.account!.id, accountB);
      expect(client.accountStatus, FuelAccountStatus.ready);
      expect(calls, 2);
      client.close();
    },
  );

  test(
    'reentrant identity selection cannot return or restore the old account',
    () async {
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((_) async => fuelReply(accountData(accountA))),
      );
      final listener = client.updates.listen((_) {
        if (client.account?.id == accountA)
          client.credential = FuelCredential.create();
      });
      await expectLater(
        client.refreshAccount(),
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      expect(client.account, isNull);
      await listener.cancel();
      client.close();
    },
  );

  test('closing during a profile request cannot publish later data', () async {
    final response = Completer<http.Response>();
    final client = FuelClient(
      Uri.parse('https://game.example'),
      httpClient: MockClient((_) => response.future),
    );
    final operation = client.refreshAccount();
    client.close();
    response.complete(fuelReply(accountData(accountA)));
    await expectLater(operation, throwsA(isA<FuelException>()));
    expect(client.account, isNull);
    expect(client.accountStatus, FuelAccountStatus.closed);
  });

  test(
    'relative API requests cannot send credentials to another host or prefix',
    () async {
      var calls = 0;
      final client = FuelClient(
        Uri.parse('https://game.example/title/fuel/v1/'),
        httpClient: MockClient((_) async {
          calls++;
          return fuelReply({});
        }),
      )..credential = FuelCredential.create();
      for (final path in [
        'https://evil.example/read',
        '//evil.example/read',
        '../other',
        '/other',
      ]) {
        await expectLater(client.request('GET', path), throwsArgumentError);
      }
      expect(calls, 0);
      client.close();
    },
  );
}

class BarrierVault extends TestVault {
  final barrier = Completer<FuelCredential?>();
  @override
  Future<FuelCredential?> read(String slot) =>
      slot == 'active' ? barrier.future : super.read(slot);
}
