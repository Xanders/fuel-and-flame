import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuel_client/fuel_client.dart';
import 'package:fuel_flutter/fuel_flutter.dart';

void main() {
  test('background releases input and resume requires neutral input', () {
    final gate = FuelInputGate();
    expect(gate.accept('attack', true), isTrue);
    expect(gate.accept('attack', true), isFalse);
    gate.disarm();
    expect(gate.accept('attack', true), isFalse);
    expect(gate.accept('attack', false), isFalse);
    expect(gate.accept('attack', true), isTrue);
  });
  testWidgets(
    'application lifecycle suspends polling but does not pause a server match',
    (tester) async {
      final client = FuelClient(Uri.parse('https://game.example'));
      final session = FuelSession(client)..select('room');
      final controller = FuelLifecycle(session);
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(session.status, FuelSessionStatus.suspended);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(session.status, FuelSessionStatus.idle);
      controller.dispose();
      await tester.runAsync(session.dispose);
      client.close();
    },
  );
}
