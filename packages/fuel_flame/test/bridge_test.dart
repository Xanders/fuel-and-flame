import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuel_flame/fuel_flame.dart';

void main() {
  test(
    'event overflow requests resync and never silently drops a reliable event',
    () async {
      final events = StreamController<int>.broadcast(sync: true);
      final played = <int>[];
      var resync = 0;
      final component = FuelEventComponent<int>(
        events.stream,
        played.add,
        capacity: 2,
        onResync: () => resync++,
      );
      component.onMount();
      events.add(1);
      events.add(2);
      events.add(3);
      component.update(0.1);
      expect(resync, 1);
      expect(played, isEmpty);
      component.reset();
      events.add(4);
      component.update(0.1);
      expect(played, [4]);
      component.onRemove();
      events.add(5);
      component.update(0.1);
      expect(played, [4]);
      await events.close();
    },
  );
}
