part of '../fuel_client.dart';

Future<void> _boundedCleanup(
  Future<void> Function() action,
  Duration limit,
) async {
  try {
    await action().timeout(limit);
  } catch (_) {
    // Cleanup cannot revive a detached request or connection.
  }
}

/// Bounded HTTP IO without account policy, retries or interpretation of status.
class FuelHttpTransport {
  final http.Client _client;
  final Duration timeout;
  final int maxRequestBytes;
  final int maxResponseBytes;
  final int maxPending;
  final _pending = <void Function(Object)>{};
  bool _closed = false;

  FuelHttpTransport({
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    this.maxRequestBytes = 64 * 1024,
    this.maxResponseBytes = 1024 * 1024,
    this.maxPending = 64,
  }) : _client = client ?? http.Client() {
    if (timeout <= Duration.zero ||
        maxRequestBytes < 1 ||
        maxResponseBytes < 1 ||
        maxPending < 1) {
      throw ArgumentError('positive transport limits required');
    }
  }

  Future<http.Response> get(
    Uri uri, {
    Map<String, String>? headers,
    Future<void>? cancel,
    Duration? timeout,
  }) => request('GET', uri, headers: headers, cancel: cancel, timeout: timeout);

  Future<http.Response> post(
    Uri uri, {
    Map<String, String>? headers,
    String? body,
    Future<void>? cancel,
    Duration? timeout,
  }) => request(
    'POST',
    uri,
    headers: headers,
    body: body,
    cancel: cancel,
    timeout: timeout,
  );

  Future<http.Response> request(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    String? body,
    Future<void>? cancel,
    Duration? timeout,
  }) {
    if (_closed) return Future.error(const FuelException('closed'));
    if (_pending.length >= maxPending)
      return Future.error(const FuelException('busy'));
    if (body != null &&
        (body.length > maxRequestBytes ||
            utf8.encode(body).length > maxRequestBytes)) {
      return Future.error(const FuelException('too_large'));
    }
    final limit = timeout ?? this.timeout;
    if (limit <= Duration.zero)
      return Future.error(ArgumentError('positive timeout required'));
    final result = Completer<http.Response>();
    final abort = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    Timer? timer;
    void release() {
      timer?.cancel();
      if (!abort.isCompleted) abort.complete();
      final stream = subscription;
      if (stream != null)
        unawaited(_boundedCleanup(stream.cancel, const Duration(seconds: 3)));
    }

    late void Function(Object) fail;
    fail = (error) {
      if (result.isCompleted) return;
      _pending.remove(fail);
      result.completeError(error);
      release();
    };
    _pending.add(fail);
    timer = Timer(limit, () => fail(const FuelException('timeout')));
    cancel?.then(
      (_) => fail(const FuelException('cancelled')),
      onError: (Object _) => fail(const FuelException('cancelled')),
    );
    final request = http.AbortableRequest(
      method,
      uri,
      abortTrigger: abort.future,
    );
    if (headers != null) request.headers.addAll(headers);
    if (body != null) request.body = body;
    try {
      _client
          .send(request)
          .then<void>((response) {
            if (result.isCompleted) {
              unawaited(
                _boundedCleanup(
                  () => response.stream
                      .listen((_) {}, onError: (Object _) {})
                      .cancel(),
                  const Duration(seconds: 3),
                ),
              );
              return;
            }
            final bytes = BytesBuilder(copy: false);
            subscription = response.stream.listen(
              (chunk) {
                if (result.isCompleted) return;
                if (bytes.length + chunk.length > maxResponseBytes) {
                  fail(const FuelException('too_large'));
                } else {
                  bytes.add(chunk);
                }
              },
              onError: (Object error) => fail(error),
              onDone: () {
                if (result.isCompleted) return;
                try {
                  final completed = http.Response.bytes(
                    bytes.takeBytes(),
                    response.statusCode,
                    headers: response.headers,
                    request: response.request,
                    isRedirect: response.isRedirect,
                    persistentConnection: response.persistentConnection,
                    reasonPhrase: response.reasonPhrase,
                  );
                  _pending.remove(fail);
                  timer?.cancel();
                  result.complete(completed);
                } catch (error) {
                  fail(error);
                }
              },
            );
          }, onError: (Object error) => fail(error))
          .catchError(fail);
    } catch (error) {
      fail(error);
    }
    return result.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final fail in _pending.toList()) {
      fail(const FuelException('closed'));
    }
    _client.close();
  }
}

/// One replaceable JSON socket. Identity and wire semantics belong to its caller.
/// Disconnect fences immediately; slow channel cleanup never blocks reconnect.
class FuelConnection {
  final Duration readyTimeout;
  final Duration? heartbeatTimeout;
  final Duration cleanupTimeout;
  final int maxMessageBytes;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Completer<bool>? _connecting;
  Timer? _heartbeat;
  Future<void> _cleanup = Future.value();
  void Function(Object)? _onError;
  int _generation = 0;
  bool _closed = false;
  bool _connected = false;
  bool get connected => _connected;

  FuelConnection({
    this.readyTimeout = const Duration(seconds: 20),
    this.heartbeatTimeout,
    this.cleanupTimeout = const Duration(seconds: 3),
    this.maxMessageBytes = 1024 * 1024,
  }) {
    if (readyTimeout <= Duration.zero ||
        cleanupTimeout <= Duration.zero ||
        (heartbeatTimeout != null && heartbeatTimeout! <= Duration.zero) ||
        maxMessageBytes < 1)
      throw ArgumentError('positive connection limits required');
  }

  Future<bool> connect(
    WebSocketChannel channel, {
    required void Function(Json) onMessage,
    void Function(Object)? onError,
    Json? hello,
    bool Function(Json)? isHeartbeat,
  }) {
    if (_closed) return Future.error(const FuelException('closed'));
    unawaited(disconnect());
    final gen = _generation;
    _channel = channel;
    _onError = onError;
    final ready = Completer<bool>();
    _connecting = ready;
    final early = <String>[];
    bool current() => !_closed && gen == _generation;
    void renew() {
      _heartbeat?.cancel();
      if (heartbeatTimeout != null) {
        _heartbeat = Timer(heartbeatTimeout!, () {
          if (current()) _terminate(const FuelException('timeout'));
        });
      }
    }

    void deliver(String message) {
      if (!current()) return;
      try {
        final json = jsonDecode(message) as Json;
        onMessage(json);
        if (!current()) return;
        final heartbeat = isHeartbeat?.call(json) ?? true;
        if (current() && heartbeat) renew();
      } catch (error) {
        if (current()) _terminate(error);
      }
    }

    try {
      _subscription = channel.stream.listen(
        (message) {
          if (!current()) return;
          if (message is! String ||
              message.length > maxMessageBytes ||
              utf8.encode(message).length > maxMessageBytes) {
            _terminate(const FuelException('too_large'));
          } else if (!_connected) {
            if (early.length >= 32) {
              _terminate(const FuelException('busy'));
            } else {
              early.add(message);
            }
          } else {
            deliver(message);
          }
        },
        onError: (Object error) {
          if (current()) _terminate(error);
        },
        onDone: () {
          if (current()) _terminate(const FuelException('disconnected'));
        },
      );
      channel.ready
          .timeout(readyTimeout)
          .then(
            (_) {
              if (!current()) return;
              try {
                _connected = true;
                if (hello != null) send(hello);
                if (!current()) return;
                renew();
                for (final message in early) {
                  deliver(message);
                  if (!current()) return;
                }
                if (!ready.isCompleted) ready.complete(true);
              } catch (error) {
                if (current()) _terminate(error);
              }
            },
            onError: (Object error) {
              if (current()) _terminate(error);
            },
          );
    } catch (error) {
      if (current()) _terminate(error);
    }
    return ready.future;
  }

  void send(Json message) {
    if (!_connected || _closed) throw const FuelException('not_connected');
    final encoded = jsonEncode(message);
    if (encoded.length > maxMessageBytes ||
        utf8.encode(encoded).length > maxMessageBytes) {
      throw const FuelException('too_large');
    }
    try {
      _channel!.sink.add(encoded);
    } catch (error) {
      _terminate(error);
      rethrow;
    }
  }

  void _terminate(Object error) {
    final notify = _onError;
    unawaited(disconnect());
    try {
      notify?.call(error);
    } catch (_) {
      /* A consumer cannot break cleanup. */
    }
  }

  Future<void> disconnect() {
    _generation++;
    _connected = false;
    _onError = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    final connecting = _connecting;
    _connecting = null;
    if (connecting != null && !connecting.isCompleted)
      connecting.complete(false);
    final channel = _channel;
    final subscription = _subscription;
    _channel = null;
    _subscription = null;
    _cleanup = Future.wait<void>([
      _cleanup,
      if (subscription != null)
        _boundedCleanup(subscription.cancel, cleanupTimeout),
      if (channel != null)
        _boundedCleanup(() => channel.sink.close(), cleanupTimeout),
    ]).then((_) {});
    return _cleanup;
  }

  Future<void> close() {
    _closed = true;
    return disconnect();
  }
}
