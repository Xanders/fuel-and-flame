import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'account_owner_test.dart' show accountA, accountData, fuelReply;
import 'game_test.dart' show world;
import 'operations_test.dart' show journal, operation;
import 'review_regression_test.dart' show TestChannel;

void main() {
  for (final path in ['operations', 'sessions/mine']) {
    test('startup recovers $path after more than five automatic attempts', () {
      fakeAsync((clock) {
        var failures = 0, creates = 0, sockets = 0;
        final channel = TestChannel();
        final client = FuelClient(
          Uri.parse('https://game.example'),
          journal: journal({}),
          httpClient: MockClient((request) async {
            final route = request.url.path;
            if (route.endsWith('/$path') && ++failures <= 6) {
              throw http.ClientException('offline');
            }
            if (route.endsWith('/account'))
              return fuelReply(accountData(accountA));
            if (route.endsWith('/operations')) return fuelReply([]);
            if (route.endsWith('/sessions/mine')) {
              return fuelReply([
                {'session_id': 'room'},
              ]);
            }
            if (route.endsWith('/sessions')) creates++;
            if (route.endsWith('/sessions/room')) return fuelReply(world());
            return fuelReply({'account_id': accountA});
          }),
        );
        final game = FuelGameController(
          client,
          socketFactory: (_, _) {
            sockets++;
            return channel;
          },
        );
        Object? initialError;
        unawaited(
          game.start().catchError((Object error) {
            initialError = error;
          }),
        );
        clock.flushMicrotasks();
        expect(initialError, isA<http.ClientException>());
        expect(game.status, FuelGameStatus.offline);
        for (var step = 0; step < 8 && sockets == 0; step++) {
          clock.elapse(const Duration(seconds: 8));
        }
        expect(failures, greaterThanOrEqualTo(7));
        expect(sockets, 1);
        channel.emit('recovered', '1');
        expect(game.status, FuelGameStatus.online);
        expect(game.sessionId, 'room');
        expect(creates, 0);
        unawaited(game.dispose());
        client.close();
        clock.flushMicrotasks();
      });
    });
  }

  for (final status in [0, 408, 429]) {
    test(
      'unknown admission ($status) recovers membership without another POST',
      () {
        fakeAsync((clock) {
          var posts = 0, reads = 0;
          final channel = TestChannel();
          final client = FuelClient(
            Uri.parse('https://game.example'),
            journal: journal({}),
            httpClient: MockClient((request) async {
              final route = request.url.path;
              if (route.endsWith('/account'))
                return fuelReply(accountData(accountA));
              if (route.endsWith('/operations')) return fuelReply([]);
              if (route.endsWith('/sessions')) {
                posts++;
                if (status == 0) throw http.ClientException('unknown outcome');
                return http.Response(
                  '{"wire_version":1,"error":"unavailable"}',
                  status,
                );
              }
              if (route.endsWith('/sessions/mine')) {
                if (++reads <= 5) throw http.ClientException('still offline');
                return fuelReply([
                  {'session_id': 'room'},
                ]);
              }
              return fuelReply(world());
            }),
          );
          unawaited(client.refreshAccount());
          clock.flushMicrotasks();
          final game = FuelGameController(
            client,
            socketFactory: (_, _) => channel,
          );
          unawaited(game.create('duel').catchError((Object _) {}));
          clock.flushMicrotasks();
          clock.elapse(const Duration(seconds: 25));
          expect(reads, 6);
          expect(posts, 1);
          channel.emit('recovered', '1');
          expect(game.status, FuelGameStatus.online);
          expect(game.sessionId, 'room');
          unawaited(game.dispose());
          client.close();
          clock.flushMicrotasks();
        });
      },
    );
  }

  test(
    'no-room recovery reconciles a committed action without another mutation',
    () {
      fakeAsync((clock) {
        var posts = 0, receiptReads = 0;
        Json? committed;
        final client = FuelClient(
          Uri.parse('https://game.example'),
          journal: journal({}),
          httpClient: MockClient((request) async {
            final route = request.url.path;
            if (route.endsWith('/account'))
              return fuelReply(accountData(accountA));
            if (route.endsWith('/actions')) {
              posts++;
              committed = operation('stable-intent', 1, source: 'public');
              throw http.ClientException('committed, response lost');
            }
            if (route.endsWith('/operations/stable-intent')) {
              if (++receiptReads <= 6)
                throw http.ClientException('receipt offline');
              return fuelReply(committed);
            }
            if (route.endsWith('/sessions/mine') ||
                route.endsWith('/operations'))
              return fuelReply([]);
            return fuelReply({'account_id': accountA});
          }),
        );
        unawaited(client.refreshAccount());
        clock.flushMicrotasks();
        unawaited(
          client
              .executeAction(FuelAction('buy', {}, id: 'stable-intent'))
              .then<void>((_) {}, onError: (Object _) {}),
        );
        // Observe the unknown outcome before starting the controller.
        clock.flushMicrotasks();
        final game = FuelGameController(client);
        unawaited(game.start().catchError((Object _) {}));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 25));
        expect(receiptReads, greaterThanOrEqualTo(7));
        expect(posts, 1);
        expect(game.status, FuelGameStatus.idle);
        unawaited(game.dispose());
        client.close();
        clock.flushMicrotasks();
      });
    },
  );

  test('suspension stops unknown admission recovery without replay', () {
    fakeAsync((clock) {
      var posts = 0, reads = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: journal({}),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/sessions')) {
            posts++;
            throw http.ClientException('offline');
          }
          if (request.url.path.endsWith('/sessions/mine')) reads++;
          return fuelReply([]);
        }),
      );
      unawaited(client.refreshAccount());
      clock.flushMicrotasks();
      final game = FuelGameController(client);
      unawaited(game.create('duel').catchError((Object _) {}));
      clock.flushMicrotasks();
      game.suspend();
      clock.elapse(const Duration(minutes: 2));
      expect(game.status, FuelGameStatus.suspended);
      expect(posts, 1);
      expect(reads, 0);
      unawaited(game.dispose());
      client.close();
      clock.flushMicrotasks();
    });
  });
}
