import 'dart:async';
import 'dart:convert';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'account_owner_test.dart' show accountA, accountData, fuelReply;
import 'review_regression_test.dart' show TestChannel;
import 'operations_test.dart' show journal, operation;

Json world() => {
  'session_id': 'room',
  'epoch': 'e',
  'revision': '0',
  'receipt_cursor': '0',
  'server_time': '2026-10-25T00:00:00Z',
  'state': {'value': 1},
};

void main() {
  test(
    'the owner reconciles a pending persistent action while the game stays connected',
    () async {
      var posts = 0, coins = 100;
      Json? receipt;
      final channel = TestChannel();
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: journal({}),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA, coins));
          if (request.url.path.endsWith('/sessions'))
            return fuelReply({'session_id': 'room'});
          if (request.url.path.endsWith('/operations'))
            return fuelReply(
              receipt == null || request.url.queryParameters['after'] == '1'
                  ? []
                  : [receipt],
            );
          if (request.url.path.endsWith('/actions')) {
            posts++;
            coins++;
            final data = jsonDecode(request.body) as Json;
            receipt = operation(data['id'] as String, 1, source: 'public');
            throw http.ClientException('committed, lost body');
          }
          if (request.url.path.contains('/operations/'))
            return fuelReply(receipt);
          return fuelReply(world());
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client, socketFactory: (_, _) => channel);
      await game.create('solo');
      channel.emit('live', '1');
      await expectLater(
        client.executeAction(FuelAction('buy', {})),
        throwsA(isA<http.ClientException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5300));
      expect(await client.pendingActions(), isEmpty);
      expect(posts, 1);
      expect(coins, 101);
      await game.dispose();
      client.close();
    },
  );
  test(
    'an invalidated game avatar ends the session instead of retrying forever',
    () async {
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/sessions'))
            return fuelReply({'session_id': 'room'});
          return http.Response(
            '{"wire_version":1,"error":"avatar_retired"}',
            400,
          );
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client);
      await expectLater(game.create('solo'), throwsA(isA<FuelException>()));
      expect(game.status, FuelGameStatus.lost);
      await game.dispose();
      client.close();
    },
  );
  test(
    'one owner connects with native headers and fences input and private state across identity changes',
    () async {
      final channel = TestChannel();
      final proof = FuelCredential.create();
      final client = FuelClient(
        Uri.parse('https://game.example/title/fuel/v1'),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/sessions'))
            return fuelReply({
              'session_id': 'room',
              'epoch': 'e',
              'code': 'ACDEFH',
            });
          if (request.url.path.endsWith('/operations')) return fuelReply([]);
          return fuelReply(world());
        }),
      )..credential = proof;
      await client.refreshAccount();
      final game = FuelGameController(
        client,
        socketFactory: (uri, headers) {
          expect(uri.path, '/title/fuel/v1/stream');
          expect(uri.scheme, 'wss');
          expect(uri.queryParameters['account_id'], accountA);
          expect('$uri', isNot(contains(proof.secret)));
          expect(headers['Authorization'], 'Fuel ${proof.id}:${proof.secret}');
          return channel;
        },
      );
      await game.create('solo');
      channel.emit('owned', '1');
      expect(game.status, FuelGameStatus.online);
      expect(game.current!.state['private'], 'owned');
      game.input({'type': 'move', 'x': 1});
      game.suspend();
      expect(game.status, FuelGameStatus.suspended);
      expect(() => game.input({'type': 'move'}), throwsA(isA<FuelException>()));
      client.credential = FuelCredential.create();
      expect(game.current, isNull);
      expect(game.sessionId, isNull);
      await game.dispose();
      client.close();
    },
  );

  test(
    'unknown create outcome is recovered through membership without making another room',
    () async {
      var posts = 0;
      final channel = TestChannel();
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/sessions/mine'))
            return fuelReply([
              {'session_id': 'room', 'mode': 'solo', 'code': 'ACDEFH'},
            ]);
          if (request.url.path.endsWith('/sessions')) {
            posts++;
            throw StateError('committed room, lost response');
          }
          return fuelReply(world());
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client, socketFactory: (_, _) => channel);
      await expectLater(game.create('solo'), throwsStateError);
      await game.recoverRoom();
      channel.emit('recovered', '0');
      expect(posts, 1);
      expect(game.sessionId, 'room');
      expect(game.status, FuelGameStatus.online);
      await game.dispose();
      client.close();
    },
  );

  test('late admission cannot select a room after disposal', () async {
    final response = Completer();
    var sockets = 0;
    final client = FuelClient(
      Uri.parse('https://game.example'),
      httpClient: MockClient(
        (request) async => request.url.path.endsWith('/account')
            ? fuelReply(accountData(accountA))
            : await response.future,
      ),
    );
    await client.refreshAccount();
    final game = FuelGameController(
      client,
      socketFactory: (_, _) {
        sockets++;
        return TestChannel();
      },
    );
    final created = game.create('solo');
    final assertion = expectLater(created, throwsA(isA<FuelException>()));
    await game.dispose();
    response.complete(fuelReply({'session_id': 'room'}));
    await assertion;
    expect(sockets, 0);
    expect(game.sessionId, isNull);
    client.close();
  });
}
