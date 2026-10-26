import 'dart:async';
import 'dart:convert';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'account_owner_test.dart' show accountA, accountData, fuelReply;
import 'operations_test.dart' show journal;
import 'review_regression_test.dart' show TestChannel;

Json snapshot({String epoch = 'e', String revision = '0'}) => {
  'session_id': 'room',
  'epoch': epoch,
  'revision': revision,
  'server_time': '2026-10-27T00:00:00Z',
  'state': {'value': 1},
};

void select(
  FuelGameController game, {
  String epoch = 'e',
  String revision = '0',
}) {
  game.session.select('room');
  game.session.accept(
    FuelSnapshot.fromJson(snapshot(epoch: epoch, revision: revision)),
  );
}

void main() {
  test(
    'a command receiving definitive room loss publishes loss and retires its exact intent',
    () async {
      final storage = journal({});
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          return http.Response(
            '{"wire_version":1,"error":"session_lost"}',
            409,
          );
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client);
      select(game);
      try {
        await expectLater(
          game.command({'type': 'move'}),
          throwsA(
            isA<FuelException>().having((e) => e.code, 'code', 'session_lost'),
          ),
        );
        expect(game.status, FuelGameStatus.lost);
        expect(game.pendingCommand, isNull);
        expect(
          await storage.readEntry('account:$accountA:session_command'),
          isNull,
        );
      } finally {
        await game.dispose();
        client.close();
      }
    },
  );

  test(
    'SDKCMD-R1-01: a rejected old action does not prevent reconnecting a live room',
    () async {
      var posts = 0, sockets = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: journal({}),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/commands')) {
            if (++posts == 1) throw http.ClientException('offline');
            return http.Response(
              '{"wire_version":1,"error":"revision_conflict"}',
              409,
            );
          }
          return fuelReply(snapshot(revision: '3'));
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(
        client,
        socketFactory: (_, _) {
          sockets++;
          return TestChannel();
        },
      );
      select(game);
      try {
        await expectLater(
          game.command({'type': 'move'}),
          throwsA(isA<http.ClientException>()),
        );
        await game.connect();
        expect(sockets, 1);
        expect(game.session.status, isNot(FuelSessionStatus.lost));
        expect(game.current!.revision, BigInt.from(3));
        expect(game.pendingCommand, isNull);
      } finally {
        await game.dispose();
        client.close();
      }
    },
  );

  test(
    'SDKCMD-R1-02: another controller clearing the journal also clears the local pending projection',
    () async {
      final storage = journal({});
      var posts = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/commands')) {
            if (++posts == 1) throw http.ClientException('offline');
            return fuelReply(snapshot(revision: '1'));
          }
          return fuelReply(snapshot(revision: '1'));
        }),
      );
      await client.refreshAccount();
      final a = FuelGameController(client), b = FuelGameController(client);
      select(a);
      select(b);
      try {
        await expectLater(
          a.command({'type': 'move'}),
          throwsA(isA<http.ClientException>()),
        );
        await expectLater(
          b.command({'type': 'other'}),
          throwsA(isA<FuelException>()),
        );
        expect(b.pendingCommand, isNotNull);
        await a.retryCommand();
        await expectLater(
          b.retryCommand(),
          throwsA(
            isA<FuelException>().having((e) => e.code, 'code', 'not_found'),
          ),
        );
        expect(b.pendingCommand, isNull);
      } finally {
        await a.dispose();
        await b.dispose();
        client.close();
      }
    },
  );

  test(
    'SDKCMD-R1-03: confirmed reconnect loss retires its command and allows deliberate leave',
    () async {
      final storage = journal({});
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/commands'))
            throw http.ClientException('offline');
          if (request.url.path.endsWith('/operations')) return fuelReply([]);
          return http.Response(
            '{"wire_version":1,"error":"session_lost"}',
            409,
          );
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client);
      select(game);
      try {
        await expectLater(
          game.command({'type': 'move'}),
          throwsA(isA<http.ClientException>()),
        );
        await expectLater(game.connect(), throwsA(isA<FuelException>()));
        expect(game.status, FuelGameStatus.lost);
        expect(game.pendingCommand, isNull);
        await game.leave();
        expect(game.sessionId, isNull);
      } finally {
        await game.dispose();
        client.close();
      }
    },
  );

  test(
    'SDKCMD-R1-04: another live room never deletes the first rooms uncertain intent',
    () async {
      final bodies = <Json>[];
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: journal({}),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          bodies.add(jsonDecode(request.body) as Json);
          if (bodies.length == 1) throw http.ClientException('offline');
          return fuelReply(snapshot(revision: '1'));
        }),
      );
      await client.refreshAccount();
      final a = FuelGameController(client), b = FuelGameController(client);
      select(a);
      b.session.select('other');
      b.session.accept(
        FuelSnapshot.fromJson({...snapshot(), 'session_id': 'other'}),
      );
      try {
        await expectLater(
          a.command({'type': 'move'}),
          throwsA(isA<http.ClientException>()),
        );
        await expectLater(
          b.command({'type': 'other'}),
          throwsA(isA<FuelException>()),
        );
        await a.retryCommand();
        expect(bodies.last['id'], bodies.first['id']);
      } finally {
        await a.dispose();
        await b.dispose();
        client.close();
      }
    },
  );

  test(
    'reconnect reconciles the saved command before opening the selected room stream',
    () async {
      final storage = journal({}), bodies = <String>[];
      var sockets = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/commands')) {
            bodies.add(request.body);
            if (bodies.length == 1) throw http.ClientException('response lost');
            return fuelReply(snapshot(revision: '1'));
          }
          return fuelReply(snapshot(revision: '1'));
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(
        client,
        socketFactory: (_, _) {
          sockets++;
          expect(bodies, hasLength(2));
          return TestChannel();
        },
      );
      select(game);
      await expectLater(
        game.command({'type': 'move'}),
        throwsA(isA<http.ClientException>()),
      );
      await game.connect();
      expect(bodies[0], bodies[1]);
      expect(sockets, 1);
      expect(game.pendingCommand, isNull);
      await game.dispose();
      client.close();
    },
  );

  test(
    'definite stale-revision rejection releases intent and fetches current authority',
    () async {
      final bodies = <Json>[];
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: journal({}),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/commands')) {
            bodies.add(jsonDecode(request.body) as Json);
            if (bodies.length == 1)
              return http.Response(
                '{"wire_version":1,"error":"revision_conflict"}',
                409,
              );
            return fuelReply(snapshot(revision: '4'));
          }
          return fuelReply(snapshot(revision: '3'));
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client);
      select(game);
      await expectLater(
        game.command({'type': 'move'}),
        throwsA(
          isA<FuelException>().having(
            (e) => e.code,
            'code',
            'revision_conflict',
          ),
        ),
      );
      expect(game.pendingCommand, isNull);
      expect(game.current!.revision, BigInt.from(3));
      await game.command({'type': 'other'});
      expect(bodies[1]['revision'], '3');
      expect(bodies[1]['id'], isNot(bodies[0]['id']));
      await game.dispose();
      client.close();
    },
  );

  test(
    'an oversized command cannot leave a journal intent or block a smaller move',
    () async {
      final storage = journal({});
      var posts = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          posts++;
          return fuelReply(snapshot(revision: '1'));
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client);
      select(game);
      await expectLater(
        game.command({'value': 'x' * 65536}),
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'too_large'),
        ),
      );
      expect(
        await storage.readEntry('account:$accountA:session_command'),
        isNull,
      );
      await game.command({'type': 'move'});
      expect(posts, 1);
      await game.dispose();
      client.close();
    },
  );

  test(
    'known empty membership retires an old RAM intent and exposes loss before another run',
    () async {
      final storage = journal({});
      var posts = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/sessions/mine')) return fuelReply([]);
          posts++;
          throw http.ClientException('offline');
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client);
      select(game);
      await expectLater(
        game.command({'type': 'move'}),
        throwsA(isA<http.ClientException>()),
      );
      await game.recoverRoom();
      expect(game.status, FuelGameStatus.lost);
      expect(game.current, isNull);
      expect(game.pendingCommand, isNull);
      expect(
        await storage.readEntry('account:$accountA:session_command'),
        isNull,
      );
      expect(posts, 1);
      await game.dispose();
      client.close();
    },
  );

  test(
    'uncertain command survives client restart and retries exactly once with its original revision',
    () async {
      final disk = <String, String>{}, bodies = <String>[];
      var committed = false;
      FuelClient make() => FuelClient(
        Uri.parse('https://game.example'),
        journal: journal(disk),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/commands')) {
            bodies.add(request.body);
            expect(
              disk.values.any((text) => text.contains('session_command')),
              isTrue,
            );
            if (!committed) {
              committed = true;
              throw http.ClientException('committed, response lost');
            }
            return fuelReply(snapshot(revision: '1'));
          }
          return fuelReply([]);
        }),
      );
      final first = make();
      await first.refreshAccount();
      final game = FuelGameController(first);
      select(game);
      await expectLater(
        game.command({'type': 'move', 'cell': 3}),
        throwsA(isA<http.ClientException>()),
      );
      expect(game.pendingCommand, isNotNull);
      await expectLater(
        game.command({'type': 'move', 'cell': 4}),
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'pending_command'),
        ),
      );
      await game.dispose();
      first.close();
      final second = make();
      await second.refreshAccount();
      final reopened = FuelGameController(second);
      select(reopened, revision: '1');
      try {
        await reopened.retryCommand();
        expect(bodies, hasLength(2));
        expect(bodies[1], bodies[0]);
        expect((jsonDecode(bodies[1]) as Json)['revision'], '0');
        expect(reopened.pendingCommand, isNull);
        expect(
          await journal(disk).readEntry('account:$accountA:session_command'),
          isNull,
        );
      } finally {
        await reopened.dispose();
        second.close();
      }
    },
  );

  test(
    'a lost epoch discards its transient intent without sending it to a replacement run',
    () async {
      final storage = journal({});
      var posts = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          posts++;
          throw http.ClientException('offline');
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client);
      select(game);
      await expectLater(
        game.command({'type': 'move'}),
        throwsA(isA<http.ClientException>()),
      );
      select(game, epoch: 'new-epoch');
      await expectLater(
        game.retryCommand(),
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'session_lost'),
        ),
      );
      expect(posts, 1);
      expect(
        await storage.readEntry('account:$accountA:session_command'),
        isNull,
      );
      expect(game.pendingCommand, isNull);
      await game.dispose();
      client.close();
    },
  );

  test(
    'a late command reply cannot publish or erase another identity intent',
    () async {
      final storage = journal({});
      final entered = Completer<void>(), response = Completer<http.Response>();
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          entered.complete();
          return response.future;
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client);
      select(game);
      final pending = game.command({'type': 'move'});
      final assertion = expectLater(
        pending,
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await entered.future;
      client.credential = FuelCredential.create();
      response.complete(fuelReply(snapshot(revision: '1')));
      await assertion;
      expect(game.current, isNull);
      expect(
        await storage.readEntry('account:$accountA:session_command'),
        isNotNull,
      );
      await game.dispose();
      client.close();
    },
  );
}
