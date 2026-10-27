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
  test('a replaced connection yields until an explicit reconnect', () async {
    final channels = <TestChannel>[];
    var recoveryOffline = false;
    final client = FuelClient(
      Uri.parse('https://game.example'),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/account')) {
          return fuelReply(accountData(accountA));
        }
        if (request.url.path.endsWith('/operations')) return fuelReply([]);
        if (request.url.path.endsWith('/sessions/mine')) {
          if (recoveryOffline) throw http.ClientException('offline');
          return fuelReply([
            {'session_id': 'room'},
          ]);
        }
        if (request.url.path.endsWith('/sessions')) {
          return fuelReply({'session_id': 'room'});
        }
        return fuelReply(world());
      }),
    );
    await client.refreshAccount();
    final game = FuelGameController(
      client,
      socketFactory: (_, _) {
        final channel = TestChannel();
        channels.add(channel);
        return channel;
      },
    );
    try {
      await game.create('solo');
      channels.single.emit('retained board', '1');
      expect(game.status, FuelGameStatus.online);
      expect(game.current!.state['private'], 'retained board');
      channels.single.inbound.add(
        jsonEncode({'wire_version': 1, 'error': 'connection_replaced'}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(channels, hasLength(1));
      expect(game.status, FuelGameStatus.offline);
      expect((game.lastError as FuelException).code, 'connection_replaced');
      expect(game.sessionId, 'room');
      expect(game.current!.state['private'], 'retained board');
      final retained = game.current, cause = game.lastError;
      await game.recoverRoom();
      expect(channels, hasLength(1));
      expect(game.current, same(retained));
      expect(game.status, FuelGameStatus.offline);
      expect(game.lastError, same(cause));
      recoveryOffline = true;
      await expectLater(
        game.recoverRoom(),
        throwsA(isA<http.ClientException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(channels, hasLength(1));
      expect(game.status, FuelGameStatus.offline);
      expect(game.lastError, same(cause));
      await game.connect();
      channels.last.emit('same room', '2');
      expect(channels, hasLength(2));
      expect(game.status, FuelGameStatus.online);
      expect(game.sessionId, 'room');
      channels.last.inbound.addError(http.ClientException('ordinary outage'));
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(channels, hasLength(3));
      channels.last.emit('ordinary recovery', '3');
      expect(game.status, FuelGameStatus.online);
    } finally {
      await game.dispose();
      client.close();
    }
  });

  for (final reset in [
    'leave',
    'empty recovery',
    'identity',
    'different room',
  ]) {
    test('a displaced connection does not survive $reset', () async {
      final channels = <TestChannel>[];
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account')) {
            return fuelReply(accountData(accountA));
          }
          if (request.url.path.endsWith('/operations')) return fuelReply([]);
          if (request.url.path.endsWith('/sessions/mine')) {
            return fuelReply(
              reset == 'different room'
                  ? [
                      {'session_id': 'new-room'},
                    ]
                  : [],
            );
          }
          if (request.url.path.endsWith('/sessions')) {
            return fuelReply({'session_id': 'room'});
          }
          if (request.url.path.endsWith('/sessions/new-room')) {
            return fuelReply({...world(), 'session_id': 'new-room'});
          }
          return fuelReply(world());
        }),
      );
      final game = FuelGameController(
        client,
        socketFactory: (_, _) {
          final channel = TestChannel();
          channels.add(channel);
          return channel;
        },
      );
      try {
        await client.refreshAccount();
        await game.create('solo');
        channels.single.emit('old board', '1');
        channels.single.inbound.add(
          jsonEncode({'wire_version': 1, 'error': 'connection_replaced'}),
        );
        expect(game.status, FuelGameStatus.offline);
        if (reset == 'leave') await game.leave();
        if (reset == 'empty recovery') await game.recoverRoom();
        if (reset == 'identity') {
          game.suspend();
          client.credential = FuelCredential.create();
          await client.refreshAccount();
          await game.resume();
        }
        if (reset == 'different room') {
          await game.recoverRoom();
          expect(game.sessionId, 'new-room');
        } else {
          expect(game.sessionId, isNull);
          expect(game.current, isNull);
          await game.create('solo');
        }
        void emitNewBoard(String revision) => channels.last.inbound.add(
          jsonEncode({
            'wire_version': 1,
            'generation': 'g',
            'data': {
              ...world(),
              'session_id': game.sessionId,
              'revision': revision,
              'state': {'private': 'new board'},
            },
          }),
        );
        emitNewBoard('1');
        game.suspend();
        await game.resume();
        expect(channels, hasLength(3));
        emitNewBoard('2');
        expect(game.status, FuelGameStatus.online);
        expect(game.lastError, isNull);
      } finally {
        await game.dispose();
        client.close();
      }
    });
  }

  final suspendedCalls = <String, Future<dynamic> Function(FuelGameController)>{
    'create': (game) => game.create('solo'),
    'join code': (game) => game.joinCode('ACDEFH'),
    'join public': (game) => game.joinPublic('room'),
    'match': (game) => game.match('solo', ticketId: 'ticket'),
    'recover room': (game) => game.recoverRoom(),
    'ready': (game) => game.ready(),
    'leave': (game) => game.leave(),
  };
  for (final entry in suspendedCalls.entries)
    test(
      'suspended ${entry.key} preserves lifecycle without requests',
      () async {
        var requests = 0;
        final client = FuelClient(
          Uri.parse('https://game.example'),
          httpClient: MockClient((_) async {
            requests++;
            return fuelReply([]);
          }),
        );
        final game = FuelGameController(client);
        game.suspend();
        await expectLater(
          entry.value(game),
          throwsA(
            isA<FuelException>().having(
              (e) => e.code,
              'code',
              'inactive_session',
            ),
          ),
        );
        expect(requests, 0);
        expect(game.status, FuelGameStatus.suspended);
        expect(game.session.status, FuelSessionStatus.suspended);
        await game.dispose();
        client.close();
      },
    );

  test(
    'a match response after suspension cannot select a room or reopen a socket',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var sockets = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((_) async {
          entered.complete();
          await release.future;
          return fuelReply({'status': 'matched', 'session_id': 'room'});
        }),
      );
      final game = FuelGameController(
        client,
        socketFactory: (_, _) {
          sockets++;
          return TestChannel();
        },
      );
      final matched = game.match('solo', ticketId: 'ticket');
      await entered.future;
      game.suspend();
      final assertion = expectLater(
        matched,
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      release.complete();
      await assertion;
      expect(game.status, FuelGameStatus.suspended);
      expect(game.session.status, FuelSessionStatus.suspended);
      expect(game.sessionId, isNull);
      expect(sockets, 0);
      await game.dispose();
      client.close();
    },
  );

  test(
    'empty membership recovery clears the old room before a deliberate new session',
    () async {
      var creates = 0;
      final channels = <TestChannel>[];
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/sessions/mine') ||
              request.url.path.endsWith('/operations'))
            return fuelReply([]);
          if (request.url.path.endsWith('/sessions')) {
            creates++;
            return fuelReply({'session_id': 'room'});
          }
          return fuelReply(world());
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(
        client,
        socketFactory: (_, _) {
          final next = TestChannel();
          channels.add(next);
          return next;
        },
      );
      await game.create('solo');
      channels.single.emit('private old state', '0');
      await game.recoverRoom();
      expect(game.sessionId, isNull);
      expect(game.current, isNull);
      expect(game.mode, isEmpty);
      expect(game.roomCode, isEmpty);
      expect(game.status, FuelGameStatus.idle);
      await game.create('solo');
      expect(creates, 2);
      await game.dispose();
      client.close();
    },
  );

  test(
    'suspending during login cannot open a session socket until resume',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var sockets = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: journal({}),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/prepare')) {
            entered.complete();
            await release.future;
          }
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/operations')) return fuelReply([]);
          if (request.url.path.endsWith('/sessions/mine'))
            return fuelReply([
              {'session_id': 'room'},
            ]);
          if (request.url.path.endsWith('/sessions/room'))
            return fuelReply(world());
          return fuelReply({'account_id': accountA});
        }),
      );
      final game = FuelGameController(
        client,
        socketFactory: (_, _) {
          sockets++;
          return TestChannel();
        },
      );
      final started = game.start();
      await entered.future;
      game.suspend();
      final assertion = expectLater(
        started,
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      release.complete();
      await assertion;
      expect(game.status, FuelGameStatus.suspended);
      expect(game.session.status, FuelSessionStatus.suspended);
      expect(sockets, 0);
      await game.dispose();
      client.close();
    },
  );

  for (final failedPath in ['operations', 'sessions/mine'])
    test(
      'startup exposes a retry state when $failedPath fails after login',
      () async {
        final client = FuelClient(
          Uri.parse('https://game.example'),
          journal: journal({}),
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/$failedPath'))
              throw http.ClientException('offline');
            if (request.url.path.endsWith('/account'))
              return fuelReply(accountData(accountA));
            if (request.url.path.endsWith('/operations') ||
                request.url.path.endsWith('/sessions/mine'))
              return fuelReply([]);
            return fuelReply({'account_id': accountA});
          }),
        );
        final game = FuelGameController(client);
        await expectLater(game.start(), throwsA(isA<http.ClientException>()));
        expect(client.account?.id, accountA);
        expect(game.status, FuelGameStatus.offline);
        await game.dispose();
        client.close();
      },
    );

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
