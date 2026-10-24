library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

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

/// Implement with OS secure storage. Browsers use HttpOnly cookies instead.
abstract interface class CredentialVault {
  Future<FuelCredential?> read(String slot);
  Future<void> write(String slot, FuelCredential credential);
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
  final String epoch;
  final BigInt revision;
  final BigInt lastInput;
  final Json state;
  final DateTime serverTime;
  FuelSnapshot.fromJson(Json json)
    : sessionId = json['session_id'] as String,
      epoch = json['epoch'] as String,
      revision = BigInt.parse(json['revision'] as String),
      lastInput = BigInt.parse(json['last_input'] as String? ?? '-1'),
      state = Map.unmodifiable(json['state'] as Json),
      serverTime = DateTime.parse(json['server_time'] as String);
}

abstract interface class PendingCommands {
  Future<void> save(String sessionId, FuelCommand command);
  Future<void> remove(String sessionId, String id);
}

class FuelClient {
  final Uri base;
  final http.Client _http;
  final Duration timeout;
  final PendingCommands? pending;
  FuelCredential? _credential;
  FuelCredential? _candidate;
  int generation = 0;
  bool _closed = false;
  FuelClient(
    this.base, {
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
    this.pending,
  }) : _http = httpClient ?? http.Client() {
    if (base.scheme != 'https' &&
        !(base.scheme == 'http' &&
            ['127.0.0.1', 'localhost'].contains(base.host))) {
      throw ArgumentError('Fuel requires HTTPS outside loopback tests');
    }
    if (base.hasQuery || base.hasFragment || base.userInfo.isNotEmpty)
      throw ArgumentError('invalid base URL');
  }

  set credential(FuelCredential? value) {
    _credential = value;
    generation++;
  }

  Future<dynamic> request(
    String method,
    String path, {
    Json? body,
    Map<String, String>? query,
    Future<void>? cancel,
    FuelCredential? authentication,
  }) async {
    if (_closed) throw const FuelException('closed');
    final gen = generation;
    final abort = Completer<void>();
    cancel?.then((_) {
      if (!abort.isCompleted) abort.complete();
    });
    final timer = Timer(timeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    final uri = base.resolve('/fuel/v1/$path').replace(queryParameters: query);
    final request = http.AbortableRequest(
      method,
      uri,
      abortTrigger: abort.future,
    );
    request.headers.addAll({
      'Content-Type': 'application/json',
      'X-Fuel-Version': '1',
    });
    final credential = authentication ?? _credential;
    if (credential != null)
      request.headers['Authorization'] =
          'Fuel ${credential.id}:${credential.secret}';
    if (body != null) request.body = jsonEncode(body);
    try {
      final response = await _http.send(request).timeout(timeout);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(timeout)) {
        if (bytes.length + chunk.length > 1024 * 1024) {
          if (!abort.isCompleted) abort.complete();
          throw const FuelException('too_large');
        }
        bytes.add(chunk);
      }
      if (_closed || gen != generation || abort.isCompleted)
        throw const FuelException('cancelled');
      final json = jsonDecode(utf8.decode(bytes.takeBytes())) as Json;
      if (json['wire_version'] != 1)
        throw const FuelException('unsupported_version');
      if (response.statusCode != 200 || json.containsKey('error')) {
        throw FuelException(
          json['error'] as String? ?? 'unavailable',
          response.statusCode,
        );
      }
      return json['data'];
    } finally {
      timer.cancel();
    }
  }

  Future<Json> bootstrapNative(CredentialVault vault) async {
    var saved = await vault.read('active');
    if (saved == null) {
      saved = FuelCredential.create();
      await vault.write('active', saved);
    }
    credential = saved;
    return await request('POST', 'auth/bootstrap', body: {}) as Json;
  }

  Future<Json> bootstrapBrowser() async {
    await request('GET', 'auth/prepare');
    return await request('POST', 'auth/bootstrap', body: {}) as Json;
  }

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
  Future<Json> approvePair(String id) async =>
      await request('POST', 'auth/pair/approve', body: {'id': id}) as Json;
  Future<Json> pairStatus() async =>
      await request('GET', 'auth/pair/status', authentication: _candidate)
          as Json;
  Future<Json> requestPair(String code) async =>
      await request(
            'POST',
            'auth/pair/request',
            body: {'code': normalizeCode(code)},
            authentication: _candidate,
          )
          as Json;
  Future<void> prepareTransfer({CredentialVault? vault}) async {
    if (vault == null) {
      await request('GET', 'auth/pair/prepare');
    } else {
      _candidate = await vault.read('candidate') ?? FuelCredential.create();
      await vault.write('candidate', _candidate!);
    }
  }

  Future<Json> activateTransfer({CredentialVault? vault}) async {
    if (vault == null) {
      final result =
          await request('POST', 'auth/pair/activate', body: {}) as Json;
      generation++;
      return result;
    }
    final candidate = _candidate ?? await vault.read('candidate');
    if (candidate == null) throw const FuelException('missing_candidate');
    final result =
        await request('GET', 'auth/pair/status', authentication: candidate)
            as Json;
    if (result['status'] != 'linked')
      throw const FuelException('confirmation_required');
    if (_credential != null) await vault.write('previous', _credential!);
    await vault.write('active', candidate);
    credential = candidate;
    return result;
  }

  Future<void> switchPrevious({CredentialVault? vault}) async {
    if (vault == null) {
      await request('POST', 'auth/switch', body: {});
      generation++;
    } else {
      final previous = await vault.read('previous');
      if (previous == null) throw const FuelException('missing_previous');
      await request('GET', 'progress', authentication: previous);
      if (_credential != null) await vault.write('previous', _credential!);
      await vault.write('active', previous);
      credential = previous;
    }
  }

  Future<List<dynamic>> bindings() async =>
      await request('GET', 'auth/bindings') as List<dynamic>;
  Future<void> revokeBinding(String id) async {
    await request('POST', 'auth/revoke', body: {'id': id});
  }

  Future<void> deleteAccount({required bool confirmed}) async {
    await request('POST', 'auth/delete', body: {'confirmed': confirmed});
    credential = null;
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
  Future<void> analyticsEnabled(bool enabled) async {
    await request('POST', 'analytics/enabled', body: {'enabled': enabled});
  }

  void close() {
    _closed = true;
    generation++;
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
  FuelSession(this.client);

  void select(String id) {
    _invalidate();
    _id = id;
    current = null;
    status = FuelSessionStatus.idle;
  }

  void _invalidate() {
    _generation++;
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
            error.code == 'session_lost')
          status = FuelSessionStatus.lost;
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
    if (status == FuelSessionStatus.closed || snapshot.sessionId != _id) return;
    final old = current;
    if (old != null && old.epoch != snapshot.epoch) {
      status = FuelSessionStatus.lost;
      throw const FuelException('session_lost');
    }
    if (old != null && snapshot.revision <= old.revision) return;
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
    await _snapshots.close();
  }
}

/// A caller-supplied channel supports browser cookies or native secure headers.
/// Realtime inputs are transient and are never automatically replayed.
class FuelRealtime {
  final WebSocketChannel channel;
  final FuelSession session;
  StreamSubscription<dynamic>? _subscription;
  String? generation;
  BigInt _sequence = BigInt.zero;
  FuelRealtime(this.channel, this.session);
  Future<void> connect({void Function(Object)? onError}) async {
    await channel.ready;
    _subscription = channel.stream.listen(
      (message) {
        try {
          if (message is! String || message.length > 1024 * 1024)
            throw const FuelException('too_large');
          final json = jsonDecode(message) as Json;
          if (json['wire_version'] != 1)
            throw const FuelException('unsupported_version');
          generation = json['generation'] as String;
          session.accept(FuelSnapshot.fromJson(json['data'] as Json));
        } catch (error) {
          onError?.call(error);
        }
      },
      onError: (Object error) {
        onError?.call(error);
      },
    );
  }

  void input(Json action) {
    if (generation == null || session.current == null)
      throw const FuelException('not_connected');
    _sequence += BigInt.one;
    channel.sink.add(
      jsonEncode({
        'epoch': session.current!.epoch,
        'sequence': '$_sequence',
        'action': action,
      }),
    );
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await channel.sink.close();
  }
}
