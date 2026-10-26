part of '../fuel_client.dart';

extension FuelSessionCommands on FuelGameController {
  Future<FuelSnapshot> command(Json action) {
    final current = this.current;
    if (current == null ||
        _inactive ||
        session.status == FuelSessionStatus.lost)
      return Future.error(const FuelException('inactive_session'));
    return _sendCommand(
      FuelCommand(randomId(), current.epoch, current.revision, action),
    );
  }

  Future<FuelSnapshot> retryCommand() => _sendCommand(null);

  Future<void> _recoverCommand() async {
    final actor = client.account?.id;
    if (_commandFlight != null || actor == null || current == null) return;
    final token = _generation, identity = client.generation;
    final pending = await client._stored(
      () => client._journal.readEntry('account:$actor:session_command'),
      identity,
    );
    _guard(token, identity);
    if (_commandFlight != null) return;
    if (pending == null || pending['session_id'] != sessionId) {
      _pendingCommand = null;
      _updates.notify();
      return;
    }
    if (_commandFlight == null) {
      try {
        await retryCommand();
      } on FuelException catch (error) {
        _guard(token, identity);
        if (_pendingCommand != null ||
            ![
              'revision_conflict',
              'conflict',
              'invalid_action',
            ].contains(error.code))
          rethrow;
        // The rejected move is finished; the room itself remains authoritative.
      }
    }
  }

  Future<void> _retireLostCommand(String room) async {
    final actor = client.account?.id;
    if (actor == null) return;
    final token = _generation, identity = client.generation;
    final key = 'account:$actor:session_command';
    final pending = await client._stored(
      () => client._journal.readEntry(key),
      identity,
    );
    _guard(token, identity);
    if (pending?['session_id'] == room) {
      await client._stored(
        () => client._journal.updateEntry(
          key,
          (old) => old?['id'] == pending!['id'] ? null : old,
        ),
        identity,
      );
      _guard(token, identity);
    }
    _pendingCommand = null;
  }

  Future<FuelSnapshot> _sendCommand(FuelCommand? proposed) {
    if (_inactive || current == null)
      return Future.error(const FuelException('inactive_session'));
    if (_commandFlight != null || _joining || _admissionUnknown)
      return Future.error(const FuelException('command_busy'));
    final actor = client.account?.id, id = sessionId;
    if (actor == null || id == null)
      return Future.error(const FuelException('account_required'));
    if (proposed != null &&
        utf8.encode(jsonEncode(proposed.toJson())).length > 65536)
      return Future.error(const FuelException('too_large'));
    final token = _generation, identity = client.generation;
    final selection = session._generation;
    void guard() {
      _guard(token, identity);
      if (session._generation != selection || sessionId != id)
        throw const FuelException('cancelled');
    }

    final key = 'account:$actor:session_command';
    late Future<FuelSnapshot> task;
    task = () async {
      try {
        guard();
        final entry = await client._stored(
          () => proposed == null
              ? client._journal.readEntry(key)
              : client._journal.updateEntry(
                  key,
                  (old) => old ?? {'session_id': id, ...proposed.toJson()},
                ),
          identity,
        );
        guard();
        if (entry == null || entry['session_id'] != id) {
          _pendingCommand = null;
          _updates.notify();
          throw FuelException(entry == null ? 'not_found' : 'pending_command');
        }
        final command = FuelCommand(
          entry['id'] as String,
          entry['epoch'] as String,
          BigInt.parse(entry['revision'] as String),
          entry['action'] as Json,
        );
        _pendingCommand = command;
        _updates.notify();
        guard();
        Future<void> forget() async {
          await client._stored(
            () => client._journal.updateEntry(
              key,
              (old) => old?['id'] == command.id ? null : old,
            ),
            identity,
          );
          guard();
          _pendingCommand = null;
          _updates.notify();
          guard();
        }

        if (command.epoch != current!.epoch) {
          await forget();
          throw const FuelException('session_lost');
        }
        if (proposed != null && command.id != proposed.id)
          throw const FuelException('pending_command');
        try {
          final reply = FuelSnapshot.fromJson(
            await client.command(id, command),
          );
          guard();
          if (reply.sessionId != id || reply.epoch != command.epoch)
            throw const FuelException('invalid_snapshot');
          await forget();
          lastError = null;
          session.accept(reply);
          guard();
          return reply;
        } on FuelException catch (error) {
          guard();
          if (error.status >= 400 &&
              error.status < 500 &&
              ![408, 429].contains(error.status)) {
            await forget();
            if ([
              'session_lost',
              'session_ended',
              'not_found',
              'forbidden',
            ].contains(error.code))
              _failed(error);
            if (['revision_conflict', 'conflict'].contains(error.code)) {
              final snapshot =
                  await client.request(
                        'GET',
                        'sessions/${Uri.encodeComponent(id)}',
                      )
                      as Json;
              guard();
              session.accept(FuelSnapshot.fromJson(snapshot));
            }
          }
          rethrow;
        }
      } catch (error) {
        guard();
        lastError = error;
        _updates.notify();
        rethrow;
      } finally {
        if (identical(_commandFlight, task)) {
          _commandFlight = null;
          if (!_updates.isClosed) _updates.notify();
        }
      }
    }();
    _commandFlight = task;
    return task;
  }
}
