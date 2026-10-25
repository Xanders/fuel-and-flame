part of '../fuel_client.dart';

class _BrowserFuelJournal extends RecordJournal {
  final platform.BrowserRecordPort port;
  _BrowserFuelJournal(this.port)
    : super(read: port.read, write: port.write, lock: port.lock);
}

abstract interface class FuelJournal {
  bool get durable;
  Future<Json?> readEntry(String key);
  Future<void> writeEntry(String key, Json? value);
  Future<Json?> updateEntry(String key, Json? Function(Json?) update);
  Future<Map<String, Json>> entries(String prefix);
  Future<void> completeSelection(String intentId, Json identity);
  Future<void> completeDeletion(String accountId, List<String> removedBindings);
}

/// Native ports store secrets in OS secure storage. Use one vault per record pair.
abstract interface class CredentialVault implements FuelJournal {
  Future<FuelCredential?> read(String slot);
  Future<void> write(String slot, FuelCredential credential);
  Future<void> activate(
    FuelCredential credential, {
    String? accountId,
    String? selectionId,
  });
}

Json _copyJson(Json value) => jsonDecode(jsonEncode(value)) as Json;

void _completeSelection(Json journal, String intentId, Json identity) {
  final pending = journal['selection'] as Json?;
  if (pending == null &&
      (journal['identity'] as Json?)?['selection_id'] == intentId)
    return;
  if (pending?['id'] != intentId)
    throw const FuelException('selection_changed');
  journal['identity'] = {..._copyJson(identity), 'selection_id': intentId};
  journal.remove('selection');
}

class MemoryFuelJournal implements FuelJournal {
  final _entries = <String, Json>{};
  @override
  bool get durable => false;
  @override
  Future<void> completeSelection(String intentId, Json identity) async {
    _completeSelection(_entries, intentId, identity);
  }

  @override
  Future<Json?> readEntry(String key) async =>
      _entries[key] == null ? null : _copyJson(_entries[key]!);
  @override
  Future<void> writeEntry(String key, Json? value) async {
    if (value == null) {
      _entries.remove(key);
    } else {
      _entries[key] = _copyJson(value);
    }
  }

  @override
  Future<Json?> updateEntry(String key, Json? Function(Json?) update) async {
    final old = _entries[key];
    final value = update(old == null ? null : _copyJson(old));
    if (value == null) {
      _entries.remove(key);
    } else {
      _entries[key] = _copyJson(value);
    }
    return value == null ? null : _copyJson(value);
  }

  @override
  Future<Map<String, Json>> entries(String prefix) async => {
    for (final entry in _entries.entries)
      if (entry.key.startsWith(prefix)) entry.key: _copyJson(entry.value),
  };
  @override
  Future<void> completeDeletion(
    String accountId,
    List<String> removedBindings,
  ) async {
    _entries.removeWhere((key, _) => key.startsWith('account:$accountId:'));
    final current = _entries['identity'];
    if (current?['kind'] != 'active' ||
        current?['account_id'] is! String ||
        current?['account_id'] == accountId) {
      _entries['identity'] = {'kind': 'deleted', 'account_id': accountId};
    }
  }
}

class _StoredRecord {
  final BigInt sequence;
  final Json data;
  final String? text;
  _StoredRecord(this.sequence, this.data, [this.text]);
}

typedef FuelRecordLock = Future<void> Function(Future<void> Function() action);

/// Two verified copies protect proof rotation; checksums detect accidental damage,
/// not hostile access to the underlying secure-storage port.
class _VerifiedRecords {
  final Future<String?> Function(String) read;
  final Future<void> Function(String, String) write;
  final FuelRecordLock? lock;
  Future<void> _tail = Future.value();
  _VerifiedRecords(this.read, this.write, this.lock);

  Future<T> transaction<T>(Future<T> Function(_StoredRecord) action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        late T value;
        Future<void> run() async {
          value = await action(await _load());
        }

        if (lock == null) {
          await run();
        } else {
          await lock!(run);
        }
        result.complete(value);
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  _StoredRecord? _decode(String? text) {
    if (text == null) return null;
    if (utf8.encode(text).length > 1048576)
      throw const FormatException('invalid_vault');
    final outer = jsonDecode(text);
    if (outer is! Json ||
        outer['version'] != 2 ||
        outer['sequence'] is! String ||
        (outer['sequence'] as String).length > 40 ||
        outer['payload'] is! String ||
        outer['checksum'] is! String) {
      throw const FormatException('invalid_vault');
    }
    final sequence = BigInt.tryParse(outer['sequence'] as String);
    if (sequence == null || sequence <= BigInt.zero)
      throw const FormatException('invalid_vault');
    final checksum = sha256
        .convert(utf8.encode(jsonEncode([2, '$sequence', outer['payload']])))
        .toString();
    if (checksum != outer['checksum'])
      throw const FormatException('invalid_vault');
    final data = jsonDecode(outer['payload'] as String);
    if (data is! Json ||
        data['slots'] is! Json ||
        data['proofs'] is! Json ||
        data['journal'] is! Json ||
        data['retired'] is! List ||
        !(data['retired'] as List).every((id) => id is String)) {
      throw const FormatException('invalid_vault');
    }
    return _StoredRecord(sequence, data, text);
  }

  Future<_StoredRecord> _load() async {
    final a = _decode(await read('a')), b = _decode(await read('b'));
    if (a == null && b == null) {
      return _StoredRecord(BigInt.zero, {
        'slots': <String, dynamic>{},
        'proofs': <String, dynamic>{},
        'journal': <String, dynamic>{},
        'retired': <dynamic>[],
      });
    }
    if (a == null || b == null) {
      final first = (a ?? b)!;
      // Complete an interrupted first save before any network bootstrap. A later
      // missing copy is corruption, so it cannot restore an older deleted proof.
      if (first.sequence != BigInt.one)
        throw const FormatException('invalid_vault');
      await _writeVerified(a == null ? 'a' : 'b', first.text!);
      return first;
    }
    if (a.sequence == b.sequence && a.text != b.text)
      throw const FormatException('invalid_vault');
    return a.sequence >= b.sequence ? a : b;
  }

  Future<void> _writeVerified(String slot, String text) async {
    await write(slot, text);
    if (await read(slot) != text)
      throw const FuelException('storage_verification');
  }

  Future<void> save(_StoredRecord old, Json data) async {
    final sequence = old.sequence + BigInt.one;
    final payload = jsonEncode(data);
    final text = jsonEncode({
      'version': 2,
      'sequence': '$sequence',
      'payload': payload,
      'checksum': sha256
          .convert(utf8.encode(jsonEncode([2, '$sequence', payload])))
          .toString(),
    });
    if (utf8.encode(text).length > 1048576)
      throw const FuelException('storage_capacity');
    final first = sequence.isOdd ? 'a' : 'b';
    await _writeVerified(first, text);
    await _writeVerified(first == 'a' ? 'b' : 'a', text);
  }
}

class RecordJournal implements FuelJournal {
  final _VerifiedRecords _records;
  RecordJournal({
    required Future<String?> Function(String) read,
    required Future<void> Function(String, String) write,
    FuelRecordLock? lock,
  }) : _records = _VerifiedRecords(read, write, lock);
  @override
  bool get durable => true;
  @override
  Future<void> completeSelection(String intentId, Json identity) =>
      _change((data) {
        _completeSelection(data['journal'] as Json, intentId, identity);
      });

  Future<T> _change<T>(T Function(Json) action) =>
      _records.transaction((record) async {
        final data = _copyJson(record.data);
        final result = action(data);
        await _records.save(record, data);
        return result;
      });

  @override
  Future<Json?> readEntry(String key) => _records.transaction((record) async {
    final value = (record.data['journal'] as Json)[key];
    return value == null ? null : _copyJson(value as Json);
  });
  @override
  Future<void> writeEntry(String key, Json? value) async {
    await updateEntry(key, (_) => value);
  }

  @override
  Future<Json?> updateEntry(String key, Json? Function(Json?) update) =>
      _change((data) {
        if (key.length > 256) throw const FuelException('invalid_journal_key');
        final journal = data['journal'] as Json;
        final old = journal[key];
        final value = update(old == null ? null : _copyJson(old as Json));
        if (value == null) {
          journal.remove(key);
        } else {
          journal[key] = _copyJson(value);
        }
        return value == null ? null : _copyJson(value);
      });
  @override
  Future<Map<String, Json>> entries(String prefix) => _records.transaction(
    (record) async => {
      for (final entry in (record.data['journal'] as Json).entries)
        if (entry.key.startsWith(prefix))
          entry.key: _copyJson(entry.value as Json),
    },
  );
  @override
  Future<void> completeDeletion(
    String accountId,
    List<String> removedBindings,
  ) => _change((data) {
    final slots = data['slots'] as Json,
        proofs = data['proofs'] as Json,
        journal = data['journal'] as Json;
    final retired = (data['retired'] as List).cast<String>().toSet()
      ..addAll(removedBindings);
    slots.removeWhere((_, id) => retired.contains(id));
    proofs.removeWhere((id, _) => retired.contains(id));
    journal.removeWhere((key, _) => key.startsWith('account:$accountId:'));
    final current = journal['identity'] as Json?;
    final otherActive =
        slots['active'] != null ||
        current?['kind'] == 'active' &&
            current?['account_id'] is String &&
            current?['account_id'] != accountId;
    if (!otherActive)
      journal['identity'] = {'kind': 'deleted', 'account_id': accountId};
    data['retired'] = retired.toList();
  });
}

class RecordCredentialVault extends RecordJournal implements CredentialVault {
  RecordCredentialVault({
    required super.read,
    required super.write,
    super.lock,
  });

  FuelCredential? _proof(Json data, String? id) {
    if (id == null) return null;
    if ((data['retired'] as List).contains(id))
      throw const FormatException('invalid_vault');
    final value = (data['proofs'] as Json)[id];
    if (value is! Json || value['id'] != id || value['secret'] is! String)
      throw const FormatException('invalid_vault');
    return FuelCredential(id, value['secret'] as String);
  }

  void _remember(Json data, FuelCredential credential) {
    if ((data['retired'] as List).contains(credential.id))
      throw const FuelException('retired_binding');
    final proofs = data['proofs'] as Json;
    if (proofs.length >= 64 && !proofs.containsKey(credential.id))
      throw const FuelException('credential_capacity');
    proofs[credential.id] = credential.toStorage();
  }

  @override
  Future<FuelCredential?> read(String slot) =>
      _records.transaction((record) async {
        final id = slot.startsWith('binding:')
            ? slot.substring(8)
            : (record.data['slots'] as Json)[slot] as String?;
        return _proof(record.data, id);
      });
  @override
  Future<void> write(String slot, FuelCredential credential) => _change((data) {
    if (!['active', 'previous', 'candidate'].contains(slot))
      throw const FuelException('invalid_slot');
    _remember(data, credential);
    (data['slots'] as Json)[slot] = credential.id;
  });
  @override
  Future<void> activate(
    FuelCredential credential, {
    String? accountId,
    String? selectionId,
  }) => _change((data) {
    if (selectionId != null)
      _completeSelection(data['journal'] as Json, selectionId, {
        'kind': 'active',
        'binding_id': credential.id,
        'account_id': accountId,
      });
    _remember(data, credential);
    final slots = data['slots'] as Json;
    final old = slots['active'];
    if (old != null && old != credential.id) slots['previous'] = old;
    slots['active'] = credential.id;
    (data['journal'] as Json)['identity'] = {
      'kind': 'active',
      'binding_id': credential.id,
      if (accountId != null) 'account_id': accountId,
      if (selectionId != null) 'selection_id': selectionId,
    };
  });

  Future<List<String>> retainedBindings() => _records.transaction(
    (record) async => (record.data['proofs'] as Json).keys.toList(),
  );
}
