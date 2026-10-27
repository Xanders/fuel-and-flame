import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuel_client/fuel_client.dart';
import 'package:fuel_flutter/fuel_flutter.dart';
import 'package:http/testing.dart';
import '../../fuel_client/test/account_owner_test.dart'
    show accountA, accountData, fuelReply;
import '../../fuel_client/test/game_test.dart' show world;
import '../../fuel_client/test/review_regression_test.dart' show TestChannel;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final displaced in [true, false]) {
    test(
      'model lifecycle preserves displaced=$displaced reconnect policy',
      () async {
        final channels = <TestChannel>[];
        final fuel = FuelClient(
          Uri.parse('https://game.example'),
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/account')) {
              return fuelReply(accountData(accountA));
            }
            if (request.url.path.endsWith('/operations')) return fuelReply([]);
            if (request.url.path.endsWith('/sessions/mine')) {
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
        final model = FuelGameModel(
          fuel,
          socketFactory: (_, _) {
            final channel = TestChannel();
            channels.add(channel);
            return channel;
          },
        );
        try {
          await fuel.refreshAccount();
          await model.game.create('solo');
          channels.single.emit('retained board', '1');
          final retained = model.game.current;
          if (displaced) {
            channels.single.inbound.add(
              jsonEncode({'wire_version': 1, 'error': 'connection_replaced'}),
            );
          }
          final cause = model.game.lastError;
          for (var cycle = 0; cycle < 2; cycle++) {
            model.didChangeAppLifecycleState(AppLifecycleState.inactive);
            model.didChangeAppLifecycleState(AppLifecycleState.paused);
            expect(model.game.status, FuelGameStatus.suspended);
            model.didChangeAppLifecycleState(AppLifecycleState.resumed);
            await Future<void>.delayed(const Duration(milliseconds: 650));
            expect(channels, hasLength(displaced ? 1 : cycle + 2));
            expect(model.game.sessionId, 'room');
            expect(model.game.current!.epoch, 'e');
            if (displaced) {
              expect(model.game.status, FuelGameStatus.offline);
              expect(model.game.lastError, same(cause));
              expect((cause as FuelException).code, 'connection_replaced');
              expect(model.game.current, same(retained));
            } else {
              channels.last.emit('retained board', '${cycle + 2}');
              expect(model.game.status, FuelGameStatus.online);
            }
          }
          await model.game.connect();
          channels.last.emit('explicit reclaim', '4');
          expect(channels, hasLength(displaced ? 2 : 4));
          expect(model.game.status, FuelGameStatus.online);
          expect(model.game.lastError, isNull);
          expect(model.game.current!.state['private'], 'explicit reclaim');
        } finally {
          model.dispose();
          await Future<void>.delayed(Duration.zero);
        }
      },
    );
  }
  test(
    'the model owns lifecycle, neutral input rearm and client disposal',
    () async {
      final fuel = FuelClient(Uri.parse('https://game.example'));
      final model = FuelGameModel(fuel);
      expect(model.input.accept('attack', true), isTrue);
      model.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(model.game.status, FuelGameStatus.suspended);
      expect(model.input.accept('attack', true), isFalse);
      model.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(model.input.accept('attack', true), isFalse);
      expect(model.input.accept('attack', false), isFalse);
      expect(model.input.accept('attack', true), isTrue);
      model.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(model.game.status, FuelGameStatus.closed);
      expect(fuel.accountStatus, FuelAccountStatus.closed);
    },
  );
}
