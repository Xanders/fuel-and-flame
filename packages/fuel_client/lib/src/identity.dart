part of '../fuel_client.dart';

extension FuelIdentity on FuelClient {
  Future<void> prepareTransfer({
    CredentialVault? vault,
    bool newAttempt = false,
  }) async {
    if (_preparingTransfer || _identityChanging || _identityUncertain)
      throw const FuelException('identity_changing');
    _preparingTransfer = true;
    final token = generation;
    try {
      final storage = vault ?? _vault;
      if (storage == null) {
        await request(
          'GET',
          'auth/pair/prepare',
          query: {if (newAttempt) 'new': 'true'},
        );
      } else {
        _vault = storage;
        _journal = storage;
        var candidate = await _stored(() => storage.read('candidate'), token);
        final previous = await _stored(() => storage.read('previous'), token);
        var renew =
            newAttempt ||
            candidate == null ||
            candidate.id == _credential?.id ||
            candidate.id == previous?.id;
        if (!renew) {
          try {
            final result =
                await request(
                      'GET',
                      'auth/pair/status',
                      authentication: candidate,
                    )
                    as Json;
            renew = ['expired', 'cancelled'].contains(result['status']);
          } on FuelException catch (error) {
            if (!['unauthorized', 'invalid_code'].contains(error.code)) rethrow;
          }
        }
        candidate = renew ? FuelCredential.create() : candidate;
        await _stored(() => storage.write('candidate', candidate!), token);
        _candidate = candidate;
      }
      _guard(token);
    } finally {
      _preparingTransfer = false;
    }
  }

  Future<Json> activateTransfer({CredentialVault? vault}) =>
      _changeSelection('activate', vault);
  Future<void> switchPrevious({CredentialVault? vault}) async {
    await _changeSelection('switch', vault);
  }

  Future<Json> _changeSelection(
    String kind,
    CredentialVault? vault,
  ) => _withIdentity((token) async {
    if (vault != null) {
      _vault = vault;
      _journal = vault;
    }
    if (!_journal.durable)
      throw const FuelException('durable_storage_required');
    var intent = await _stored(() => _journal.readEntry('selection'), token);
    if (intent != null && intent['kind'] != kind)
      throw const FuelException('pending_identity');
    if (intent == null) {
      String? from, to;
      if (_vault != null) {
        from = (await _stored(() => _vault!.read('active'), token))?.id;
        to = (await _stored(
          () => _vault!.read(kind == 'switch' ? 'previous' : 'candidate'),
          token,
        ))?.id;
        if (to == null)
          throw FuelException(
            kind == 'switch' ? 'missing_previous' : 'missing_candidate',
          );
        if (kind == 'activate') {
          final proof = await _stored(() => _vault!.read('binding:$to'), token);
          final status =
              await _request('GET', 'auth/pair/status', authentication: proof)
                  as Json;
          if (status['status'] != 'linked')
            throw const FuelException('confirmation_required');
        }
      } else {
        final selected = await _request('GET', 'auth/selection') as Json;
        from = (selected['current'] as Json?)?['binding_id'] as String?;
        to = kind == 'activate'
            ? selected['candidate_id'] as String?
            : (selected['previous'] as Json?)?['binding_id'] as String?;
        if (to == null || kind == 'switch' && to == from)
          throw FuelException(
            kind == 'switch' ? 'missing_previous' : 'missing_candidate',
          );
      }
      final proposed = <String, dynamic>{
        'id': randomId(),
        'kind': kind,
        'from': from,
        'to': to,
      };
      intent = await _stored(
        () => _journal.updateEntry('selection', (old) => old ?? proposed),
        token,
      );
      if (intent!['kind'] != kind)
        throw const FuelException('pending_identity');
    }
    final value = await _resumeSelection(token);
    if (value == null) throw const FuelException('pending_identity');
    _publishAccount(value, token);
    return <String, dynamic>{'account_id': value.id};
  });

  Future<FuelAccount?> _resumeSelection(int token) async {
    final intent = await _stored(() => _journal.readEntry('selection'), token);
    if (intent == null) return null;
    try {
      FuelAccount value;
      if (_vault != null) {
        final proof = await _stored(
          () => _vault!.read('binding:${intent['to']}'),
          token,
        );
        if (proof == null) throw const FuelException('missing_binding');
        value = FuelAccount.fromJson(
          await _request('GET', 'account', authentication: proof) as Json,
        );
        _guard(token);
        await _stored(
          () => _vault!.activate(
            proof,
            accountId: value.id,
            selectionId: intent['id'] as String,
          ),
          token,
        );
        _credential = proof;
      } else {
        final result =
            await _request(
                  'POST',
                  intent['kind'] == 'switch'
                      ? 'auth/switch'
                      : 'auth/pair/activate',
                  body: intent['kind'] == 'switch'
                      ? {'from': intent['from'], 'to': intent['to']}
                      : {'target_id': intent['to']},
                )
                as Json;
        value = await _readAccount(token);
        if (result['account_id'] != value.id)
          throw const FuelException('selection_changed');
        await _stored(
          () => _journal.completeSelection(intent['id'] as String, {
            'kind': 'active',
            'account_id': value.id,
          }),
          token,
        );
      }
      return value;
    } on FuelException catch (error) {
      _guard(token);
      if (error.status >= 400 &&
          error.status < 500 &&
          ![408, 429].contains(error.status)) {
        await _stored(
          () => _journal.updateEntry(
            'selection',
            (old) => old?['id'] == intent['id'] ? null : old,
          ),
          token,
        );
      }
      rethrow;
    }
  }

  Future<void> deleteAccount({required bool confirmed}) {
    if (!confirmed)
      return Future.error(const FuelException('confirmation_required'));
    final actor = account?.id;
    if (actor == null)
      return Future.error(const FuelException('account_required'));
    return _withIdentity((token) async {
      if (!_journal.durable)
        throw const FuelException('durable_storage_required');
      final intent = await _stored(
        () => _journal.updateEntry(
          'account:$actor:deletion',
          (old) => old ?? {'account_id': actor, 'proof': randomId(32)},
        ),
        token,
      );
      await _finishDeletion(intent!, token);
      _identityUncertain = false;
      _accountStatus = FuelAccountStatus.deleted;
      _updates.notify();
      _guard(token);
    });
  }

  Future<void> recoverDeletion() => _withIdentity((token) async {
    await _resumeDeletions(token);
    _identityUncertain = false;
    final marker = await _stored(() => _journal.readEntry('identity'), token);
    _accountStatus = marker?['kind'] == 'deleted'
        ? FuelAccountStatus.deleted
        : FuelAccountStatus.idle;
  });

  Future<void> _resumeDeletions(int token) async {
    final intents = await _stored(() => _journal.entries('account:'), token);
    for (final entry in intents.entries.where(
      (entry) => entry.key.endsWith(':deletion'),
    )) {
      await _finishDeletion(entry.value, token);
    }
  }

  Future<void> _finishDeletion(Json intent, int token) async {
    var result =
        await _request('POST', 'auth/delete/status', body: intent) as Json;
    _guard(token);
    if (result['status'] == 'unknown')
      result =
          await _request(
                'POST',
                'auth/delete',
                body: {...intent, 'confirmed': true},
              )
              as Json;
    _guard(token);
    if (result['status'] != 'deleted')
      throw const FuelException('deletion_pending');
    final removed = (result['removed_bindings'] as List).cast<String>();
    await _stored(
      () => _journal.completeDeletion(intent['account_id'] as String, removed),
      token,
    );
    if (removed.contains(_credential?.id)) _credential = null;
    if (removed.contains(_candidate?.id)) _candidate = null;
  }
}
