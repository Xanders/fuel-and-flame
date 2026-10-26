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
