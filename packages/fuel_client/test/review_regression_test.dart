import 'dart:async';
import 'dart:convert';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'client_test.dart' show TestVault;

FuelSnapshot snapshot(String secret, {String revision = '0'}) =>
    FuelSnapshot.fromJson({
      'session_id': 'room',
      'epoch': 'e',
      'revision': revision,
      'state': {'private': secret},
      'server_time': '2026-10-25T00:00:00Z',
    });

void main() {
  test(
    'a realtime connection rejected before ready still closes its channel',
    () async {
      final client = FuelClient(Uri.parse('https://game.example'));
      final session = FuelSession(client)..select('room');
      client.close();
      final channel = TestChannel();
      final realtime = FuelRealtime(channel, session);
      await expectLater(realtime.connect(), throwsA(isA<FuelException>()));
      await channel.sink.done.timeout(const Duration(milliseconds: 50));
      await realtime.close();
      await session.dispose();
    },
  );

  test(
    'a reentrant identity change during snapshot delivery cannot restore readiness',
    () async {
      final client = FuelClient(Uri.parse('https://game.example'));
      final session = FuelSession(client)..select('room');
      final listener = session.snapshots.listen(
        (_) => client.credential = FuelCredential.create(),
      );
      final channel = TestChannel();
      final realtime = FuelRealtime(channel, session);
      await realtime.connect();
      channel.emit('old identity', '1');
      expect(realtime.generation, isNull);
      expect(session.current, isNull);
      await realtime.close();
      await listener.cancel();
      await session.dispose();
      client.close();
    },
  );
  test(
    'realtime cannot reconnect during a pending browser identity change',
    () async {
      final response = Completer<http.Response>();
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((_) => response.future),
      );
      final session = FuelSession(client)..select('room');
      final operation = client.activateTransfer();
      final channel = TestChannel();
      final realtime = FuelRealtime(channel, session);
      await expectLater(
        realtime.connect(),
        throwsA(
          isA<FuelException>().having(
            (e) => e.code,
            'code',
            'identity_changing',
          ),
        ),
      );
      channel.emit('old account', '0');
      expect(session.current, isNull);
      expect(() => realtime.input({'x': 1}), throwsA(isA<FuelException>()));
      response.complete(http.Response('{"wire_version":1,"data":{}}', 200));
      await operation;
      await realtime.close();
      await session.dispose();
      client.close();
    },
  );

  for (final path in ['activate', 'switch']) {
    test(
      'uncertain browser $path response clears old projection and socket',
      () async {
        final client = FuelClient(
          Uri.parse('https://game.example'),
          httpClient: MockClient.streaming(
            (_, _) async => http.StreamedResponse(
              Stream<List<int>>.error(
                StateError('body lost after cookie header'),
              ),
              200,
            ),
          ),
        );
        final session = FuelSession(client)..select('room');
        final channel = TestChannel();
        final realtime = FuelRealtime(channel, session);
        await realtime.connect();
        channel.emit('old account', '0');
        await expectLater(
          path == 'activate'
              ? client.activateTransfer()
              : client.switchPrevious(),
          throwsStateError,
        );
        expect(session.current, isNull);
        expect(realtime.generation, isNull);
        await realtime.close();
        await session.dispose();
        client.close();
      },
    );
  }
  test('identity notification preserves lifecycle suspension', () async {
    final client = FuelClient(Uri.parse('https://game.example'));
    final session = FuelSession(client)..select('room');
    session.accept(snapshot('old'));
    session.suspend();
    client.credential = FuelCredential.create();
    expect(session.status, FuelSessionStatus.suspended);
    expect(session.current, isNull);
    await session.dispose();
    client.close();
  });
  test(
    'browser identity transition fences concurrent requests and completion while backgrounded',
    () async {
      final response = Completer<http.Response>();
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((_) => response.future),
      );
      final session = FuelSession(client)..select('room');
      final operation = client.activateTransfer();
      final blocked = client.request('GET', 'progress');
      session.suspend();
      response.complete(
        http.Response('{"wire_version":1,"data":{"account_id":"new"}}', 200),
      );
      await expectLater(
        blocked,
        throwsA(
          isA<FuelException>().having(
            (e) => e.code,
            'code',
            'identity_changing',
          ),
        ),
      );
      await operation;
      expect(session.status, FuelSessionStatus.suspended);
      await session.dispose();
      client.close();
    },
  );
  test(
    'single-record vault atomically keeps both accounts across failure and restart',
    () async {
      String? stored;
      var fail = false;
      final vault = RecordCredentialVault(
        read: () async => stored,
        write: (value) async {
          if (fail) throw StateError('storage failed');
          stored = value;
        },
      );
      final a = FuelCredential.create(), b = FuelCredential.create();
      await vault.write('active', a);
      await vault.activate(b);
      fail = true;
      await expectLater(vault.activate(a), throwsStateError);
      final restarted = RecordCredentialVault(
        read: () async => stored,
        write: (value) async {
          stored = value;
        },
      );
      expect((await restarted.read('active'))!.id, b.id);
      expect((await restarted.read('previous'))!.id, a.id);
      stored = 'corrupt';
      await expectLater(restarted.read('active'), throwsFormatException);
    },
  );
  test(
    'repeated native activation preserves previous and failed atomic swap loses nothing',
    () async {
      final a = FuelCredential.create(), b = FuelCredential.create();
      final vault = TestVault()..slots.addAll({'active': a, 'candidate': b});
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient(
          (_) async => http.Response(
            '{"wire_version":1,"data":{"status":"linked","account_id":"b"}}',
            200,
          ),
        ),
      )..credential = a;
      await client.activateTransfer(vault: vault);
      await client.activateTransfer(vault: vault);
      expect(vault.slots['previous']!.id, a.id);
      vault.failActivate = true;
      await expectLater(client.switchPrevious(vault: vault), throwsStateError);
      expect(vault.slots['active']!.id, b.id);
      expect(vault.slots['previous']!.id, a.id);
      vault.failActivate = false;
      await client.switchPrevious(vault: vault);
      expect(vault.slots['active']!.id, a.id);
      client.close();
    },
  );

  test('new completed or expired transfer uses a fresh candidate', () async {
    final a = FuelCredential.create();
    final vault = TestVault()..slots.addAll({'active': a, 'candidate': a});
    var status = 'linked';
    final client = FuelClient(
      Uri.parse('https://game.example'),
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'wire_version': 1,
            'data': {'status': status},
          }),
          200,
        ),
      ),
    )..credential = a;
    await client.prepareTransfer(vault: vault);
    expect(vault.slots['candidate']!.id, isNot(a.id));
    final pending = vault.slots['candidate']!.id;
    status = 'expired';
    await client.prepareTransfer(vault: vault);
    expect(vault.slots['candidate']!.id, isNot(pending));
    client.close();
  });

  test(
    'identity change clears the old private projection and its cursor immediately',
    () async {
      final client = FuelClient(Uri.parse('https://game.example'));
      final session = FuelSession(client)..select('room');
      session.accept(snapshot('alice', revision: '5'));
      client.credential = FuelCredential.create();
      expect(session.current, isNull);
      session.accept(snapshot('bob'));
      expect(session.current!.state['private'], 'bob');
      await session.dispose();
      client.close();
    },
  );

  test(
    'same revision confirms resume without replaying a presentation event',
    () async {
      final client = FuelClient(Uri.parse('https://game.example'));
      final session = FuelSession(client)..select('room');
      var count = 0;
      session.snapshots.listen((_) => count++);
      session.accept(snapshot('a'));
      session.suspend();
      session.resume();
      session.accept(snapshot('a'));
      expect(session.status, FuelSessionStatus.connected);
      expect(count, 1);
      await session.dispose();
      client.close();
    },
  );

  for (final transition in ['suspend', 'reselect', 'identity']) {
    test('realtime cannot cross $transition generation', () async {
      final client = FuelClient(Uri.parse('https://game.example'));
      final session = FuelSession(client)..select('room');
      final channel = TestChannel();
      final realtime = FuelRealtime(channel, session);
      await realtime.connect();
      channel.emit('alice', '0');
      if (transition == 'suspend') session.suspend();
      if (transition == 'reselect') session.select('room');
      if (transition == 'identity') client.credential = FuelCredential.create();
      channel.emit('stale', '1');
      expect(session.current?.state['private'], isNot('stale'));
      expect(() => realtime.input({'move': 1}), throwsA(isA<FuelException>()));
      await realtime.close();
      await session.dispose();
      client.close();
    });
  }

  test(
    'normal socket completion reports disconnect and disables input',
    () async {
      final client = FuelClient(Uri.parse('https://game.example'));
      final session = FuelSession(client)..select('room');
      final channel = TestChannel();
      final realtime = FuelRealtime(channel, session);
      final errors = <Object>[];
      await realtime.connect(onError: errors.add);
      channel.emit('a', '0');
      await channel.inbound.close();
      expect(errors, isNotEmpty);
      expect(realtime.generation, isNull);
      expect(() => realtime.input({'move': 1}), throwsA(isA<FuelException>()));
      await realtime.close();
      await session.dispose();
      client.close();
    },
  );
}

class TestChannel implements WebSocketChannel {
  final inbound = StreamController<dynamic>.broadcast(sync: true);
  @override
  late final TestSink sink = TestSink();
  void emit(String secret, String revision) => inbound.add(
    jsonEncode({
      'wire_version': 1,
      'generation': 'g',
      'data': {
        'session_id': 'room',
        'epoch': 'e',
        'revision': revision,
        'state': {'private': secret},
        'server_time': '2026-10-25T00:00:00Z',
      },
    }),
  );
  @override
  Stream<dynamic> get stream => inbound.stream;
  @override
  Future<void> get ready async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestSink implements WebSocketSink {
  final messages = <dynamic>[];
  final _done = Completer<void>();
  @override
  void add(dynamic value) => messages.add(value);
  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
