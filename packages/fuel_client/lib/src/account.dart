part of '../fuel_client.dart';

enum FuelAccountStatus {
  idle,
  loading,
  ready,
  offline,
  unauthorized,
  storageError,
  identityPending,
  deleted,
  closed,
}

class FuelAccount {
  final String id;
  final String _progress;
  final bool analyticsEnabled;
  final BigInt analyticsRevision;
  final DateTime serverTime;
  dynamic get progress => jsonDecode(_progress);

  FuelAccount.fromJson(Json json)
    : id = json['account_id'] as String,
      _progress = jsonEncode(json['progress']),
      analyticsEnabled = json['analytics_enabled'] as bool,
      analyticsRevision = BigInt.parse(json['analytics_revision'] as String),
      serverTime = DateTime.fromMillisecondsSinceEpoch(
        (json['server_time'] as int) * 1000,
        isUtc: true,
      ) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        analyticsRevision.isNegative) {
      throw const FormatException('invalid_account');
    }
  }
}

/// Synchronous invalidation stays safe when a listener selects another identity.
class _FuelSignal {
  final _controller = StreamController<void>.broadcast(sync: true);
  bool _emitting = false, _again = false;
  Stream<void> get stream => _controller.stream;
  bool get isClosed => _controller.isClosed;
  void notify() {
    if (isClosed) return;
    if (_emitting) {
      _again = true;
      return;
    }
    _emitting = true;
    try {
      do {
        _again = false;
        _controller.add(null);
      } while (_again && !isClosed);
    } finally {
      _emitting = false;
    }
  }

  Future<void> close() => _controller.close();
}
