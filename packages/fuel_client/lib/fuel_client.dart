library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart' show sha256;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'src/platform_stub.dart'
    if (dart.library.io) 'src/platform_io.dart'
    if (dart.library.js_interop) 'src/platform_web.dart'
    as platform;

part 'src/transport.dart';
part 'src/storage.dart';
part 'src/account.dart';
part 'src/operations.dart';
part 'src/identity.dart';
part 'src/game.dart';
part 'src/session_commands.dart';

typedef Json = Map<String, dynamic>;

class FuelException implements Exception {
  final String code;
  final int status;
  const FuelException(this.code, [this.status = 0]);
  @override
  String toString() => 'FuelException($code, $status)';
}

String randomId([int bytes = 16]) {
  final random = Random.secure();
  return List.generate(
    bytes,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String normalizeCode(String value) {
  if (value.length > 30 || value.codeUnits.any((c) => c > 127)) {
    throw const FormatException('invalid_code');
  }
  final code = value.toUpperCase().replaceAll(RegExp('[ -]'), '');
  if (!RegExp(r'^[ACDEFHJKMNPRTUVWXY34679]{6}$').hasMatch(code)) {
    throw const FormatException('invalid_code');
  }
  return code;
}

String? inviteCode(Uri uri) => uri.queryParameters['invite'] == null
    ? null
    : normalizeCode(uri.queryParameters['invite']!);

class FuelCredential {
  final String id;
  final String secret;
  FuelCredential(this.id, this.secret) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(secret)) {
      throw const FormatException('invalid_credential');
    }
  }
  factory FuelCredential.create() => FuelCredential(randomId(), randomId(32));
  Json toStorage() => {'id': id, 'secret': secret};
  @override
  String toString() => 'FuelCredential([redacted])';
}

class FuelCommand {
  final String id;
  final String epoch;
  final BigInt revision;
  final String _action;
  Json get action => jsonDecode(_action) as Json;
  FuelCommand(this.id, this.epoch, this.revision, Json action)
    : _action = jsonEncode(action);
  Json toJson() => {
    'id': id,
    'epoch': epoch,
    'revision': '$revision',
    'action': action,
  };
}

class FuelSnapshot {
  final String sessionId;
  final String mode, code;
  final String epoch;
  final BigInt revision;
  final BigInt lastInput;
  final String _state;
  Json get state => jsonDecode(_state) as Json;
  final BigInt receiptCursor;
  final bool savingBacklog;
  final String? effectError;
  final DateTime serverTime;
  FuelSnapshot.fromJson(Json json)
    : sessionId = json['session_id'] as String,
      mode = json['mode'] as String? ?? '',
      code = json['code'] as String? ?? '',
      epoch = json['epoch'] as String,
      revision = BigInt.parse(json['revision'] as String),
      lastInput = BigInt.parse(json['last_input'] as String? ?? '-1'),
      _state = jsonEncode(json['state'] as Json),
      receiptCursor = BigInt.parse(json['receipt_cursor'] as String? ?? '0'),
      savingBacklog = json['saving_backlog'] as bool? ?? false,
      effectError = json['effect_error'] as String?,
      serverTime = DateTime.parse(json['server_time'] as String);
}

abstract interface class PendingCommands {
  Future<void> save(String sessionId, FuelCommand command);
  Future<void> remove(String sessionId, String id);
}

class FuelClient {
  final Uri base;
  final FuelHttpTransport _http;
  final Duration timeout;
  final PendingCommands? pending;
  final FuelJournal _browserJournal;
  platform.BrowserRecordPort? _browserRecords;
  StreamSubscription<void>? _storageChanges;
  late FuelJournal _journal;
  CredentialVault? _vault;
  FuelCredential? _credential;
  FuelCredential? _candidate;
  int _identityGeneration = 0;
  int get generation => _identityGeneration;
  final _identityChanges = _FuelSignal();
  final _updates = _FuelSignal();
  Stream<void> get updates => _updates.stream;
  FuelAccount? _account;
  FuelAccount? get account => _account;
  FuelAccountStatus _accountStatus = FuelAccountStatus.idle;
  FuelAccountStatus get accountStatus => _accountStatus;
  Object? lastError;
  Future<FuelAccount>? _accountFlight;
  int _accountVersion = 0;
  final _operationEvents = StreamController<FuelOperation>.broadcast(
    sync: true,
  );
  Stream<FuelOperation> get operations => _operationEvents.stream;
  FuelOperation? _lastOperation;
  FuelOperation? get lastOperation => _lastOperation;
  bool _operationGap = false;
  bool get operationGap => _operationGap;
  Future<void>? _recoveryFlight;
  Future<FuelOperation>? _actionFlight;
  Future<void>? _analyticsFlight;
  bool get analyticsSaving => _analyticsFlight != null;
  Object? analyticsError;
  bool _closed = false;
  bool _identityChanging = false;
  bool _identityUncertain = false;
  bool _preparingTransfer = false;
  FuelClient(
    this.base, {
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
    this.pending,
    FuelJournal? journal,
  }) : _http = FuelHttpTransport(client: httpClient, timeout: timeout),
       _browserJournal = journal ?? _platformJournal(base) {
    _journal = _browserJournal;
    if (base.scheme != 'https' &&
        !(base.scheme == 'http' &&
            ['127.0.0.1', 'localhost'].contains(base.host))) {
      throw ArgumentError('Fuel requires HTTPS outside loopback tests');
    }
    if (base.hasQuery || base.hasFragment || base.userInfo.isNotEmpty)
      throw ArgumentError('invalid base URL');
    if (_browserJournal is _BrowserFuelJournal) {
      _browserRecords = _browserJournal.port;
    } else {
      _browserRecords = _platformRecords(base);
    }
    if (_browserRecords != null) {
      _storageChanges = _browserRecords!.changes.listen((_) {
        unawaited(_checkBrowserSelection());
      });
    }
  }

  static FuelJournal _platformJournal(Uri base) {
    final port = _platformRecords(base);
    return port == null ? MemoryFuelJournal() : _BrowserFuelJournal(port);
  }

  static platform.BrowserRecordPort? _platformRecords(Uri base) {
    final normalized = base.replace(
      path: base.path.isEmpty || base.path == '/'
          ? '/fuel/v1'
          : base.path.replaceFirst(RegExp(r'/$'), ''),
    );
    return platform.browserRecords(
      'fuel:${sha256.convert(utf8.encode('$normalized'))}',
    );
  }

  Future<void> _checkBrowserSelection() async {
    if (_closed || _vault != null || _identityChanging) return;
    final token = generation;
    try {
      final selected = await _browserJournal.readEntry('identity');
      final pending = await _browserJournal.readEntry('selection');
      _guard(token);
      if (pending == null &&
          (_account == null ||
              selected?['account_id'] == _account!.id &&
                  selected?['kind'] == 'active'))
        return;
    } catch (_) {
      if (_closed || generation != token) return;
    }
    _identityUncertain = true;
    _advanceIdentity();
    _accountStatus = FuelAccountStatus.identityPending;
    _updates.notify();
  }

  set credential(FuelCredential? value) {
    _credential = value;
    _identityUncertain = false;
    _advanceIdentity();
  }

  void _advanceIdentity() {
    _identityGeneration++;
    _accountVersion++;
    _account = null;
    _accountFlight = null;
    _recoveryFlight = null;
    _actionFlight = null;
    _analyticsFlight = null;
    analyticsError = null;
    _lastOperation = null;
    _operationGap = false;
    lastError = null;
    _accountStatus = _closed
        ? FuelAccountStatus.closed
        : FuelAccountStatus.idle;
    _identityChanges.notify();
    _updates.notify();
  }

  void _guard(int token) {
    if (_closed || token != generation) throw const FuelException('cancelled');
  }

  void _publishAccount(FuelAccount value, int token) {
    _guard(token);
    if (_account != null && _account!.id != value.id) {
      _advanceIdentity();
      throw const FuelException('selection_changed');
    }
    _account = value;
    _identityUncertain = false;
    _accountStatus = FuelAccountStatus.ready;
    lastError = null;
    _updates.notify();
    _guard(token);
  }

  Future<FuelAccount> _readAccount(int token) async {
    final data = await _request('GET', 'account') as Json;
    _guard(token);
    return FuelAccount.fromJson(data);
  }

  Future<T> _stored<T>(Future<T> Function() operation, int token) async {
    _guard(token);
    try {
      final result = await operation();
      _guard(token);
      return result;
    } catch (error) {
      _guard(token);
      if (error is FuelException) rethrow;
      throw const FuelException('storage_error');
    }
  }

  Future<T> _withIdentity<T>(Future<T> Function(int token) operation) {
    if (_closed || _identityChanging)
      return Future.error(
        FuelException(_closed ? 'closed' : 'identity_changing'),
      );
    _identityChanging = true;
    _identityUncertain = true;
    _advanceIdentity();
    final token = generation;
    _accountStatus = FuelAccountStatus.loading;
    _updates.notify();
    final task = () async {
      try {
        _guard(token);
        final result = await _withBrowserIdentity(() async {
          _guard(token);
          return operation(token);
        });
        _guard(token);
        return result;
      } catch (error) {
        _guard(token);
        lastError = error;
        final code = error is FuelException ? error.code : '';
        if (code == 'unauthorized') _identityUncertain = false;
        _accountStatus =
            code.startsWith('storage') || code == 'credential_capacity'
            ? FuelAccountStatus.storageError
            : _identityUncertain
            ? FuelAccountStatus.identityPending
            : code == 'unauthorized'
            ? FuelAccountStatus.unauthorized
            : FuelAccountStatus.offline;
        rethrow;
      } finally {
        _identityChanging = false;
        if (!_closed && generation == token) _updates.notify();
      }
    }();
    return task.then((result) {
      _guard(token);
      return result;
    });
  }

  Future<T> _withBrowserIdentity<T>(Future<T> Function() operation) async {
    final records = _browserRecords;
    if (records == null) return operation();
    late T result;
    await records.lockIdentity(() async {
      result = await operation();
    });
    return result;
  }

  Future<FuelAccount> refreshAccount() {
    if (_closed || _identityChanging)
      return Future.error(
        FuelException(_closed ? 'closed' : 'identity_changing'),
      );
    if (_identityUncertain || _accountStatus == FuelAccountStatus.deleted)
      return Future.error(const FuelException('identity_pending'));
    if (_accountFlight != null) return _accountFlight!;
    final token = generation;
    final result = Completer<FuelAccount>();
    final future = _accountFlight = result.future;
    if (_account == null) _accountStatus = FuelAccountStatus.loading;
    _updates.notify();
    unawaited(() async {
      try {
        while (true) {
          _guard(token);
          final version = _accountVersion;
          final value = await _readAccount(token);
          if (version != _accountVersion) continue;
          _publishAccount(value, token);
          result.complete(value);
          break;
        }
      } catch (error, stack) {
        if (!_closed && generation == token) {
          lastError = error;
          _accountStatus =
              error is FuelException && error.code == 'unauthorized'
              ? FuelAccountStatus.unauthorized
              : FuelAccountStatus.offline;
          _updates.notify();
        }
        result.completeError(
          _closed || generation != token
              ? const FuelException('cancelled')
              : error,
          stack,
        );
      } finally {
        if (identical(_accountFlight, future)) _accountFlight = null;
      }
    }());
    return future;
  }

  Uri _apiUri(String path, Map<String, String>? query) {
    final suffix = Uri.parse(path);
    if (suffix.isAbsolute ||
        suffix.hasAuthority ||
        path.startsWith('/') ||
        suffix.hasQuery ||
        suffix.hasFragment ||
        suffix.pathSegments.any((part) => part == '.' || part == '..')) {
      throw ArgumentError(
        'Fuel API paths must remain relative to their configured prefix',
      );
    }
    var prefix = base.path;
    if (prefix.isEmpty || prefix == '/') prefix = '/fuel/v1/';
    if (!prefix.endsWith('/')) prefix += '/';
    return base
        .replace(path: prefix)
        .resolve(path)
        .replace(queryParameters: query);
  }

  Future<dynamic> request(
    String method,
    String path, {
    Json? body,
    Map<String, String>? query,
    Future<void>? cancel,
    FuelCredential? authentication,
  }) async {
    if (_identityChanging) throw const FuelException('identity_changing');
    if (_identityUncertain || _accountStatus == FuelAccountStatus.deleted)
      throw const FuelException('identity_pending');
    return _request(
      method,
      path,
      body: body,
      query: query,
      cancel: cancel,
      authentication: authentication,
    );
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Json? body,
    Map<String, String>? query,
    Future<void>? cancel,
    FuelCredential? authentication,
  }) async {
    if (_closed) throw const FuelException('closed');
    final gen = generation;
    final uri = _apiUri(path, query);
    final headers = {'Content-Type': 'application/json', 'X-Fuel-Version': '1'};
    final credential = authentication ?? _credential;
    if (authentication == null && _account != null)
      headers['X-Fuel-Expected-Account'] = _account!.id;
    if (credential != null)
      headers['Authorization'] = 'Fuel ${credential.id}:${credential.secret}';
    late http.Response response;
    try {
      response = await _http.request(
        method,
        uri,
        headers: headers,
        body: body == null ? null : jsonEncode(body),
        cancel: cancel,
      );
    } catch (_) {
      _guard(gen);
      rethrow;
    }
    if (_closed || gen != generation) throw const FuelException('cancelled');
    String? actor;
    for (final header in response.headers.entries) {
      if (header.key.toLowerCase() == 'x-fuel-account') {
        actor = header.value;
        break;
      }
    }
    if (actor != null && _account != null && _account!.id != actor) {
      _identityUncertain = true;
      _advanceIdentity();
      _accountStatus = FuelAccountStatus.identityPending;
      _updates.notify();
      throw const FuelException('selection_changed');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Json;
    if (json['wire_version'] != 1)
      throw const FuelException('unsupported_version');
    if (response.statusCode != 200 || json.containsKey('error')) {
      final candidatePath = [
        'auth/pair/status',
        'auth/pair/request',
        'auth/pair/activate',
      ].contains(path);
      if (json['error'] == 'unauthorized' &&
          authentication == null &&
          !candidatePath &&
          _account != null) {
        _identityUncertain = false;
        _advanceIdentity();
        _accountStatus = FuelAccountStatus.unauthorized;
        _updates.notify();
      }
      throw FuelException(
        json['error'] as String? ?? 'unavailable',
        response.statusCode,
      );
    }
    return json['data'];
  }

  Future<Json> bootstrapNative(
    CredentialVault vault, {
    bool newGuest = false,
  }) => _withIdentity((token) async {
    _vault = vault;
    _journal = vault;
    _credential = await _stored(() => vault.read('active'), token);
    await _resumeDeletions(token);
    final resumed = await _resumeSelection(token);
    if (resumed != null) {
      _publishAccount(resumed, token);
      return <String, dynamic>{'account_id': resumed.id};
    }
    final marker = await _stored(() => vault.readEntry('identity'), token);
    final saved = await _stored(() => vault.read('active'), token);
    if (saved == null && marker?['kind'] == 'deleted' && !newGuest) {
      _credential = null;
      _accountStatus = FuelAccountStatus.deleted;
      _identityUncertain = false;
      return <String, dynamic>{'status': 'deleted'};
    }
    var selected = saved ?? FuelCredential.create();
    await _stored(() => vault.activate(selected), token);
    _credential = selected;
    late Json result;
    try {
      result = await _request('POST', 'auth/bootstrap', body: {}) as Json;
    } on FuelException catch (error) {
      if (!newGuest ||
          saved == null ||
          error.status != 401 ||
          error.code != 'unauthorized')
        rethrow;
      _guard(token);
      selected = FuelCredential.create();
      // Replace only the rejected active slot, retaining a valid previous guest.
      await _stored(() => vault.write('active', selected), token);
      await _stored(() => vault.activate(selected), token);
      _credential = selected;
      result = await _request('POST', 'auth/bootstrap', body: {}) as Json;
    }
    _guard(token);
    final value = await _readAccount(token);
    if (result['account_id'] != value.id)
      throw const FuelException('invalid_account');
    await _stored(() => vault.activate(selected, accountId: value.id), token);
    _publishAccount(value, token);
    return result;
  });

  Future<Json> bootstrapBrowser({bool newGuest = false}) => _withIdentity((
    token,
  ) async {
    _vault = null;
    _journal = _browserJournal;
    _credential = null;
    await _resumeDeletions(token);
    final resumed = await _resumeSelection(token);
    if (resumed != null) {
      _publishAccount(resumed, token);
      return <String, dynamic>{'account_id': resumed.id};
    }
    final marker = await _stored(() => _journal.readEntry('identity'), token);
    if (marker?['kind'] == 'deleted' && !newGuest) {
      _accountStatus = FuelAccountStatus.deleted;
      _identityUncertain = false;
      return <String, dynamic>{'status': 'deleted'};
    }
    await _request('GET', 'auth/prepare');
    _guard(token);
    final result = await _request('POST', 'auth/bootstrap', body: {}) as Json;
    _guard(token);
    final value = await _readAccount(token);
    if (result['account_id'] != value.id)
      throw const FuelException('invalid_account');
    await _stored(
      () => _journal.writeEntry('identity', {
        'kind': 'active',
        'account_id': value.id,
      }),
      token,
    );
    _publishAccount(value, token);
    return result;
  });

  Future<Json> createRoom(
    String mode, {
    int capacity = 2,
    bool public = false,
    bool lateJoin = true,
  }) async =>
      await request(
            'POST',
            'sessions',
            body: {
              'mode': mode,
              'capacity': capacity,
              'public': public,
              'late_join': lateJoin,
            },
          )
          as Json;
  Future<List<dynamic>> lobbies(String mode) async =>
      await request('GET', 'sessions', query: {'mode': mode}) as List<dynamic>;
  Future<Json> joinCode(String code) async =>
      await request('POST', 'join', body: {'code': normalizeCode(code)})
          as Json;
  Future<Json> joinPublic(String sessionId) async =>
      await request('POST', 'join', body: {'session_id': sessionId}) as Json;
  Future<Json> match(String mode, {String ticketId = 'default'}) async =>
      await request(
            'POST',
            'match',
            body: {'mode': mode, 'ticket_id': ticketId},
          )
          as Json;
  Future<Json> cancelMatch(String mode, {String ticketId = 'default'}) async =>
      await request(
            'POST',
            'match/cancel',
            body: {'mode': mode, 'ticket_id': ticketId},
          )
          as Json;
  Future<Json> command(String sessionId, FuelCommand command) async {
    await pending?.save(sessionId, command);
    final result =
        await request(
              'POST',
              'sessions/${Uri.encodeComponent(sessionId)}/commands',
              body: command.toJson(),
            )
            as Json;
    await pending?.remove(sessionId, command.id);
    return result;
  }

  Future<Json> issuePair() async =>
      await request('POST', 'auth/pair', body: {}) as Json;
  Future<List<dynamic>> pendingPairs() async =>
      await request('GET', 'auth/pair/pending') as List<dynamic>;
  Future<Json> issuedPair(String id) async =>
      await request('GET', 'auth/pair/issued', query: {'id': id}) as Json;
  Future<Json> approvePair(String id) async =>
      await request('POST', 'auth/pair/approve', body: {'id': id}) as Json;
  Future<Json> pairStatus() async {
    final token = generation;
    if (_vault != null) {
      _candidate = await _stored(() => _vault!.read('candidate'), token);
      if (_candidate == null) throw const FuelException('missing_candidate');
    }
    return await request('GET', 'auth/pair/status', authentication: _candidate)
        as Json;
  }

  Future<Json> requestPair(String code) async =>
      await request(
            'POST',
            'auth/pair/request',
            body: {'code': normalizeCode(code)},
            authentication: _candidate,
          )
          as Json;
  Future<List<dynamic>> bindings() async =>
      await request('GET', 'auth/bindings') as List<dynamic>;
  Future<void> revokeBinding(String id, {bool confirmedLast = false}) async {
    await request(
      'POST',
      'auth/revoke',
      body: {'id': id, 'confirmed_last': confirmedLast},
    );
  }

  Future<Json> postChat(String kind, String target, String text) async =>
      await request(
            'POST',
            'chat',
            body: {'kind': kind, 'target': target, 'text': text},
          )
          as Json;
  Future<List<dynamic>> chatHistory(String kind, String target) async =>
      await request('GET', 'chat', query: {'kind': kind, 'target': target})
          as List<dynamic>;
  Future<List<dynamic>> leaderboard(String board, {int limit = 100}) async =>
      await request(
            'GET',
            'leaderboards/${Uri.encodeComponent(board)}',
            query: {'limit': '$limit'},
          )
          as List<dynamic>;
  Future<Json> leaderboardPage(String board, {int limit = 100}) async =>
      await request(
            'GET',
            'leaderboards/${Uri.encodeComponent(board)}/page',
            query: {'limit': '$limit'},
          )
          as Json;
  Future<List<dynamic>> ratings(
    String board, {
    String metric = 'wins',
    int hours = 24,
  }) async =>
      await request(
            'GET',
            'ratings/${Uri.encodeComponent(board)}',
            query: {'metric': metric, 'hours': '$hours'},
          )
          as List<dynamic>;

  /// Best-effort UI telemetry, separate from gameplay actions and receipts.
  Future<String> analyticsEvent(
    String name,
    Json properties, {
    String session = '',
  }) async {
    final confirmed = account;
    if (confirmed == null) throw const FuelException('account_required');
    if (!confirmed.analyticsEnabled || analyticsSaving) return 'disabled';
    final result =
        await request(
              'POST',
              'analytics/events',
              body: {
                'id': randomId(),
                'name': name,
                'session': session,
                'properties': properties,
                'revision': confirmed.analyticsRevision.toString(),
              },
            )
            as Json;
    return result['status'] as String;
  }

  Future<void> analyticsEnabled(bool enabled) {
    if (_analyticsFlight != null)
      return Future.error(const FuelException('preference_busy'));
    final token = generation;
    late Future<void> task;
    task =
        () async {
              Object? failure;
              try {
                await request(
                  'POST',
                  'analytics/enabled',
                  body: {'enabled': enabled},
                );
              } catch (error) {
                _guard(token);
                failure = error;
              }
              _guard(token);
              _accountVersion++;
              final confirmed = await refreshAccount();
              _guard(token);
              if (confirmed.analyticsEnabled != enabled)
                throw failure ?? const FuelException('preference_unconfirmed');
            }()
            .catchError((Object error) {
              _guard(token);
              analyticsError = error;
              throw error;
            })
            .whenComplete(() {
              if (identical(_analyticsFlight, task)) {
                _analyticsFlight = null;
                _updates.notify();
              }
            });
    analyticsError = null;
    _analyticsFlight = task;
    _updates.notify();
    return task.then((_) {
      _guard(token);
    });
  }

  Future<void> cancelPair(String id) async {
    await request('POST', 'auth/pair/cancel', body: {'id': id});
  }

  Future<List<dynamic>> mutedPlayers() async =>
      await request('GET', 'chat/mutes') as List;
  Future<void> mutePlayer(String id, bool muted) async {
    await request('POST', 'chat/mute', body: {'target': id, 'muted': muted});
  }

  Future<void> reportChat(
    String kind,
    String target,
    String messageId,
    String reason,
  ) async {
    await request(
      'POST',
      'chat/report',
      body: {
        'kind': kind,
        'target': target,
        'message_id': messageId,
        'reason': reason,
      },
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _advanceIdentity();
    unawaited(_identityChanges.close());
    unawaited(_updates.close());
    unawaited(_operationEvents.close());
    unawaited(_storageChanges?.cancel() ?? Future.value());
    _browserRecords?.close();
    _http.close();
  }
}

enum FuelSessionStatus { idle, connected, suspended, lost, closed }

class FuelSession {
  final FuelClient client;
  final _snapshots = StreamController<FuelSnapshot>.broadcast(sync: true);
  Stream<FuelSnapshot> get snapshots => _snapshots.stream;
  FuelSessionStatus status = FuelSessionStatus.idle;
  FuelSnapshot? current;
  String? _id;
  int _generation = 0;
  Future<void>? _poll;
  Completer<void>? _cancel;
  final _changes = StreamController<void>.broadcast(sync: true);
  late final StreamSubscription<void> _identitySubscription;
  FuelSession(this.client) {
    _identitySubscription = client._identityChanges.stream.listen((_) {
      if (status == FuelSessionStatus.closed) return;
      _invalidate();
      current = null;
      if (status != FuelSessionStatus.suspended) {
        status = FuelSessionStatus.idle;
      }
    });
  }

  void select(String id) {
    if (status == FuelSessionStatus.closed) throw const FuelException('closed');
    _invalidate();
    _id = id;
    current = null;
    status = FuelSessionStatus.idle;
  }

  void _invalidate() {
    _generation++;
    _changes.add(null);
    if (!(_cancel?.isCompleted ?? true)) _cancel!.complete();
    _cancel = null;
    _poll = null;
  }

  Future<void> poll() {
    if (_poll != null) return _poll!;
    final id = _id;
    if (id == null ||
        status == FuelSessionStatus.closed ||
        status == FuelSessionStatus.suspended ||
        status == FuelSessionStatus.lost) {
      return Future.error(const FuelException('inactive_session'));
    }
    final gen = _generation;
    final identity = client.generation;
    final cancel = _cancel = Completer<void>();
    final operation = () async {
      try {
        final json =
            await client.request(
                  'GET',
                  'sessions/${Uri.encodeComponent(id)}/events',
                  query: {
                    if (current != null) 'cursor': '${current!.revision}',
                    if (current != null) 'epoch': current!.epoch,
                  },
                  cancel: cancel.future,
                )
                as Json;
        if (gen != _generation || identity != client.generation) return;
        accept(FuelSnapshot.fromJson(json));
      } on FuelException catch (error) {
        if (gen != _generation || identity != client.generation) return;
        if (gen == _generation &&
            identity == client.generation &&
            error.code == 'session_lost') {
          _invalidate();
          status = FuelSessionStatus.lost;
        }
        rethrow;
      } catch (_) {
        if (gen != _generation || identity != client.generation) return;
        rethrow;
      } finally {
        if (gen == _generation) {
          _poll = null;
          _cancel = null;
        }
      }
    }();
    _poll = operation;
    return operation;
  }

  void accept(FuelSnapshot snapshot) {
    if (client._identityChanging ||
        client._closed ||
        [
          FuelSessionStatus.closed,
          FuelSessionStatus.suspended,
          FuelSessionStatus.lost,
        ].contains(status) ||
        snapshot.sessionId != _id)
      return;
    final old = current;
    if (old != null && old.epoch != snapshot.epoch) {
      _invalidate();
      status = FuelSessionStatus.lost;
      throw const FuelException('session_lost');
    }
    if (old != null && snapshot.revision < old.revision) return;
    if (old != null && snapshot.revision == old.revision) {
      status = FuelSessionStatus.connected;
      return;
    }
    current = snapshot;
    status = FuelSessionStatus.connected;
    _snapshots.add(snapshot);
  }

  void suspend() {
    _invalidate();
    status = FuelSessionStatus.suspended;
  }

  void resume() {
    if (status == FuelSessionStatus.suspended) {
      status = FuelSessionStatus.idle;
    }
  }

  Future<void> dispose() async {
    _invalidate();
    status = FuelSessionStatus.closed;
    await _identitySubscription.cancel();
    await _changes.close();
    await _snapshots.close();
  }
}

/// A caller-supplied channel supports browser cookies or native secure headers.
/// Realtime inputs are transient and are never automatically replayed.
class FuelRealtime {
  final WebSocketChannel channel;
  final FuelSession session;
  final FuelConnection _connection;
  StreamSubscription<void>? _sessionSubscription;
  String? generation;
  BigInt _sequence = BigInt.zero;
  int? _sessionGeneration;
  int? _identityGeneration;
  bool _closed = false;
  Future<void>? _cleanup;
  void Function(Object)? _onError;
  FuelRealtime(
    this.channel,
    this.session, {
    Duration readyTimeout = const Duration(seconds: 20),
    Duration heartbeatTimeout = const Duration(seconds: 12),
  }) : _connection = FuelConnection(
         readyTimeout: readyTimeout,
         heartbeatTimeout: heartbeatTimeout,
       );
  Future<void> connect({
    void Function(Object)? onError,
    void Function()? onReady,
  }) async {
    if (_closed || _sessionGeneration != null)
      throw const FuelException('closed');
    if (session.client._identityChanging ||
        session.client._identityUncertain ||
        session.client._closed ||
        session.client.accountStatus == FuelAccountStatus.deleted) {
      final error = FuelException(
        session.client._closed
            ? 'closed'
            : session.client._identityChanging
            ? 'identity_changing'
            : 'identity_pending',
      );
      _disconnect(error, notify: false);
      await close();
      throw error;
    }
    _onError = onError;
    _sessionGeneration = session._generation;
    _identityGeneration = session.client.generation;
    _sessionSubscription = session._changes.stream.listen((_) {
      if (!_valid) _disconnect(const FuelException('stale_connection'));
    });
    Object? failure;
    var announced = false;
    final ready = await _connection.connect(
      channel,
      onMessage: (json) {
        if (!_valid) {
          _disconnect(const FuelException('stale_connection'));
          return;
        }
        try {
          if (json['error'] != null)
            throw FuelException(json['error'] as String);
          if (json['wire_version'] != 1)
            throw const FuelException('unsupported_version');
          if (json['account_id'] != null &&
              session.client.account?.id != json['account_id'])
            throw const FuelException('selection_changed');
          final snapshot = FuelSnapshot.fromJson(json['data'] as Json);
          if (snapshot.sessionId != session._id)
            throw const FuelException('invalid_snapshot');
          generation = json['generation'] as String;
          session.accept(snapshot);
          if (!_valid) return;
          if (!announced) {
            announced = true;
            onReady?.call();
          }
        } catch (error) {
          _disconnect(error);
        }
      },
      onError: (Object error) {
        failure = error;
        _disconnect(error);
      },
      isHeartbeat: (json) =>
          json['wire_version'] == 1 &&
          json['data'] is Json &&
          (json['data'] as Json)['session_id'] == session._id,
    );
    if (!ready && failure != null) throw failure!;
  }

  void input(Json action) {
    if (!_valid ||
        generation == null ||
        session.current == null ||
        session.status != FuelSessionStatus.connected)
      throw const FuelException('not_connected');
    _sequence += BigInt.one;
    _connection.send({
      'epoch': session.current!.epoch,
      'sequence': '$_sequence',
      'action': action,
    });
  }

  bool get _valid =>
      !_closed &&
      !session.client._closed &&
      !session.client._identityChanging &&
      !session.client._identityUncertain &&
      _sessionGeneration == session._generation &&
      _identityGeneration == session.client.generation &&
      ![
        FuelSessionStatus.suspended,
        FuelSessionStatus.lost,
        FuelSessionStatus.closed,
      ].contains(session.status);

  void _disconnect(Object error, {bool notify = true}) {
    if (_closed) return;
    final wasCurrent = _valid;
    _closed = true;
    generation = null;
    if (wasCurrent && session.status == FuelSessionStatus.connected)
      session.status = FuelSessionStatus.idle;
    _cleanup = () async {
      await _connection.close();
      if (_sessionGeneration == null) {
        await _boundedCleanup(
          () => channel.sink.close(),
          const Duration(seconds: 3),
        );
      }
      await _sessionSubscription?.cancel();
    }();
    if (notify) {
      try {
        _onError?.call(error);
      } catch (_) {
        /* Cleanup is already fenced. */
      }
    }
  }

  Future<void> close() {
    _disconnect(const FuelException('closed'), notify: false);
    return _cleanup ?? Future.value();
  }
}
