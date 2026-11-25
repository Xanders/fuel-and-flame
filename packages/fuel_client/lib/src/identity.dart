part of '../fuel_client.dart';

class _FuelInitialRecovery {
  final void Function() check;
  _FuelInitialRecovery(this.check);

  static bool transient(Object error) =>
      error is http.ClientException ||
      error is TimeoutException ||
      error is FuelException &&
          (error.code == 'timeout' ||
              error.status >= 500 ||
              [408, 429].contains(error.status));

  Future<T> read<T>(
    Future<T> Function() request, {
    bool pending = false,
  }) async {
    for (var attempt = 0; ; attempt++) {
      check();
      try {
        final value = await request();
        check();
        return value;
      } catch (error) {
        check();
        final unsettled =
            pending &&
            error is FuelException &&
            error.status == 401 &&
            error.code == 'unauthorized';
        if (attempt == 3 || !transient(error) && !unsettled) rethrow;
        await Future<void>.delayed(
          Duration(milliseconds: 500 * (1 << attempt)),
        );
      }
    }
  }
}

extension FuelIdentity on FuelClient {
  /// Read-only UI hint. A retained binding may have been revoked elsewhere;
  /// switching still uses the normal verified identity transition.
  Future<bool> hasPreviousAccount() async {
    if (_identityChanging || _identityUncertain) {
      throw const FuelException('identity_changing');
    }
    final token = generation;
    _guard(token);
    if (_vault case final vault?) {
      final previous = await _stored(() => vault.read('previous'), token);
      _guard(token);
      return previous != null && previous.id != _credential?.id;
    }
    final available = await _withBrowserIdentity(() async {
      _guard(token);
      final selected = await _request('GET', 'auth/selection') as Json;
      _guard(token);
      final previous = selected['previous'], current = selected['current'];
      if (previous == null) return false;
      if (previous is! Map ||
          previous['binding_id'] is! String ||
          (previous['binding_id'] as String).isEmpty ||
          current != null &&
              (current is! Map || current['binding_id'] is! String)) {
        throw const FormatException('invalid_selection');
      }
      return previous['binding_id'] != (current as Map?)?['binding_id'];
    });
    _guard(token);
    return available;
  }

  Future<void> prepareTransfer({
    CredentialVault? vault,
    bool newAttempt = false,
  }) async {
    if (_preparingTransfer || _identityAdmitted || _identityUncertain)
      throw const FuelException('identity_changing');
    _preparingTransfer = true;
    final token = generation;
    try {
      await _withBrowserIdentity(() async {
        _guard(token);
        final storage = vault ?? _vault;
        final pending = await _stored(
          () => (storage ?? _journal).readEntry('selection'),
          token,
        );
        if (pending?['kind'] == 'basic') {
          throw const FuelException('pending_identity');
        }
        if (storage == null) {
          await request(
            'GET',
            'auth/pair/prepare',
            query: {'flow': 'basic-v1', if (newAttempt) 'new': 'true'},
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
                        query: {'target_id': candidate.id},
                        authentication: candidate,
                      )
                      as Json;
              renew = [
                'expired',
                'cancelled',
                'retired',
              ].contains(result['status']);
            } on FuelException catch (error) {
              if (!['unauthorized', 'invalid_code'].contains(error.code))
                rethrow;
            }
          }
          candidate = renew ? FuelCredential.create() : candidate;
          await _stored(() => storage.write('candidate', candidate!), token);
          _candidate = candidate;
        }
        _guard(token);
      });
    } finally {
      _preparingTransfer = false;
    }
  }

  /// Selects the confirmed candidate. Pass the account shown to the user in
  /// [expectedAccountId] to reject a selection that changed in another tab.
  Future<Json> activateTransfer({
    CredentialVault? vault,
    String? expectedAccountId,
  }) =>
      _changeSelection('activate', vault, expectedAccountId: expectedAccountId);

  /// Redeems a basic code with the proof saved by [prepareTransfer].
  Future<Json> redeemBasicTransfer(String code) =>
      _selectBasicTransfer(normalizeCode(code));

  /// After a lost response, selects an already linked basic candidate.
  /// Never submits the code again or links a new candidate.
  Future<Json> recoverBasicTransfer() => _selectBasicTransfer(null);

  Future<Json> _selectBasicTransfer(String? code) async {
    if (_preparingTransfer) {
      throw const FuelException('identity_changing');
    }
    final sourceAccount = _account?.id;
    final sourceBinding = _credential?.id;
    Future<(Json, bool)> readFreshSelection(int token) async {
      final vault = _vault;
      final browser = vault == null
          ? await _request('GET', 'auth/selection') as Json
          : null;
      final proposed = await _proposeSelection(
        'basic',
        vault,
        token,
        browser: browser,
      );
      final current = browser?['current'] as Json?;
      final sourceChanged = vault == null
          ? sourceAccount != null && (current?['account_id']) != sourceAccount
          : sourceBinding != null && proposed['from'] != sourceBinding;
      return (proposed, sourceChanged);
    }

    List<Json>? deletions;
    (Json, bool)? checked;
    var sourceUncertain = false;
    final (result, rejected) = await _withIdentity<(Json?, Object?)>(
      (token) async {
        if (!_journal.durable) {
          throw const FuelException('durable_storage_required');
        }
        await _resumeDeletions(token, pending: deletions);
        var intent = await _stored(
          () => _journal.readEntry('selection'),
          token,
        );
        final fresh = intent == null;
        if (intent != null && intent['kind'] != 'basic') {
          throw const FuelException('pending_identity');
        }
        if (intent == null) {
          if (code == null) throw const FuelException('missing_transfer');
          if (sourceUncertain) throw const FuelException('identity_pending');
          final (proposed, sourceChanged) =
              checked ?? await readFreshSelection(token);
          try {
            if (sourceChanged) throw const FuelException('selection_changed');
            if (checked == null) {
              await _requireUnusedBasicCandidate(proposed, token);
            }
          } catch (error) {
            final current = await _verifiedBasicSource(proposed, token);
            if (current != null) _publishAccount(current, token);
            return (null, error);
          }
          intent = await _saveBasicSelection(proposed, token);
        }
        Json? receipt;
        if (code != null) {
          try {
            receipt =
                await _request(
                      'POST',
                      'auth/pair/redeem',
                      body: {
                        'code': code,
                        'target_id': intent['to'],
                        'from': intent['from'],
                      },
                      authentication: await _basicProof(intent, token),
                    )
                    as Json;
          } on FuelException catch (error) {
            if (!_basicRejectionBeforeCommit(error)) rethrow;
            // A rejected retry does not disprove an earlier unknown POST.
            if (fresh) await _discardBasicSelection(intent, token);
            final previous = await _verifiedBasicSource(intent, token);
            if (previous != null) _publishAccount(previous, token);
            return (null, error);
          }
        }
        try {
          final (value, linked) = await _finishBasicSelection(
            intent,
            token,
            receipt,
          );
          _publishAccount(value, token);
          return (linked, null);
        } on FuelException catch (error) {
          final retired = error.code == 'transfer_retired';
          if (!retired && error.code != 'transfer_pending') rethrow;
          final previous = await _verifiedBasicSource(intent, token);
          if (retired) await _discardBasicSelection(intent, token);
          if (previous == null) rethrow;
          _publishAccount(previous, token);
          return (null, error);
        }
      },
      beforeTransition: code == null
          ? _requireBasicSelection
          : (token) async {
              if (!_journal.durable) {
                throw const FuelException('durable_storage_required');
              }
              sourceUncertain = _identityUncertain;
              final saved = await _stored(
                () => _journal.readEntry('selection'),
                token,
              );
              if (saved != null) return;
              if (sourceUncertain) {
                throw const FuelException('identity_pending');
              }
              final pending = await _pendingDeletions(token);
              deletions = pending;
              if (pending.isNotEmpty) return;
              final (proposed, sourceChanged) = await readFreshSelection(token);
              if (!sourceChanged) {
                await _requireUnusedBasicCandidate(proposed, token);
              }
              checked = (proposed, sourceChanged);
            },
    );
    if (rejected != null) throw rejected;
    return result!;
  }

  Future<void> _requireBasicSelection(int token) async {
    final intent = await _stored(() => _journal.readEntry('selection'), token);
    if (intent == null) {
      if (_browserRecords != null) await _checkBrowserSelection();
      _guard(token);
      throw const FuelException('missing_transfer');
    }
    if (intent['kind'] != 'basic')
      throw const FuelException('pending_identity');
  }

  Future<void> _requireUnusedBasicCandidate(Json proposed, int token) async {
    final target = proposed['to'] as String;
    if (target == proposed['from']) {
      throw const FuelException('selection_changed');
    }
    final proof = await _basicProof(proposed, token);
    try {
      await _request(
        'GET',
        'auth/pair/status',
        query: {'target_id': target},
        authentication: proof,
      );
    } on FuelException catch (error) {
      // Fuel has no status row for a newly prepared proof.
      if ((error.status, error.code) == (401, 'unauthorized') ||
          (error.status, error.code) == (400, 'invalid_code')) {
        return;
      }
      rethrow;
    }
    throw const FuelException('selection_changed');
  }

  Future<Json> _saveBasicSelection(Json proposed, int token) async {
    final saved = await _stored(
      () => _journal.updateEntry('selection', (old) => old ?? proposed),
      token,
    );
    if (saved?['id'] != proposed['id']) {
      throw const FuelException('pending_identity');
    }
    return saved!;
  }

  Future<FuelCredential?> _basicProof(Json intent, int token) async {
    final vault = _vault;
    if (vault == null) return null;
    final proof = await _stored(
      () => vault.read('binding:${intent['to']}'),
      token,
    );
    if (proof == null || proof.id != intent['to']) {
      throw const FuelException('missing_candidate');
    }
    return proof;
  }

  bool _basicRejectionBeforeCommit(FuelException error) =>
      switch ((error.status, error.code)) {
        (400, 'invalid_code') ||
        (400, 'selection_changed') ||
        (401, 'unauthorized') ||
        (403, 'forbidden') ||
        (429, 'rate_limited') ||
        (503, 'maintenance') => true,
        _ => false,
      };

  Future<void> _discardBasicSelection(Json intent, int token) async {
    await _stored(
      () => _journal.updateEntry(
        'selection',
        (old) => old?['id'] == intent['id'] ? null : old,
      ),
      token,
    );
  }

  // An unlinked read does not disprove a delayed POST. Verify the exact old
  // selected proof, leaving the frozen candidate and intent in place.
  Future<FuelAccount?> _verifiedBasicSource(Json intent, int token) async {
    final from = intent['from'] as String?;
    if (from == null) return null;
    if (_vault case final vault?) {
      final active = await _stored(() => vault.read('active'), token);
      if (active?.id != from) return null;
      try {
        final value = FuelAccount.fromJson(
          await _request('GET', 'account', authentication: active) as Json,
        );
        _guard(token);
        _credential = active;
        return value;
      } on FuelException catch (error) {
        if (error.status != 401 || error.code != 'unauthorized') rethrow;
        return null;
      }
    }
    final slots = await _request('GET', 'auth/selection') as Json;
    final current = slots['current'] as Json?;
    final previous = slots['previous'] as Json?;
    final revokedTarget =
        current != null &&
        current['binding_id'] == intent['to'] &&
        current['account_id'] == null &&
        previous?['binding_id'] == from;
    final expected = revokedTarget
        ? previous!['account_id']
        : (current?['binding_id'] == from ? current!['account_id'] : null);
    if (expected is! String) return null;
    if (revokedTarget) {
      final saved = await _stored(
        () => _journal.updateEntry(
          'selection',
          (old) => old?['id'] == intent['id']
              ? {...old!, 'restore_source': true}
              : old,
        ),
        token,
      );
      if (saved?['id'] != intent['id']) {
        throw const FuelException('selection_changed');
      }
      final selected =
          await _request(
                'POST',
                'auth/switch',
                body: {'from': intent['to'], 'to': from},
              )
              as Json;
      if (selected['account_id'] != expected) {
        throw const FuelException('selection_changed');
      }
    }
    final value = await _readAccount(token);
    if (value.id != expected) {
      throw const FuelException('selection_changed');
    }
    if (revokedTarget || intent['restore_source'] == true) {
      await _discardBasicSelection(intent, token);
    }
    return value;
  }

  Future<(FuelAccount, Json)> _finishBasicSelection(
    Json intent,
    int token,
    Json? receipt,
  ) async {
    final vault = _vault;
    final proof = await _basicProof(intent, token);
    final target = intent['to'] as String;
    final recovering = receipt == null;
    if (receipt == null) {
      try {
        receipt =
            await _request(
                  'GET',
                  'auth/pair/status',
                  query: {'target_id': target},
                  authentication: proof,
                )
                as Json;
      } on FuelException catch (error) {
        if (!['invalid_code', 'unauthorized'].contains(error.code)) rethrow;
        throw const FuelException('transfer_pending');
      }
    }
    if (receipt['status'] == 'retired') {
      throw const FuelException('transfer_retired');
    }
    final accountId = receipt['account_id'];
    if (receipt['status'] != 'linked' ||
        receipt['mode'] != 'basic' ||
        accountId is! String) {
      throw const FuelException('transfer_pending');
    }
    if (vault == null && recovering) {
      final selected =
          await _request(
                'POST',
                'auth/pair/activate',
                body: {'target_id': target, 'from': intent['from']},
              )
              as Json;
      if (selected['account_id'] != accountId) {
        throw const FuelException('selection_changed');
      }
    }
    final value = FuelAccount.fromJson(
      await _request('GET', 'account', authentication: proof) as Json,
    );
    _guard(token);
    if (value.id != accountId) {
      throw const FuelException('selection_changed');
    }
    final id = intent['id'] as String;
    if (vault != null) {
      final active = (await _stored(() => vault.read('active'), token))?.id;
      if (active != intent['from'] && active != target) {
        throw const FuelException('selection_changed');
      }
      await _stored(
        () => vault.activate(proof!, accountId: value.id, selectionId: id),
        token,
      );
      _credential = proof;
    } else {
      await _stored(
        () => _journal.completeSelection(id, {
          'kind': 'active',
          'account_id': value.id,
        }),
        token,
      );
    }
    return (value, receipt);
  }

  Future<void> switchPrevious({CredentialVault? vault}) async {
    await _changeSelection('switch', vault);
  }

  Future<Json> _changeSelection(
    String kind,
    CredentialVault? vault, {
    String? expectedAccountId,
  }) async {
    Json? checked;
    ({Json? current, Json? pending})? reconcile;
    final result = await _withIdentity<Json?>(
      (token) async {
        if (vault != null) {
          _vault = vault;
          _journal = vault;
        }
        if (!_journal.durable)
          throw const FuelException('durable_storage_required');
        if (reconcile case final state?) {
          FuelCredential? proof;
          final FuelAccount value;
          if (_vault case final storage?) {
            proof = await _stored(() => storage.read('active'), token);
            if (proof == null) throw const FuelException('missing_binding');
            value = FuelAccount.fromJson(
              await _request('GET', 'account', authentication: proof) as Json,
            );
          } else {
            value = await _readAccount(token);
            if (value.id != state.current?['account_id']) {
              throw const FuelException('selection_changed');
            }
          }
          final pending = state.pending;
          if (pending != null) {
            await _stored(
              () => _journal.completeSelection(pending['id'] as String, {
                'kind': 'active',
                'account_id': value.id,
              }),
              token,
            );
          }
          if (proof != null) _credential = proof;
          _publishAccount(value, token);
          final completed =
              pending != null &&
              state.current?['binding_id'] == pending['to'] &&
              value.id == expectedAccountId;
          return completed ? {'account_id': value.id} : null;
        }
        var intent = await _stored(
          () => _journal.readEntry('selection'),
          token,
        );
        if (intent != null && intent['kind'] != kind)
          throw const FuelException('pending_identity');
        if (intent == null) {
          final proposed =
              checked ?? await _proposeSelection(kind, _vault, token);
          if (checked == null && _vault != null && kind == 'activate') {
            final proof = await _stored(
              () => _vault!.read('binding:${proposed['to']}'),
              token,
            );
            final status =
                await _request('GET', 'auth/pair/status', authentication: proof)
                    as Json;
            if (status['status'] != 'linked')
              throw const FuelException('confirmation_required');
          }
          intent = await _stored(
            () => _journal.updateEntry('selection', (old) => old ?? proposed),
            token,
          );
          if (intent!['kind'] != kind)
            throw const FuelException('pending_identity');
        }
        if (checked != null &&
            (intent['to'] != checked!['to'] ||
                intent['from'] != checked!['from'])) {
          throw const FuelException('selection_changed');
        }
        final value = await _resumeSelection(
          token,
          saved: checked == null ? null : intent,
        );
        if (value == null) throw const FuelException('pending_identity');
        _publishAccount(value.account, token);
        return <String, dynamic>{'account_id': value.account.id};
      },
      beforeTransition: kind == 'switch' || expectedAccountId != null
          ? (token) async {
              final storage = vault ?? _journal;
              final pending = await _stored(
                () => storage.readEntry('selection'),
                token,
              );
              if (pending != null && pending['kind'] != kind) {
                throw const FuelException('pending_identity');
              }
              if (expectedAccountId != null) {
                if (!storage.durable) {
                  throw const FuelException('durable_storage_required');
                }
                final nativeVault = vault ?? _vault;
                Json? browser;
                Json? current;
                if (nativeVault == null) {
                  browser = await _request('GET', 'auth/selection') as Json;
                  current = browser['current'] as Json?;
                  final binding = current?['binding_id'];
                  final changed = pending == null
                      ? (current?['account_id']) != _account?.id
                      : binding != pending['from'] ||
                            browser['candidate_id'] != pending['to'];
                  if (changed) {
                    reconcile = (current: current, pending: pending);
                    return;
                  }
                }
                final selection =
                    pending ??
                    await _proposeSelection(
                      kind,
                      nativeVault,
                      token,
                      browser: browser,
                    );
                final target = selection['to'] as String;
                final proof = nativeVault == null
                    ? null
                    : await _stored(
                        () => nativeVault.read('binding:$target'),
                        token,
                      );
                if (nativeVault != null && proof?.id != target) {
                  throw const FuelException('missing_binding');
                }
                Json? status;
                try {
                  status =
                      await _request(
                            'GET',
                            'auth/pair/status',
                            query: {'target_id': target},
                            authentication: proof,
                          )
                          as Json;
                } on FuelException catch (error) {
                  if (pending == null ||
                      error.status != 401 ||
                      error.code != 'unauthorized') {
                    rethrow;
                  }
                }
                if (pending != null &&
                    (status == null || status['status'] == 'retired')) {
                  reconcile = (current: current, pending: pending);
                  return;
                }
                if (status?['status'] != 'linked') {
                  throw const FuelException('confirmation_required');
                }
                if (status!['account_id'] != expectedAccountId) {
                  throw const FuelException('selection_changed');
                }
                checked = selection;
              }
            }
          : null,
    );
    if (result == null) throw const FuelException('selection_changed');
    return result;
  }

  Future<Json> _proposeSelection(
    String kind,
    CredentialVault? vault,
    int token, {
    Json? browser,
  }) async {
    String? from, to;
    if (vault != null) {
      from = (await _stored(() => vault.read('active'), token))?.id;
      to = (await _stored(
        () => vault.read(kind == 'switch' ? 'previous' : 'candidate'),
        token,
      ))?.id;
    } else {
      final selected =
          browser ?? await _request('GET', 'auth/selection') as Json;
      from = (selected['current'] as Json?)?['binding_id'] as String?;
      to = kind != 'switch'
          ? selected['candidate_id'] as String?
          : (selected['previous'] as Json?)?['binding_id'] as String?;
      if (kind == 'switch' && to == from) to = null;
    }
    if (to == null) {
      throw FuelException(
        kind == 'switch' ? 'missing_previous' : 'missing_candidate',
      );
    }
    return {'id': randomId(), 'kind': kind, 'from': from, 'to': to};
  }

  Future<Json?> _resumeStartupSelection(int token) async {
    final resumed = await _resumeSelection(token);
    if (resumed == null) return null;
    _guard(token);
    _recoveredBasicTransferOnStartup = resumed.recoveredBasicTransfer;
    _publishAccount(resumed.account, token);
    return <String, dynamic>{'account_id': resumed.account.id};
  }

  Future<({FuelAccount account, bool recoveredBasicTransfer})?>
  _resumeSelection(int token, {Json? saved}) async {
    final intent =
        saved ?? await _stored(() => _journal.readEntry('selection'), token);
    if (intent == null) return null;
    if (intent['kind'] == 'basic') {
      try {
        final (value, _) = await _finishBasicSelection(intent, token, null);
        return (account: value, recoveredBasicTransfer: true);
      } on FuelException catch (error) {
        final retired = error.code == 'transfer_retired';
        if (!retired && error.code != 'transfer_pending') rethrow;
        final previous = await _verifiedBasicSource(intent, token);
        if (retired) await _discardBasicSelection(intent, token);
        if (previous != null) {
          return (account: previous, recoveredBasicTransfer: false);
        }
        if (retired) return null;
        try {
          final result =
              await _request(
                    'POST',
                    'auth/pair/abandon',
                    body: {'target_id': intent['to']},
                    authentication: await _basicProof(intent, token),
                  )
                  as Json;
          if (result['status'] != 'retired') throw error;
          await _discardBasicSelection(intent, token);
          return null;
        } on FuelException catch (settlement) {
          if (settlement.code != 'transfer_completed') rethrow;
          final (value, _) = await _finishBasicSelection(intent, token, null);
          return (account: value, recoveredBasicTransfer: true);
        }
      }
    }
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
                      : {'target_id': intent['to'], 'from': intent['from']},
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
      return (account: value, recoveredBasicTransfer: false);
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
      final transfer = await _stored(
        () => _journal.readEntry('selection'),
        token,
      );
      final intent = await _stored(
        () => _journal.updateEntry(
          'account:$actor:deletion',
          (old) => old != null && old['status_only'] != true
              ? old
              : {
                  'account_id': actor,
                  'proof': old?['proof'] ?? randomId(32),
                  if (transfer?['kind'] == 'basic')
                    'abandon_candidate_id': transfer!['to'],
                },
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
    final marker = await _stored(() => _journal.readEntry('identity'), token);
    if (marker?['kind'] == 'deleted') {
      _identityUncertain = false;
      _accountStatus = FuelAccountStatus.deleted;
    } else {
      final selected = await _resumeSelection(token);
      _publishAccount(selected?.account ?? await _readAccount(token), token);
    }
  });

  Future<List<Json>> _pendingDeletions(int token) async {
    final intents = await _stored(() => _journal.entries('account:'), token);
    return [
      for (final entry in intents.entries)
        if (entry.key.endsWith(':deletion')) entry.value,
    ];
  }

  Future<void> _resumeDeletions(int token, {List<Json>? pending}) async {
    for (final intent in pending ?? await _pendingDeletions(token)) {
      try {
        await _finishDeletion(intent, token, recovering: true);
      } on FuelException catch (error) {
        if (error.code != 'transfer_completed') rethrow;
      }
    }
  }

  Future<void> _finishDeletion(
    Json intent,
    int token, {
    bool recovering = false,
  }) async {
    final candidate = intent['abandon_candidate_id'] as String?;
    var result =
        await _request('POST', 'auth/delete/status', body: intent) as Json;
    _guard(token);
    if (result['status'] == 'unknown') {
      if (intent['status_only'] == true) return;
      final body = {...intent, 'confirmed': true};
      final vault = _vault;
      if (candidate != null && vault != null) {
        final proof = await _stored(
          () => vault.read('binding:$candidate'),
          token,
        );
        if (proof == null) throw const FuelException('missing_candidate');
        body['abandon_candidate_secret'] = proof.secret;
      }
      try {
        final path = candidate == null
            ? 'auth/delete'
            : 'auth/delete/with-transfer';
        result = await _request('POST', path, body: body) as Json;
      } on FuelException catch (error) {
        if (candidate == null) rethrow;
        final completed = error.code == 'transfer_completed';
        final authorityLost =
            error.status == 401 && error.code == 'unauthorized';
        if (!completed && !authorityLost) rethrow;
        await _stored(
          () => _journal.updateEntry(
            'account:${intent['account_id']}:deletion',
            (old) {
              if (old == null || old['proof'] != intent['proof']) return old;
              return completed ? null : {...old, 'status_only': true};
            },
          ),
          token,
        );
        if (!authorityLost || !recovering) rethrow;
        result =
            await _request('POST', 'auth/delete/status', body: intent) as Json;
        if (result['status'] == 'unknown') return;
      }
    }
    _guard(token);
    if (result['status'] != 'deleted')
      throw const FuelException('deletion_pending');
    final removed = (result['removed_bindings'] as List).cast<String>();
    if (candidate != null && removed.contains(candidate)) {
      final transfer = await _stored(
        () => _journal.readEntry('selection'),
        token,
      );
      if (transfer?['kind'] == 'basic' && transfer?['to'] == candidate) {
        await _discardBasicSelection(transfer!, token);
      }
    }
    await _stored(
      () => _journal.completeDeletion(intent['account_id'] as String, removed),
      token,
    );
    if (removed.contains(_credential?.id)) _credential = null;
    if (removed.contains(_candidate?.id)) _candidate = null;
  }
}
