library;

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:fuel_client/fuel_client.dart';

export 'src/audio.dart';

/// One UI owner for the account, session and local lifecycle.
class FuelGameModel extends ChangeNotifier with WidgetsBindingObserver {
  final FuelClient fuel;
  late final FuelGameController game;
  final input = FuelInputGate();
  final _subscriptions = <StreamSubscription<void>>[];
  bool _disposed = false;
  bool get isDisposed => _disposed;
  FuelGameModel(this.fuel, {FuelSocketFactory? socketFactory}) {
    game = FuelGameController(fuel, socketFactory: socketFactory);
    _subscriptions.add(
      fuel.updates.listen((_) {
        if (fuel.account == null) input.disarm();
        if (!_disposed) notifyListeners();
      }),
    );
    _subscriptions.add(
      game.updates.listen((_) {
        if (!_disposed) notifyListeners();
      }),
    );
    WidgetsBinding.instance.addObserver(this);
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(game.resume().catchError((Object _) {}));
    } else {
      input.disarm();
      game.suspend();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(game.dispose());
    fuel.close();
    super.dispose();
  }
}

/// Edge-triggered actions rearm only after neutral input following lost focus.
class FuelInputGate {
  final _held = <String>{};
  final _blocked = <String>{};
  bool _disarmed = false;
  bool get hasHeldInput => _held.isNotEmpty || _blocked.isNotEmpty;
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
