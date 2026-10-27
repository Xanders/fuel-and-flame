import 'dart:async';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'account_owner_test.dart'
    show accountA, accountB, accountData, fuelReply;

import 'operations_test.dart' show journal;

void main() {
  for (final survivor in [false, true]) {
    test(
      'browser availability preserves confirmed deletion with survivor: $survivor',
      () async {
        final disk = <String, String>{};
        final calls = <String>[];
        final client = FuelClient(
          Uri.parse('https://game.example'),
          journal: journal(disk),
          httpClient: MockClient((request) async {
            calls.add('${request.method} ${request.url.path}');
            if (request.url.path.endsWith('/account'))
              return fuelReply(accountData(accountA));
            if (request.url.path.endsWith('/auth/delete/status'))
              return fuelReply({
                'status': 'deleted',
                'removed_bindings': ['a'],
              });
            if (request.url.path.endsWith('/auth/selection'))
              return fuelReply({
                'current': null,
                'previous': survivor
                    ? {'binding_id': 'b', 'account_id': accountB}
                    : null,
              });
            throw StateError('unexpected ${request.url.path}');
          }),
        );
        try {
          await client.refreshAccount();
          await client.deleteAccount(confirmed: true);
          expect(client.accountStatus, FuelAccountStatus.deleted);
          calls.clear();
          final generation = client.generation,
              saved = Map<String, String>.from(disk);
          expect(await client.hasPreviousAccount(), survivor);
          expect(calls, ['GET /fuel/v1/auth/selection']);
          expect(client.accountStatus, FuelAccountStatus.deleted);
          expect(client.account, isNull);
          expect(client.generation, generation);
          expect(disk, saved);
          await expectLater(
            client.request('GET', 'account'),
            throwsA(
              isA<FuelException>().having(
                (e) => e.code,
                'code',
                'identity_pending',
              ),
            ),
          );
        } finally {
          client.close();
        }
      },
    );
  }
  test(
    'native availability reads the vault without switching, exposing proofs or changing the account',
    () async {
      final disk = <String, String>{};
      var readsFail = false;
      final vault = RecordCredentialVault(
        read: (key) async {
          if (readsFail) throw StateError('unavailable');
          return disk[key];
        },
        write: (key, value) async {
          disk[key] = value;
        },
      );
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient(
          (request) async => request.url.path.endsWith('/account')
              ? fuelReply(accountData(accountA))
              : fuelReply({'account_id': accountA}),
        ),
      );
      try {
        await client.bootstrapNative(vault);
        final generation = client.generation, actor = client.account!.id;
        expect(await client.hasPreviousAccount(), isFalse);
        final active = await vault.read('active');
        final before = Map<String, String>.from(disk);
        await vault.write('previous', active!);
        expect(await client.hasPreviousAccount(), isFalse);
        await vault.write('previous', FuelCredential.create());
        final written = Map<String, String>.from(disk);
        expect(await client.hasPreviousAccount(), isTrue);
        expect(disk, written);
        expect(client.generation, generation);
        expect(client.account!.id, actor);
        expect(client.accountStatus, FuelAccountStatus.ready);
        expect(before, isNotEmpty);
        readsFail = true;
        await expectLater(
          client.hasPreviousAccount(),
          throwsA(
            isA<FuelException>().having((e) => e.code, 'code', 'storage_error'),
          ),
        );
      } finally {
        client.close();
      }
    },
  );

  test(
    'browser availability uses selection metadata and never mutates selection or account state',
    () async {
      Json? previous;
      final calls = <String>[];
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          return fuelReply({
            'current': {'binding_id': 'a', 'account_id': accountA},
            'previous': previous,
          });
        }),
      );
      try {
        await client.refreshAccount();
        calls.clear();
        final generation = client.generation;
        expect(await client.hasPreviousAccount(), isFalse);
        previous = {'binding_id': 'a', 'account_id': accountA};
        expect(await client.hasPreviousAccount(), isFalse);
        previous = {'binding_id': 'b', 'account_id': accountB};
        expect(await client.hasPreviousAccount(), isTrue);
        expect(calls, List.filled(3, 'GET /fuel/v1/auth/selection'));
        expect(client.generation, generation);
        expect(client.account!.id, accountA);
        expect(client.accountStatus, FuelAccountStatus.ready);
      } finally {
        client.close();
      }
    },
  );

  test(
    'an old availability response cannot affect another identity and transport errors are not false',
    () async {
      final entered = Completer<void>(), response = Completer<http.Response>();
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((_) {
          entered.complete();
          return response.future;
        }),
      );
      final checking = client.hasPreviousAccount();
      final assertion = expectLater(
        checking,
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await entered.future;
      client.credential = FuelCredential.create();
      response.complete(
        fuelReply({
          'current': null,
          'previous': {'binding_id': 'b'},
        }),
      );
      await assertion;
      client.close();
      final offline = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((_) async {
          throw http.ClientException('offline');
        }),
      );
      try {
        await expectLater(
          offline.hasPreviousAccount(),
          throwsA(isA<http.ClientException>()),
        );
      } finally {
        offline.close();
      }
    },
  );
}
