library;

import 'package:flutter/widgets.dart';
import 'package:fuel_client/fuel_client.dart';

/// Edge-triggered actions rearm only after neutral input following lost focus.
class FuelInputGate {
  final _held = <String>{};
  final _blocked = <String>{};
  bool _disarmed = false;
  bool accept(String action, bool pressed) {
    if (!pressed) {
      _held.remove(action);
      _blocked.remove(action);
      _disarmed = false;
      return false;
    }
    if (_disarmed || _blocked.contains(action)) {
      _blocked.add(action);
      return false;
    }
    return _held.add(action);
  }

  void disarm() {
    _blocked.addAll(_held);
    _held.clear();
    _disarmed = true;
  }
}

/// Lifecycle only controls local presentation/input/network polling.
class FuelLifecycle extends ChangeNotifier with WidgetsBindingObserver {
  final FuelSession session;
  final FuelInputGate input;
  bool _disposed = false;
  FuelLifecycle(this.session, {FuelInputGate? input})
    : input = input ?? FuelInputGate() {
    WidgetsBinding.instance.addObserver(this);
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      session.resume();
    } else {
      input.disarm();
      session.suspend();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
