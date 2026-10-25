import 'dart:convert';
import 'package:fuel_client/fuel_client.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a stale selection completion cannot erase or overwrite a newer selection',
    () async {
      final disk = <String, String>{};
      final journal = RecordJournal(
        read: (slot) async => disk[slot],
        write: (slot, value) async {
          disk[slot] = value;
        },
      );
      await journal.writeEntry('selection', {'id': 'first'});
      await journal.completeSelection('first', {
        'kind': 'active',
        'account_id': 'a',
      });
      await journal.writeEntry('selection', {'id': 'second'});
      await expectLater(
        journal.completeSelection('first', {
          'kind': 'active',
          'account_id': 'a',
        }),
        throwsA(isA<FuelException>()),
      );
      expect((await journal.readEntry('selection'))!['id'], 'second');
      await journal.completeSelection('second', {
        'kind': 'active',
        'account_id': 'b',
      });
      await expectLater(
        journal.completeSelection('first', {
          'kind': 'active',
          'account_id': 'a',
        }),
        throwsA(isA<FuelException>()),
      );
      expect((await journal.readEntry('identity'))!['account_id'], 'b');
    },
  );
  test(
    'a deleted sole active proof leaves an explicit durable deletion state',
    () async {
      final disk = <String, String>{};
      final vault = RecordCredentialVault(
        read: (slot) async => disk[slot],
        write: (slot, value) async {
          disk[slot] = value;
        },
      );
      final credential = FuelCredential.create();
      await vault.activate(credential);
      await vault.completeDeletion('a', [credential.id]);
      expect(await vault.read('active'), isNull);
      expect((await vault.readEntry('identity'))!['kind'], 'deleted');
    },
  );

  test(
    'verified records retain both proofs across a partial activation write',
    () async {
      final disk = <String, String>{};
      int? remaining;
      final vault = RecordCredentialVault(
        read: (slot) async => disk[slot],
        write: (slot, value) async {
          if (remaining != null) {
            final count = remaining!;
            remaining = count - 1;
            if (count <= 0) throw StateError('storage failed');
          }
          disk[slot] = value;
        },
      );
      final a = FuelCredential.create(), b = FuelCredential.create();
      await vault.write('active', a);
      await vault.write('candidate', b);
      remaining = 1;
      await expectLater(vault.activate(b), throwsStateError);
      remaining = null;
      final restarted = RecordCredentialVault(
        read: (slot) async => disk[slot],
        write: (slot, value) async {
          disk[slot] = value;
        },
      );
      expect((await restarted.read('active'))!.id, b.id);
      expect((await restarted.read('previous'))!.id, a.id);
      expect((await restarted.read('candidate'))!.id, b.id);
    },
  );

  test(
    'deletion forgets only returned bindings in both copies and preserves another account',
    () async {
      final disk = <String, String>{};
      final vault = RecordCredentialVault(
        read: (slot) async => disk[slot],
        write: (slot, value) async {
          disk[slot] = value;
        },
      );
      final a = FuelCredential.create(), b = FuelCredential.create();
      await vault.write('active', a);
      await vault.activate(b);
      await vault.writeEntry('identity', {'kind': 'active', 'account_id': 'b'});
      await vault.writeEntry('account:a:delete', {'proof': 'pending'});
      await vault.writeEntry('account:b:action:one', {'id': 'one'});
      await vault.completeDeletion('a', [a.id]);
      expect((await vault.read('active'))!.id, b.id);
      expect(await vault.read('previous'), isNull);
      expect((await vault.readEntry('identity'))!['account_id'], 'b');
      expect(await vault.entries('account:a:'), isEmpty);
      expect(await vault.entries('account:b:'), hasLength(1));
      expect(disk.values.any((value) => value.contains(a.secret)), isFalse);
      disk['a'] = 'corrupt';
      await expectLater(vault.read('active'), throwsFormatException);
    },
  );

  test('detects failed read-back and valid-JSON checksum corruption', () async {
    final disk = <String, String>{};
    var corrupt = false;
    final vault = RecordCredentialVault(
      read: (slot) async => disk[slot],
      write: (slot, value) async {
        disk[slot] = corrupt ? '$value ' : value;
      },
    );
    final a = FuelCredential.create();
    await vault.write('active', a);
    corrupt = true;
    await expectLater(
      vault.write('candidate', FuelCredential.create()),
      throwsA(isA<FuelException>()),
    );
    corrupt = false;
    final record = jsonDecode(disk['b']!) as Json;
    record['sequence'] = '999';
    disk['b'] = jsonEncode(record);
    await expectLater(vault.read('active'), throwsFormatException);
  });
}
