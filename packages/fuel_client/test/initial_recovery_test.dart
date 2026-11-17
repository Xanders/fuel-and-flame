import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'account_owner_test.dart' show accountA, accountB, accountData, fuelReply;
import 'client_test.dart' show TestVault;
import 'operations_test.dart' show journal;

http.Response rejected(int status, String code) =>
    http.Response('{"wire_version":1,"error":"$code"}', status);

void main() {
  for (final native in [false, true]) {
    for (final phase in ['account', 'bootstrap']) {
      test(
        '$native startup recovers $phase with one identity and bootstrap',
        () {
          fakeAsync((clock) {
            final vault = TestVault();
            final previous = FuelCredential.create();
            vault.slots['previous'] = previous;
            var posts = 0, reads = 0, prepares = 0;
            final proofs = <String?>[];
            final client = FuelClient(
              Uri.parse('https://game.example'),
              journal: journal({}),
              httpClient: MockClient((request) async {
                proofs.add(request.headers['Authorization']);
                if (request.url.path.endsWith('/auth/prepare')) {
                  prepares++;
                  expect(request.url.query, isEmpty);
                  return fuelReply({'status': 'prepared'});
                }
                if (request.url.path.endsWith('/auth/bootstrap')) {
                  posts++;
                  if (phase == 'bootstrap') {
                    throw http.ClientException('response lost after commit');
                  }
                  return fuelReply({'account_id': accountA});
                }
                if (request.url.path.endsWith('/account')) {
                  reads++;
                  if (reads <= 2) {
                    return phase == 'bootstrap'
                        ? rejected(401, 'unauthorized')
                        : rejected(503, 'unavailable');
                  }
                  return fuelReply(accountData(accountA));
                }
                return fuelReply([]);
              }),
            );
            final game = FuelGameController(client);
            Object? error;
            var completed = false;
            unawaited(
              game
                  .start(vault: native ? vault : null)
                  .then(
                    (_) {
                      completed = true;
                    },
                    onError: (Object e) {
                      error = e;
                    },
                  ),
            );
            clock.flushMicrotasks();
            final identity = client.generation;
            expect(completed, isFalse);
            clock.elapse(const Duration(seconds: 4));
            expect(error, isNull);
            expect(completed, isTrue);
            expect(client.account?.id, accountA);
            expect(client.generation, identity);
            expect(posts, 1);
            expect(prepares, native ? 0 : 1);
            if (native) {
              expect(proofs.toSet(), hasLength(1));
              expect(vault.slots['previous'], same(previous));
              expect(vault.slots['active'], isNotNull);
            }
            unawaited(game.dispose());
            client.close();
            clock.flushMicrotasks();
          });
        },
      );
    }
  }

  test('prepare retries safely before the sole bootstrap POST', () {
    fakeAsync((clock) {
      var prepares = 0, posts = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/prepare')) {
            expect(request.url.query, isEmpty);
            if (++prepares < 3) throw http.ClientException('offline');
          }
          if (request.url.path.endsWith('/auth/bootstrap')) posts++;
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/operations') ||
              request.url.path.endsWith('/sessions/mine'))
            return fuelReply([]);
          return fuelReply({'account_id': accountA});
        }),
      );
      final game = FuelGameController(client);
      Object? error;
      unawaited(
        game.start().catchError((Object e) {
          error = e;
        }),
      );
      clock.flushMicrotasks();
      final identity = client.generation;
      clock.elapse(const Duration(seconds: 4));
      expect(error, isNull);
      expect(client.account?.id, accountA);
      expect(client.generation, identity);
      expect(prepares, 3);
      expect(posts, 1);
      unawaited(game.dispose());
      client.close();
      clock.flushMicrotasks();
    });
  });

  for (final phase in ['prepare', 'bootstrap', 'account']) {
    test('$phase exhaustion is bounded and preserves unknown identity', () {
      fakeAsync((clock) {
        var calls = 0, posts = 0, rotations = 0;
        final client = FuelClient(
          Uri.parse('https://game.example'),
          journal: journal({}),
          httpClient: MockClient((request) async {
            calls++;
            if (request.url.query.isNotEmpty) rotations++;
            if (request.method == 'POST') posts++;
            if (request.url.path.endsWith('/auth/$phase') ||
                phase == 'account' && request.url.path.endsWith('/account'))
              throw http.ClientException('offline');
            if (request.url.path.endsWith('/account'))
              return rejected(401, 'unauthorized');
            return fuelReply({'account_id': accountA});
          }),
        );
        final game = FuelGameController(client);
        Object? error;
        unawaited(
          game.start(newGuest: true).catchError((Object e) {
            error = e;
          }),
        );
        clock.flushMicrotasks();
        final identity = client.generation;
        clock.elapse(const Duration(seconds: 10));
        expect(error, isA<http.ClientException>());
        expect(game.status, FuelGameStatus.offline);
        expect(game.lastError, same(error));
        expect(client.accountStatus, FuelAccountStatus.identityPending);
        expect(client.generation, identity);
        expect(posts, phase == 'prepare' ? 0 : 1);
        expect(rotations, 0);
        final stopped = calls;
        clock.elapse(const Duration(minutes: 10));
        expect(calls, stopped);
        expect(stopped, lessThanOrEqualTo(7));
        unawaited(game.dispose());
        client.close();
        clock.flushMicrotasks();
      });
    });
  }

  for (final transition in ['suspend', 'dispose', 'close']) {
    test('$transition stops initial retry before another request', () {
      fakeAsync((clock) {
        var calls = 0;
        final client = FuelClient(
          Uri.parse('https://game.example'),
          httpClient: MockClient((_) async {
            calls++;
            throw http.ClientException('offline');
          }),
        );
        final game = FuelGameController(client);
        Object? error;
        unawaited(
          game.start().catchError((Object e) {
            error = e;
          }),
        );
        clock.flushMicrotasks();
        switch (transition) {
          case 'suspend':
            game.suspend();
          case 'dispose':
            unawaited(game.dispose());
          case 'close':
            client.close();
        }
        clock.elapse(const Duration(seconds: 10));
        expect(calls, 1);
        expect(
          error,
          isA<FuelException>().having((e) => e.code, 'code', 'cancelled'),
        );
        expect(
          game.status,
          transition == 'suspend'
              ? FuelGameStatus.suspended
              : transition == 'dispose'
              ? FuelGameStatus.closed
              : anything,
        );
        unawaited(game.dispose());
        client.close();
        clock.flushMicrotasks();
      });
    });
  }

  test('storage failure stops before any network admission', () {
    fakeAsync((clock) {
      var calls = 0;
      final vault = TestVault()..failActivate = true;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((_) async {
          calls++;
          return fuelReply({'account_id': accountA});
        }),
      );
      final game = FuelGameController(client);
      Object? error;
      unawaited(
        game.start(vault: vault).catchError((Object e) {
          error = e;
        }),
      );
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 1));
      expect(
        error,
        isA<FuelException>().having((e) => e.code, 'code', 'storage_error'),
      );
      expect(client.accountStatus, FuelAccountStatus.storageError);
      expect(game.status, FuelGameStatus.offline);
      expect(calls, 0);
      unawaited(game.dispose());
      client.close();
      clock.flushMicrotasks();
    });
  });

  test('mismatched account after confirmed bootstrap is never published', () {
    fakeAsync((clock) {
      var reads = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account')) {
            reads++;
            return fuelReply(accountData(accountB));
          }
          return fuelReply({'account_id': accountA});
        }),
      );
      final game = FuelGameController(client);
      Object? error;
      unawaited(
        game.start().catchError((Object e) {
          error = e;
        }),
      );
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 1));
      expect(
        error,
        isA<FuelException>().having((e) => e.code, 'code', 'invalid_account'),
      );
      expect(client.account, isNull);
      expect(reads, 1);
      unawaited(game.dispose());
      client.close();
      clock.flushMicrotasks();
    });
  });

  test('definite revoked proof is not retried or rotated', () {
    fakeAsync((clock) {
      var posts = 0, calls = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          calls++;
          if (request.method == 'POST') {
            posts++;
            return rejected(401, 'unauthorized');
          }
          return fuelReply({'status': 'prepared'});
        }),
      );
      final game = FuelGameController(client);
      Object? error;
      unawaited(
        game.start().catchError((Object e) {
          error = e;
        }),
      );
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 1));
      expect(
        error,
        isA<FuelException>().having((e) => e.code, 'code', 'unauthorized'),
      );
      expect(game.status, FuelGameStatus.unauthorized);
      expect(client.accountStatus, FuelAccountStatus.unauthorized);
      expect(posts, 1);
      expect(calls, 2);
      unawaited(game.dispose());
      client.close();
      clock.flushMicrotasks();
    });
  });
}
