import 'dart:async';
import 'dart:convert';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'account_owner_test.dart' show accountA, accountData, fuelReply;
import 'game_test.dart' show world;
import 'review_regression_test.dart' show TestChannel;

http.Response saving() =>
    http.Response('{"wire_version":1,"error":"pending_result"}', 400);

void main() {
  for (final metadata in <Json>[
    {'saving_backlog': true},
    {'effect_error': 'conflict'},
    {},
  ]) {
    test('departure timeout respects the latest snapshot $metadata', () async {
      final client = FuelClient(
        Uri.parse('https://game.example'),
        timeout: const Duration(milliseconds: 120),
        httpClient: MockClient((request) async {
          if (request.method == 'POST') return saving();
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          return fuelReply(world());
        }),
      );
      await client.refreshAccount();
      final channel = TestChannel();
      final game = FuelGameController(client, socketFactory: (_, _) => channel)
        ..session.select('room');
      var injected = false;
      final subscription = game.updates.listen((_) {
        if (game.status != FuelGameStatus.saving || injected) return;
        injected = true;
        channel.inbound.add(
          jsonEncode({
            'wire_version': 1,
            'generation': 'g',
            'data': {...world(), 'revision': '2', ...metadata},
          }),
        );
      });
      try {
        await game.connect();
        channel.emit('before', '1');
        await expectLater(
          game.leave(),
          throwsA(
            isA<FuelException>().having(
              (e) => e.code,
              'code',
              'pending_result',
            ),
          ),
        );
        expect(injected, isTrue);
        expect(game.sessionId, 'room');
        expect(game.current?.revision, BigInt.from(2));
        expect(
          game.status,
          metadata.isEmpty ? FuelGameStatus.online : FuelGameStatus.saving,
        );
        if (metadata.isNotEmpty) {
          final sent = channel.sink.messages.length;
          expect(() => game.input({'move': 1}), throwsA(isA<FuelException>()));
          expect(channel.sink.messages.length, sent);
        } else {
          game.input({'move': 1});
          expect(channel.sink.messages, hasLength(1));
        }
      } finally {
        await subscription.cancel();
        await game.dispose();
        client.close();
      }
    });
  }

  test(
    'snapshots cannot enable input while departure awaits settlement',
    () async {
      var posts = 0;
      final departed = Completer<http.Response>();
      final entered = Completer<void>();
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.method == 'POST') {
            return ++posts == 1 ? saving() : departed.future;
          }
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/operations')) return fuelReply([]);
          return fuelReply(world());
        }),
      );
      await client.refreshAccount();
      final channel = TestChannel();
      final game = FuelGameController(client, socketFactory: (_, _) => channel)
        ..session.select('room');
      final subscription = game.updates.listen((_) {
        if (game.status == FuelGameStatus.saving && !entered.isCompleted)
          entered.complete();
      });
      Future<void>? assertion;
      try {
        await game.connect();
        channel.emit('before', '1');
        expect(game.status, FuelGameStatus.online);
        assertion = expectLater(game.leave(), completes);
        await entered.future.timeout(const Duration(seconds: 1));
        channel.emit('during', '2');
        expect(game.current?.state['private'], 'during');
        expect(game.status, FuelGameStatus.saving);
        final sent = channel.sink.messages.length;
        expect(
          () => game.input({'move': 1}),
          throwsA(
            isA<FuelException>().having((e) => e.code, 'code', 'not_connected'),
          ),
        );
        expect(channel.sink.messages.length, sent);
        expect(game.sessionId, 'room');
        departed.complete(fuelReply({'status': 'left'}));
        await assertion;
        expect(game.sessionId, isNull);
        expect(game.status, FuelGameStatus.idle);
      } finally {
        if (!departed.isCompleted)
          departed.complete(fuelReply({'status': 'left'}));
        await assertion;
        await subscription.cancel();
        await game.dispose();
        client.close();
      }
    },
  );

  test(
    'departure waits for settlement without losing membership on rejection',
    () async {
      var posts = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.method == 'POST') {
            return ++posts < 3 ? saving() : fuelReply({'status': 'left'});
          }
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          return fuelReply([]);
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client)..session.select('room');
      final entered = Completer<void>();
      final subscription = game.updates.listen((_) {
        if (game.status == FuelGameStatus.saving && !entered.isCompleted)
          entered.complete();
      });
      try {
        final leaving = game.leave();
        final assertion = expectLater(leaving, completes);
        await entered.future.timeout(const Duration(seconds: 1));
        expect(game.sessionId, 'room');
        await expectLater(
          game.match('solo', ticketId: 'other'),
          throwsA(
            isA<FuelException>().having((e) => e.code, 'code', 'session_busy'),
          ),
        );
        await assertion;
        expect(posts, 3);
        expect(game.sessionId, isNull);
        expect(game.status, FuelGameStatus.idle);
      } finally {
        await subscription.cancel();
        await game.dispose();
        client.close();
      }
    },
  );

  test(
    'departure preserves membership after a rejected wait then an unknown reply',
    () async {
      var posts = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.method == 'POST') {
            if (++posts == 1) return saving();
            throw http.ClientException('lost departure response');
          }
          return fuelReply(accountData(accountA));
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client)..session.select('room');
      try {
        await expectLater(game.leave(), throwsA(isA<http.ClientException>()));
        expect(posts, 2);
        expect(game.sessionId, 'room');
      } finally {
        await game.dispose();
        client.close();
      }
    },
  );

  final admissions = <String, Future<dynamic> Function(FuelGameController)>{
    'create': (game) => game.create('solo'),
    'join code': (game) => game.joinCode('ACDEFH'),
    'join public': (game) => game.joinPublic('room'),
    'match': (game) => game.match('solo', ticketId: 'same-ticket'),
  };
  for (final entry in admissions.entries) {
    test(
      '${entry.key} waits for rejected pending settlement before admission',
      () async {
        final posts = <String>[];
        final client = FuelClient(
          Uri.parse('https://game.example'),
          httpClient: MockClient((request) async {
            if (request.method == 'POST') {
              posts.add('${request.url.path}:${request.body}');
              return posts.length < 3
                  ? saving()
                  : fuelReply({'status': 'matched', 'session_id': 'room'});
            }
            if (request.url.path.endsWith('/account'))
              return fuelReply(accountData(accountA));
            return fuelReply(world());
          }),
        );
        await client.refreshAccount();
        final channel = TestChannel();
        final game = FuelGameController(
          client,
          socketFactory: (_, _) => channel,
        );
        final states = <FuelGameStatus>[];
        final subscription = game.updates.listen(
          (_) => states.add(game.status),
        );
        try {
          await entry.value(game);
          channel.emit('settled', '1');
          expect(posts.length, 3);
          expect(posts.toSet().length, 1);
          expect(states, contains(FuelGameStatus.saving));
          expect(game.sessionId, 'room');
          expect(game.status, FuelGameStatus.online);
        } finally {
          await subscription.cancel();
          await game.dispose();
          client.close();
        }
      },
    );
  }

  for (final cancel in ['suspend', 'identity', 'dispose']) {
    test('$cancel during settlement wait prevents another admission', () async {
      var posts = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.method == 'POST') {
            posts++;
            return saving();
          }
          return fuelReply(accountData(accountA));
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client);
      final subscription = game.updates.listen((_) {
        if (game.status != FuelGameStatus.saving) return;
        switch (cancel) {
          case 'suspend':
            game.suspend();
          case 'identity':
            unawaited(
              Future<void>.delayed(
                const Duration(milliseconds: 10),
                () => client.credential = FuelCredential.create(),
              ),
            );
          case 'dispose':
            unawaited(game.dispose());
        }
      });
      try {
        await expectLater(
          game.create('solo'),
          throwsA(
            isA<FuelException>().having((e) => e.code, 'code', 'cancelled'),
          ),
        );
        expect(posts, 1);
        expect(game.sessionId, isNull);
      } finally {
        await subscription.cancel();
        await game.dispose();
        client.close();
      }
    });
  }

  test(
    'an unknown result after settlement rejection is never resubmitted',
    () async {
      var posts = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.method == 'POST') {
            if (++posts == 1) return saving();
            throw http.ClientException('committed admission, lost response');
          }
          return fuelReply(accountData(accountA));
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client);
      try {
        await expectLater(
          game.create('solo'),
          throwsA(isA<http.ClientException>()),
        );
        await expectLater(
          game.create('solo'),
          throwsA(
            isA<FuelException>().having(
              (e) => e.code,
              'code',
              'pending_admission',
            ),
          ),
        );
        expect(posts, 2);
      } finally {
        await game.dispose();
        client.close();
      }
    },
  );

  test('unsettled admission stops at the existing timeout budget', () async {
    var posts = 0;
    final client = FuelClient(
      Uri.parse('https://game.example'),
      timeout: const Duration(milliseconds: 80),
      httpClient: MockClient((request) async {
        if (request.method == 'POST') {
          posts++;
          return saving();
        }
        return fuelReply(accountData(accountA));
      }),
    );
    await client.refreshAccount();
    final game = FuelGameController(client);
    try {
      await expectLater(
        game.create('solo'),
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'pending_result'),
        ),
      );
      expect(posts, inInclusiveRange(1, 3));
      expect(game.sessionId, isNull);
    } finally {
      await game.dispose();
      client.close();
    }
  });

  for (final error in [(400, 'full'), (500, 'pending_result')]) {
    test('admission does not retry ${error.$1} ${error.$2}', () async {
      var posts = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.method == 'POST') {
            posts++;
            return http.Response(
              '{"wire_version":1,"error":"${error.$2}"}',
              error.$1,
            );
          }
          return fuelReply(accountData(accountA));
        }),
      );
      await client.refreshAccount();
      final game = FuelGameController(client);
      try {
        await expectLater(game.create('solo'), throwsA(isA<FuelException>()));
        expect(posts, 1);
      } finally {
        await game.dispose();
        client.close();
      }
    });
  }

  test('a waiting match restores idle after the settlement wait', () async {
    var posts = 0;
    final client = FuelClient(
      Uri.parse('https://game.example'),
      httpClient: MockClient((request) async {
        if (request.method == 'POST') {
          return ++posts == 1 ? saving() : fuelReply({'status': 'waiting'});
        }
        return fuelReply(accountData(accountA));
      }),
    );
    await client.refreshAccount();
    final game = FuelGameController(client);
    try {
      expect(
        (await game.match('solo', ticketId: 'same-ticket'))['status'],
        'waiting',
      );
      expect(posts, 2);
      expect(game.status, FuelGameStatus.idle);
      expect(game.sessionId, isNull);
    } finally {
      await game.dispose();
      client.close();
    }
  });

  test('a waiting admission cannot overlap another match or create', () async {
    final entered = Completer<void>();
    var posts = 0;
    final client = FuelClient(
      Uri.parse('https://game.example'),
      httpClient: MockClient((request) async {
        if (request.method == 'POST') {
          return ++posts == 1 ? saving() : fuelReply({'status': 'waiting'});
        }
        return fuelReply(accountData(accountA));
      }),
    );
    await client.refreshAccount();
    final game = FuelGameController(client);
    final subscription = game.updates.listen((_) {
      if (game.status == FuelGameStatus.saving && !entered.isCompleted)
        entered.complete();
    });
    try {
      final matching = game.match('solo', ticketId: 'first');
      await entered.future;
      for (final start in [
        () => game.match('solo', ticketId: 'second'),
        () => game.create('solo'),
      ]) {
        await expectLater(
          start(),
          throwsA(
            isA<FuelException>().having((e) => e.code, 'code', 'session_busy'),
          ),
        );
      }
      expect((await matching)['status'], 'waiting');
      expect(posts, 2);
      expect(game.status, FuelGameStatus.idle);
    } finally {
      await subscription.cancel();
      await game.dispose();
      client.close();
    }
  });
}
