library;

import 'dart:async';
import 'dart:collection';
import 'package:flame/components.dart';
import 'package:fuel_client/fuel_client.dart';

/// Coalesce full snapshots; never use this component for dependent deltas/events.
class FuelSnapshotComponent extends Component {
  final Stream<FuelSnapshot> source;
  final void Function(FuelSnapshot) present;
  final void Function(Object) onError;
  StreamSubscription<FuelSnapshot>? _subscription;
  FuelSnapshot? _pending;
  bool _active = false;
  FuelSnapshotComponent(this.source, this.present, {required this.onError});
  @override
  void onMount() {
    super.onMount();
    _active = true;
    _subscription = source.listen((value) {
      if (_active) _pending = value;
    }, onError: onError);
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!_active) return;
    final value = _pending;
    _pending = null;
    if (value != null) present(value);
  }

  @override
  void onRemove() {
    _active = false;
    _subscription?.cancel();
    _subscription = null;
    _pending = null;
    super.onRemove();
  }
}

/// Reliable events pause on overflow until the caller explicitly resynchronizes.
class FuelEventComponent<T> extends Component {
  final Stream<T> source;
  final void Function(T) present;
  final void Function() onResync;
  final int capacity;
  final double interval;
  final FuelClient? owner;
  StreamSubscription<void>? _identitySubscription;
  int? _identityGeneration;
  final _queue = ListQueue<T>();
  StreamSubscription<T>? _subscription;
  bool _active = false;
  bool _gap = false;
  double _remaining = 0;
  FuelEventComponent(
    this.source,
    this.present, {
    required this.onResync,
    this.capacity = 64,
    this.interval = 0.1,
    this.owner,
  }) {
    if (capacity <= 0 || !interval.isFinite || interval < 0)
      throw ArgumentError('invalid queue limits');
  }
  @override
  void onMount() {
    super.onMount();
    _active = true;
    _identityGeneration = owner?.generation;
    _identitySubscription = owner?.updates.listen((_) {
      if (_identityGeneration != owner!.generation) {
        _identityGeneration = owner!.generation;
        reset();
      }
    });
    _subscription = source.listen((event) {
      if (!_active || _gap) return;
      if (_queue.length >= capacity) {
        _resync();
        return;
      }
      _queue.add(event);
    }, onError: (_) => _resync());
  }

  void _resync() {
    if (!_active || _gap) return;
    _gap = true;
    _queue.clear();
    onResync();
  }

  void reset() {
    _queue.clear();
    _gap = false;
    _remaining = 0;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!_active || _gap) return;
    _remaining -= dt;
    if (_remaining <= 0 && _queue.isNotEmpty) {
      present(_queue.removeFirst());
      _remaining = interval;
    }
  }

  @override
  void onRemove() {
    _active = false;
    _identitySubscription?.cancel();
    _identitySubscription = null;
    _subscription?.cancel();
    _subscription = null;
    _queue.clear();
    super.onRemove();
  }
}
