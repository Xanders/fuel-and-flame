part of '../fuel_client.dart';

/// One deliberate persistent action. Retain its identity after an unknown result.
class FuelAction {
  final String id;
  final String action;
  final String _payload;
  Json get payload => jsonDecode(_payload) as Json;
  FuelAction(this.action, Json payload, {String? id})
    : id = id ?? randomId(),
      _payload = jsonEncode(payload) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(this.id) ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(action) ||
        utf8.encode(_payload).length > 65536)
      throw ArgumentError('invalid action');
  }
  factory FuelAction.fromJson(Json value) => FuelAction(
    value['action'] as String,
    value['payload'] as Json,
    id: value['id'] as String,
  );
  Json toJson() => {'id': id, 'action': action, 'payload': payload};
}

class FuelOperation {
  final String id, source, action;
  final String? sessionId, epoch;
  final bool terminal;
  final BigInt cursor;
  final DateTime occurredAt, committedAt;
  final String _json;
  Json get reply => (jsonDecode(_json) as Json)['reply'] as Json;
  FuelOperation.fromJson(Json value)
    : id = value['operation_id'] as String,
      cursor = BigInt.parse(value['cursor'] as String),
      source = value['source'] as String,
      action = value['action'] as String,
      sessionId = value['session_id'] as String?,
      epoch = value['epoch'] as String?,
      terminal = value['terminal'] as bool? ?? false,
      occurredAt = DateTime.fromMillisecondsSinceEpoch(
        (value['occurred_at'] as int) * 1000,
        isUtc: true,
      ),
      committedAt = DateTime.fromMillisecondsSinceEpoch(
        (value['committed_at'] as int) * 1000,
        isUtc: true,
      ),
      _json = jsonEncode(value) {
    if (cursor <= BigInt.zero ||
        !['public', 'effect', 'event'].contains(source) ||
        value['reply'] is! Json) {
      throw const FormatException('invalid_operation');
    }
  }
  Json toJson() => jsonDecode(_json) as Json;
}

extension FuelOperations on FuelClient {
  Future<List<FuelAction>> pendingActions() async {
    final token = generation;
    final actor = account?.id ?? (await refreshAccount()).id;
    _guard(token);
    final value = await _stored(
      () => _journal.readEntry('account:$actor:action'),
      token,
    );
    return value == null ? [] : [FuelAction.fromJson(value)];
  }

  Future<FuelOperation> executeAction(FuelAction intent) {
    if (_actionFlight != null)
      return Future.error(const FuelException('action_busy'));
    final token = generation;
    late Future<FuelOperation> future;
    future =
        () async {
          if (_identityChanging) throw const FuelException('identity_changing');
          if (!_journal.durable)
            throw const FuelException('durable_storage_required');
          final actor = account?.id ?? (await refreshAccount()).id;
          _guard(token);
          final key = 'account:$actor:action';
          await _stored(
            () => _journal.updateEntry(key, (old) {
              if (old != null && jsonEncode(old) != jsonEncode(intent.toJson()))
                throw const FuelException('pending_action');
              return intent.toJson();
            }),
            token,
          );
          return _submitAction(intent, key, token);
        }().whenComplete(() {
          if (identical(_actionFlight, future)) _actionFlight = null;
        });
    _actionFlight = future;
    return future;
  }

  Future<FuelOperation> _submitAction(
    FuelAction intent,
    String key,
    int token, {
    bool recover = false,
  }) async {
    FuelOperation? receipt;
    if (recover) {
      try {
        receipt = FuelOperation.fromJson(
          await _request('GET', 'operations/${Uri.encodeComponent(intent.id)}')
              as Json,
        );
      } on FuelException catch (error) {
        if (error.code != 'not_found') rethrow;
      }
    }
    try {
      receipt ??= FuelOperation.fromJson(
        await _request('POST', 'actions', body: intent.toJson()) as Json,
      );
    } on FuelException catch (error) {
      _guard(token);
      if (error.status >= 400 &&
          error.status < 500 &&
          ![408, 429].contains(error.status)) {
        await _stored(
          () => _journal.updateEntry(
            key,
            (old) => old?['id'] == intent.id ? null : old,
          ),
          token,
        );
      }
      rethrow;
    }
    _guard(token);
    if (receipt.id != intent.id) throw const FuelException('invalid_operation');
    _accountVersion++;
    // A known commit stays successful even if subsequent profile synchronization fails.
    try {
      await _stored(
        () => _journal.updateEntry(
          key,
          (old) => old?['id'] == intent.id ? null : old,
        ),
        token,
      );
      await recoverOperations();
    } catch (error) {
      _guard(token);
      lastError = error;
      _updates.notify();
      _guard(token);
    }
    return receipt;
  }

  Future<List<FuelOperation>> retryPendingActions() {
    if (_actionFlight != null)
      return Future.error(const FuelException('action_busy'));
    final token = generation;
    late Future<FuelOperation> future;
    // Occupy admission before reading storage; another caller cannot race the read.
    future =
        () async {
          if (_identityChanging) throw const FuelException('identity_changing');
          if (!_journal.durable)
            throw const FuelException('durable_storage_required');
          final intents = await pendingActions();
          _guard(token);
          if (intents.isEmpty) throw const FuelException('no_pending_action');
          return _submitAction(
            intents.single,
            'account:${account!.id}:action',
            token,
            recover: true,
          );
        }().whenComplete(() {
          if (identical(_actionFlight, future)) _actionFlight = null;
        });
    _actionFlight = future;
    return future.then(
      (receipt) => [receipt],
      onError: (Object error, StackTrace stack) {
        if (error is FuelException && error.code == 'no_pending_action')
          return <FuelOperation>[];
        Error.throwWithStackTrace(error, stack);
      },
    );
  }

  Future<void> recoverOperations() {
    if (_recoveryFlight != null) return _recoveryFlight!;
    final token = generation;
    late Future<void> future;
    future =
        () async {
          final actor = account?.id ?? (await refreshAccount()).id;
          _guard(token);
          final key = 'account:$actor:operations';
          final saved = await _stored(() => _journal.readEntry(key), token);
          var cursor = BigInt.parse(saved?['cursor'] as String? ?? '0');
          var summary = saved?['last'] == null
              ? null
              : FuelOperation.fromJson(saved!['last'] as Json);
          final fresh = saved == null;
          var data =
              await _request(
                    'GET',
                    'operations',
                    query: {if (!fresh) 'after': '$cursor', 'limit': '65'},
                  )
                  as List;
          _guard(token);
          final gap = !fresh && data.length > 64;
          if (gap)
            data =
                await _request('GET', 'operations', query: {'limit': '64'})
                    as List;
          _guard(token);
          final page = data
              .map((value) => FuelOperation.fromJson(value as Json))
              .toList();
          var previous = cursor;
          for (final receipt in page) {
            if (receipt.cursor <= previous)
              throw const FuelException('invalid_operation_order');
            previous = receipt.cursor;
            if (receipt.terminal) summary = receipt;
          }
          if (page.isNotEmpty) cursor = page.last.cursor;
          if (fresh || gap) {
            final terminalPage =
                await _request(
                      'GET',
                      'operations',
                      query: {'terminal': 'true', 'limit': '1'},
                    )
                    as List;
            _guard(token);
            final terminals = terminalPage
                .map((value) => FuelOperation.fromJson(value as Json))
                .where((value) => value.terminal);
            if (terminals.isNotEmpty &&
                (summary == null || terminals.last.cursor > summary.cursor))
              summary = terminals.last;
          }
          final next = {
            'cursor': '$cursor',
            if (summary != null) 'last': summary.toJson(),
          };
          var claimedAfter = cursor;
          final accepted = await _stored(
            () => _journal.updateEntry(key, (old) {
              claimedAfter = BigInt.parse(old?['cursor'] as String? ?? '0');
              if (old != null && BigInt.parse(old['cursor'] as String) > cursor)
                return old;
              return next;
            }),
            token,
          );
          final recorded = BigInt.parse(accepted!['cursor'] as String);
          _lastOperation = accepted['last'] == null
              ? null
              : FuelOperation.fromJson(accepted['last'] as Json);
          _operationGap = gap;
          if (!fresh && !gap && recorded == cursor) {
            for (final receipt in page.where(
              (value) => value.cursor > claimedAfter,
            )) {
              _guard(token);
              if (receipt.source != 'event') _operationEvents.add(receipt);
              _guard(token);
            }
          }
          _accountVersion++;
          await refreshAccount();
          _guard(token);
          _updates.notify();
          _guard(token);
        }().whenComplete(() {
          if (identical(_recoveryFlight, future)) _recoveryFlight = null;
        });
    _recoveryFlight = future;
    return future;
  }
}
