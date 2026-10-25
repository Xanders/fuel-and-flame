import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuel_client/fuel_client.dart';
import 'package:fuel_flutter/fuel_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
