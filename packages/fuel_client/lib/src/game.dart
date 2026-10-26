part of '../fuel_client.dart';

enum FuelGameStatus {
  idle,
  connecting,
  online,
  saving,
  offline,
  suspended,
  lost,
  unauthorized,
  closed,
}

typedef FuelSocketFactory =
    WebSocketChannel Function(Uri uri, Map<String, String> headers);

/// Owns one selected session. Identity transitions never create a replacement room.
class FuelGameController {
  final FuelClient client;
  final FuelSession session;
  final FuelSocketFactory _socketFactory;
  final _updates = _FuelSignal();
  Stream<void> get updates => _updates.stream;
  FuelGameStatus _status = FuelGameStatus.idle;
  FuelGameStatus get status =>
      _settlementWait &&
          (_status == FuelGameStatus.idle || _status == FuelGameStatus.online)
      ? FuelGameStatus.saving
      : _status;
  bool get _inactive =>
      _status == FuelGameStatus.closed || _status == FuelGameStatus.suspended;
  FuelSnapshot? get current => session.current;
  String? get sessionId => session._id;
  String roomCode = '', mode = '';
  Object? lastError;
  FuelRealtime? _realtime;
  Timer? _retry, _refresh;
  int _generation = 0, _attempt = 0;
  BigInt _receiptCursor = BigInt.zero;
  Future<void>? _connecting;
  Future<FuelSnapshot>? _commandFlight;
  FuelCommand? _pendingCommand;
  FuelCommand? get pendingCommand => _pendingCommand;
  bool _joining = false, _admissionUnknown = false, _settlementWait = false;
  late final StreamSubscription<void> _identity;
  late final StreamSubscription<FuelSnapshot> _snapshots;

  FuelGameController(this.client, {FuelSocketFactory? socketFactory})
    : session = FuelSession(client),
      _socketFactory = socketFactory ?? platform.connectSocket {
    _identity = client._identityChanges.stream.listen((_) {
      _detach();
      session._id = null;
      session.current = null;
      roomCode = '';
      mode = '';
      _receiptCursor = BigInt.zero;
      _admissionUnknown = false;
      _pendingCommand = null;
      if (_status != FuelGameStatus.closed &&
          _status != FuelGameStatus.suspended)
        _status = FuelGameStatus.idle;
      _updates.notify();
    });
    _snapshots = session.snapshots.listen((snapshot) {
      if (_status == FuelGameStatus.closed ||
          _status == FuelGameStatus.suspended)
        return;
      if (snapshot.mode.isNotEmpty) mode = snapshot.mode;
      if (snapshot.code.isNotEmpty) roomCode = snapshot.code;
      if (_realtime?.generation != null) {
        _status = _snapshotStatus;
        _attempt = 0;
        lastError = null;
      }
      if (snapshot.receiptCursor != _receiptCursor) {
        _receiptCursor = snapshot.receiptCursor;
        _recover();
      }
      _updates.notify();
    });
  }

  FuelGameStatus get _snapshotStatus =>
      current?.savingBacklog == true || current?.effectError != null
      ? FuelGameStatus.saving
      : FuelGameStatus.online;

  void _guard(int token, int identity) {
    if (token != _generation ||
        identity != client.generation ||
        _status == FuelGameStatus.closed)
      throw const FuelException('cancelled');
  }

  Future<void> start({CredentialVault? vault, bool newGuest = false}) async {
    if (_status == FuelGameStatus.closed) throw const FuelException('closed');
    if (_status == FuelGameStatus.suspended)
      throw const FuelException('cancelled');
    final login = vault == null
        ? client.bootstrapBrowser(newGuest: newGuest)
        : client.bootstrapNative(vault, newGuest: newGuest);
    // Bootstrap synchronously invalidates the old identity before yielding.
    final token = _generation, identity = client.generation;
    await login;
    _guard(token, identity);
    if (client.account == null) return;
    _status = FuelGameStatus.connecting;
    _updates.notify();
    try {
      await client.recoverOperations();
      _guard(token, identity);
      await client.retryPendingActions();
      _guard(token, identity);
      await recoverRoom();
    } catch (error) {
      _guard(token, identity);
      _failed(error);
      rethrow;
    }
  }

  Future<void> create(String mode) =>
      _admit(() => client.createRoom(mode), mode);
  Future<void> joinCode(String code) => _admit(() => client.joinCode(code), '');
  Future<void> joinPublic(String id) => _admit(() => client.joinPublic(id), '');
  Future<Json> match(String mode, {required String ticketId}) async {
    if (_inactive) throw const FuelException('inactive_session');
    if (_joining || _admissionUnknown) {
      throw FuelException(
        _admissionUnknown ? 'pending_admission' : 'session_busy',
      );
    }
    _joining = true;
    final token = _generation, identity = client.generation;
    late Json result;
    try {
      result = await _afterSettlement(
        () => client.match(mode, ticketId: ticketId),
        token,
        identity,
      );
      _guard(token, identity);
    } finally {
      if (token == _generation) _joining = false;
    }
    if (result['status'] == 'matched') await _admit(() async => result, mode);
    return result;
  }

  Future<void> _admit(Future<Json> Function() admission, String selectedMode) {
    if (_inactive) return Future.error(const FuelException('inactive_session'));
    if (_joining || _admissionUnknown)
      return Future.error(
        FuelException(_admissionUnknown ? 'pending_admission' : 'session_busy'),
      );
    _joining = true;
    final token = _generation, identity = client.generation;
    return () async {
      try {
        if (sessionId != null) throw const FuelException('already_joined');
        _admissionUnknown = true;
        final reply = await _afterSettlement(admission, token, identity);
        _guard(token, identity);
        _admissionUnknown = false;
        _select(reply, selectedMode);
        await connect();
      } catch (error) {
        _guard(token, identity);
        if (error is FuelException && error.status >= 400 && error.status < 500)
          _admissionUnknown = false;
        lastError = error;
        if (_status != FuelGameStatus.lost &&
            _status != FuelGameStatus.unauthorized)
          _status = FuelGameStatus.offline;
        _updates.notify();
        rethrow;
      } finally {
        if (token == _generation && identity == client.generation)
          _joining = false;
      }
    }();
  }

  Future<Json> _afterSettlement(
    Future<Json> Function() admission,
    int token,
    int identity,
  ) async {
    final watch = Stopwatch()..start();
    try {
      while (true) {
        _guard(token, identity);
        try {
          return await admission();
        } on FuelException catch (error) {
          _guard(token, identity);
          // This rejection has not performed the requested membership change.
          if (error.status != 400 ||
              error.code != 'pending_result' ||
              watch.elapsed >= client.timeout)
            rethrow;
          _settlementWait = true;
          _updates.notify();
          _guard(token, identity);
          final remaining = client.timeout - watch.elapsed;
          if (remaining <= Duration.zero) rethrow;
          const interval = Duration(milliseconds: 50);
          await Future<void>.delayed(
            remaining < interval ? remaining : interval,
          );
          _guard(token, identity);
          if (watch.elapsed >= client.timeout) rethrow;
        }
      }
    } finally {
      if (token == _generation &&
          identity == client.generation &&
          _settlementWait) {
        _settlementWait = false;
        _updates.notify();
      }
    }
  }

  void _select(Json reply, String selectedMode) {
    session.select(reply['session_id'] as String);
    mode = reply['mode'] as String? ?? selectedMode;
    roomCode = reply['code'] as String? ?? '';
    _receiptCursor = BigInt.zero;
  }

  Future<void> recoverRoom() async {
    if (_inactive) throw const FuelException('inactive_session');
    final token = _generation, identity = client.generation;
    try {
      final actor = client.account?.id;
      final key = 'account:$actor:session_command';
      final pending = actor == null
          ? null
          : await client._stored(
              () => client._journal.readEntry(key),
              identity,
            );
      _guard(token, identity);
      final rooms = await client.request('GET', 'sessions/mine') as List;
      _guard(token, identity);
      _admissionUnknown = false;
      if (rooms.length > 1)
        throw const FuelException('session_selection_required');
      if (rooms.isEmpty) {
        if (pending != null) {
          await client._stored(
            () => client._journal.updateEntry(
              key,
              (old) => old?['id'] == pending['id'] ? null : old,
            ),
            identity,
          );
          _guard(token, identity);
        }
        _detach();
        session.select('');
        session._id = null;
        roomCode = '';
        mode = '';
        _receiptCursor = BigInt.zero;
        _pendingCommand = null;
        _status = pending == null ? FuelGameStatus.idle : FuelGameStatus.lost;
        if (pending != null) lastError = const FuelException('session_lost');
        _updates.notify();
        return;
      }
      _select(rooms.single as Json, '');
      await connect();
    } catch (error) {
      _guard(token, identity);
      _failed(error);
      rethrow;
    }
  }

  Future<void> connect() {
    if (_connecting != null) return _connecting!;
    final id = sessionId;
    if (id == null ||
        [
          FuelGameStatus.suspended,
          FuelGameStatus.closed,
          FuelGameStatus.lost,
        ].contains(_status))
      return Future.error(const FuelException('inactive_session'));
    final token = _generation, identity = client.generation;
    _status = FuelGameStatus.connecting;
    _retry?.cancel();
    _updates.notify();
    late Future<void> task;
    task = () async {
      try {
        _guard(token, identity);
        final old = _realtime;
        _realtime = null;
        await old?.close();
        _guard(token, identity);
        final snapshot =
            await client.request('GET', 'sessions/${Uri.encodeComponent(id)}')
                as Json;
        _guard(token, identity);
        session.accept(FuelSnapshot.fromJson(snapshot));
        _guard(token, identity);
        await _recoverCommand();
        _guard(token, identity);
        final uri = client._apiUri('stream', {
          'session_id': id,
          if (client.account != null) 'account_id': client.account!.id,
        });
        final proof = client._credential;
        final channel = _socketFactory(
          uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws'),
          {
            if (proof != null)
              'Authorization': 'Fuel ${proof.id}:${proof.secret}',
          },
        );
        _guard(token, identity);
        final realtime = _realtime = FuelRealtime(channel, session);
        await realtime.connect(
          onError: (error) {
            if (token == _generation && identity == client.generation)
              _failed(error);
          },
          onReady: () {
            _guard(token, identity);
            _status = _snapshotStatus;
            _attempt = 0;
            lastError = null;
            _updates.notify();
            _guard(token, identity);
          },
        );
        _guard(token, identity);
        _refresh ??= Timer.periodic(
          const Duration(seconds: 5),
          (_) => _recover(),
        );
      } catch (error) {
        _guard(token, identity);
        if (_confirmedRoomLoss(error)) {
          await _retireLostCommand(id);
          _guard(token, identity);
        }
        _failed(error);
        rethrow;
      } finally {
        if (identical(_connecting, task)) _connecting = null;
      }
    }();
    _connecting = task;
    return task;
  }

  void _recover() {
    final token = _generation, identity = client.generation;
    unawaited(
      () async {
        await client.recoverOperations();
        _guard(token, identity);
        try {
          await client.retryPendingActions();
        } on FuelException catch (error) {
          if (error.code != 'action_busy') rethrow;
        }
        _guard(token, identity);
        await _recoverCommand();
      }().catchError((Object error) {
        if (token == _generation &&
            identity == client.generation &&
            _status != FuelGameStatus.closed) {
          lastError = error;
          _updates.notify();
        }
      }),
    );
  }

  void _failed(Object error) {
    if ([
      FuelGameStatus.closed,
      FuelGameStatus.suspended,
      FuelGameStatus.lost,
      FuelGameStatus.unauthorized,
    ].contains(_status))
      return;
    lastError = error;
    final code = error is FuelException ? error.code : '';
    if (['unauthorized', 'selection_changed'].contains(code)) {
      _status = FuelGameStatus.unauthorized;
      _retry?.cancel();
    } else if (['session_lost', 'session_ended', 'forbidden'].contains(code) ||
        error is FuelException &&
            error.status >= 400 &&
            error.status < 500 &&
            ![408, 429].contains(error.status)) {
      _status = FuelGameStatus.lost;
      session.status = FuelSessionStatus.lost;
      _retry?.cancel();
    } else {
      _status = FuelGameStatus.offline;
      _retry?.cancel();
      final token = _generation, identity = client.generation;
      final delay = Duration(milliseconds: 500 * (1 << min(_attempt++, 4)));
      _retry = Timer(delay, () {
        if (token == _generation && identity == client.generation)
          unawaited(connect().catchError((Object _) {}));
      });
    }
    _updates.notify();
  }

  void input(Json action) {
    if (_settlementWait ||
        _commandFlight != null ||
        _pendingCommand != null ||
        _status != FuelGameStatus.online ||
        _realtime == null)
      throw const FuelException('not_connected');
    _realtime!.input(action);
  }

  Future<void> ready() async {
    if (_inactive) throw const FuelException('inactive_session');
    final id = sessionId;
    if (id == null) throw const FuelException('inactive_session');
    final token = _generation, identity = client.generation;
    final reply =
        await client.request(
              'POST',
              'sessions/${Uri.encodeComponent(id)}/ready',
              body: {},
            )
            as Json;
    _guard(token, identity);
    session.accept(FuelSnapshot.fromJson(reply));
  }

  Future<void> leave() async {
    if (_inactive) throw const FuelException('inactive_session');
    if (_commandFlight != null || _pendingCommand != null)
      throw const FuelException('pending_command');
    final id = sessionId;
    if (id == null) return;
    if (_joining || _admissionUnknown) {
      throw FuelException(
        _admissionUnknown ? 'pending_admission' : 'session_busy',
      );
    }
    _joining = true;
    final token = _generation, identity = client.generation;
    try {
      try {
        await _afterSettlement(
          () async =>
              await client.request(
                    'POST',
                    'sessions/${Uri.encodeComponent(id)}/leave',
                    body: {},
                  )
                  as Json,
          token,
          identity,
        );
      } on FuelException catch (error) {
        if (!['session_lost', 'session_ended'].contains(error.code)) rethrow;
      }
      _guard(token, identity);
      _detach();
      session.select('');
      session._id = null;
      roomCode = '';
      mode = '';
      _status = FuelGameStatus.idle;
      _updates.notify();
      await client.recoverOperations();
    } finally {
      if (token == _generation && identity == client.generation)
        _joining = false;
    }
  }

  void _detach() {
    _generation++;
    _joining = false;
    _settlementWait = false;
    _connecting = null;
    _commandFlight = null;
    _retry?.cancel();
    _refresh?.cancel();
    _refresh = null;
    final old = _realtime;
    _realtime = null;
    if (old != null) unawaited(old.close());
  }

  void suspend() {
    if (_status == FuelGameStatus.closed) return;
    _detach();
    session.suspend();
    _status = FuelGameStatus.suspended;
    _updates.notify();
  }

  Future<void> resume() async {
    if (_status != FuelGameStatus.suspended) return;
    session.resume();
    _status = FuelGameStatus.idle;
    if (sessionId != null) await connect();
    _updates.notify();
  }

  Future<void> dispose() async {
    if (_status == FuelGameStatus.closed) return;
    _detach();
    _status = FuelGameStatus.closed;
    session._id = null;
    await _identity.cancel();
    await _snapshots.cancel();
    await session.dispose();
    await _updates.close();
  }
}
