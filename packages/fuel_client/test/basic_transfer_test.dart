import 'dart:convert';

import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'account_owner_test.dart'
    show accountA, accountB, accountData, fuelReply;
import 'operations_test.dart' show journal;

final receipt = <String, dynamic>{
  'id': 'transfer',
  'status': 'linked',
  'mode': 'basic',
  'account_id': accountA,
  'emojis': ['🐱', '🍎', '🐢'],
};

http.Response basicReply() => http.Response.bytes(
  utf8.encode(jsonEncode({'wire_version': 1, 'data': receipt})),
  200,
);

void main() {
  test(
    'a revoked selected target restores the exact saved prior guest',
    () async {
      final shared = journal({});
      var selected = 'old';
      var revokeAfterPost = false, switches = 0;
      FuelClient open() => FuelClient(
        Uri.parse('https://game.example'),
        journal: shared,
        httpClient: MockClient((request) async {
          final path = request.url.path.substring('/fuel/v1/'.length);
          switch (path) {
            case 'auth/bootstrap':
              return fuelReply({'account_id': accountB});
            case 'auth/selection':
              return fuelReply({
                'current': {
                  'binding_id': selected,
                  'account_id': selected == 'old' ? accountB : null,
                },
                'candidate_id': 'new',
                'previous': {'binding_id': 'old', 'account_id': accountB},
              });
            case 'auth/pair/redeem':
              selected = 'new';
              revokeAfterPost = true;
              return basicReply();
            case 'auth/pair/status':
              return http.Response(
                '{"wire_version":1,"error":"unauthorized"}',
                401,
              );
            case 'auth/switch':
              expect(jsonDecode(request.body), {'from': 'new', 'to': 'old'});
              switches++;
              selected = 'old';
              throw http.ClientException('Lost reply after restoring B');
            case 'account':
              return revokeAfterPost && selected == 'new'
                  ? http.Response(
                      '{"wire_version":1,"error":"unauthorized"}',
                      401,
                    )
                  : fuelReply(accountData(accountB));
          }
          return fuelReply({});
        }),
      );
      final first = open();
      addTearDown(first.close);
      await first.bootstrapBrowser();
      await first.prepareTransfer();
      await expectLater(
        first.redeemBasicTransfer('ACDEFH'),
        throwsA(isA<FuelException>()),
      );
      final restarted = open();
      addTearDown(restarted.close);
      await expectLater(
        restarted.bootstrapBrowser(),
        throwsA(isA<http.ClientException>()),
      );
      final recovered = open();
      addTearDown(recovered.close);
      await recovered.bootstrapBrowser();
      expect((await recovered.refreshAccount()).id, accountB);
      expect(switches, 1);
      expect(await shared.readEntry('selection'), isNull);
    },
  );

  test(
    'a lost undelivered request still allows a verified B session on restart',
    () async {
      final shared = journal({});
      var linked = false, switched = false, posts = 0;
      FuelClient open() => FuelClient(
        Uri.parse('https://game.example'),
        journal: shared,
        httpClient: MockClient((request) async {
          final path = request.url.path.substring('/fuel/v1/'.length);
          switch (path) {
            case 'auth/bootstrap':
              return fuelReply({'account_id': switched ? accountA : accountB});
            case 'auth/selection':
              return fuelReply({
                'current': {
                  'binding_id': switched ? 'candidate' : 'previous',
                  'account_id': switched ? accountA : accountB,
                },
                'candidate_id': 'candidate',
              });
            case 'auth/pair/redeem':
              posts++;
              throw http.ClientException('No reply');
            case 'auth/pair/status':
              return linked
                  ? basicReply()
                  : http.Response(
                      '{"wire_version":1,"error":"unauthorized"}',
                      401,
                    );
            case 'auth/pair/activate':
              switched = true;
              return fuelReply({'account_id': accountA});
            case 'account':
              return fuelReply(accountData(switched ? accountA : accountB));
          }
          return fuelReply({});
        }),
      );
      final first = open();
      addTearDown(first.close);
      await first.bootstrapBrowser();
      await first.prepareTransfer();
      await expectLater(
        first.redeemBasicTransfer('ACDEFH'),
        throwsA(isA<http.ClientException>()),
      );
      final restarted = open();
      addTearDown(restarted.close);
      await restarted.bootstrapBrowser();
      expect((await restarted.refreshAccount()).id, accountB);
      expect((await shared.readEntry('selection'))?['to'], 'candidate');
      await expectLater(
        restarted.prepareTransfer(newAttempt: true),
        throwsA(
          isA<FuelException>().having(
            (e) => e.code,
            'code',
            'pending_identity',
          ),
        ),
      );
      linked =
          true; // The earlier request was unknown, so its late commit can be reconciled.
      expect(await restarted.recoverBasicTransfer(), receipt);
      expect(restarted.account?.id, accountA);
      expect(await shared.readEntry('selection'), isNull);
      expect(posts, 1);
    },
  );

  for (final (status, code) in [(429, 'rate_limited'), (503, 'maintenance')]) {
    test('pre-mutation $code leaves the existing guest usable', () async {
      final storage = journal({});
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient((request) async {
          final path = request.url.path.substring('/fuel/v1/'.length);
          switch (path) {
            case 'auth/bootstrap':
              return fuelReply({'account_id': accountB});
            case 'auth/selection':
              return fuelReply({
                'current': {'binding_id': 'old', 'account_id': accountB},
                'candidate_id': 'new',
              });
            case 'auth/pair/redeem':
              return http.Response(
                jsonEncode({'wire_version': 1, 'error': code}),
                status,
              );
            case 'account':
              return fuelReply(accountData(accountB));
          }
          return fuelReply({});
        }),
      );
      addTearDown(client.close);
      await client.bootstrapBrowser();
      await client.prepareTransfer();
      await expectLater(
        client.redeemBasicTransfer('ACDEFH'),
        throwsA(isA<FuelException>().having((e) => e.code, 'code', code)),
      );
      expect((await client.refreshAccount()).id, accountB);
      expect(await storage.readEntry('selection'), isNull);
    });
  }

  test('browser basic redemption loads A in the same user action', () async {
    final requests = <String>[];
    var selected = accountB;
    final client = FuelClient(
      Uri.parse('https://game.example'),
      journal: journal({}),
      httpClient: MockClient((request) async {
        final path = request.url.path.substring('/fuel/v1/'.length);
        requests.add(path);
        if (path == 'auth/selection') {
          return fuelReply({
            'current': {'binding_id': 'old', 'account_id': accountB},
            'candidate_id': 'new',
          });
        }
        if (path == 'auth/pair/redeem') {
          expect(jsonDecode(request.body), containsPair('code', 'ACDEFH'));
          selected = accountA; // Browser applies the server's active cookie.
          return basicReply();
        }
        if (path == 'account') return fuelReply(accountData(selected));
        return fuelReply({});
      }),
    );
    addTearDown(client.close);
    await client.prepareTransfer();
    expect(await client.redeemBasicTransfer('ACDEFH'), receipt);
    expect(client.account?.id, accountA);
    expect(requests, [
      'auth/pair/prepare',
      'auth/selection',
      'auth/pair/redeem',
      'account',
    ]);
  });

  test(
    'lost browser profile read fences another tab and recovers at startup',
    () async {
      final disk = <String, String>{};
      final shared = journal(disk);
      var switched = false, loseProfile = false;
      var prepares = 0, redeems = 0;
      FuelClient open() => FuelClient(
        Uri.parse('https://game.example'),
        journal: shared,
        httpClient: MockClient((request) async {
          final path = request.url.path.substring('/fuel/v1/'.length);
          switch (path) {
            case 'auth/prepare':
              return fuelReply({});
            case 'auth/bootstrap':
              return fuelReply({'account_id': switched ? accountA : accountB});
            case 'auth/pair/prepare':
              prepares++;
              return fuelReply({});
            case 'auth/selection':
              return fuelReply({
                'current': {
                  'binding_id': switched ? 'new' : 'old',
                  'account_id': switched ? accountA : accountB,
                },
                'candidate_id': 'new',
              });
            case 'auth/pair/redeem':
              redeems++;
              expect((await shared.readEntry('selection'))?['to'], 'new');
              switched = true;
              loseProfile = true;
              return basicReply();
            case 'auth/pair/status':
              return basicReply();
            case 'auth/pair/activate':
              expect(
                jsonDecode(request.body),
                containsPair('target_id', 'new'),
              );
              switched = true;
              return fuelReply({'account_id': accountA});
            case 'account':
              if (loseProfile) {
                loseProfile = false;
                throw http.ClientException('Lost account read after cookie');
              }
              return fuelReply(accountData(switched ? accountA : accountB));
          }
          throw StateError('Unexpected request: $path');
        }),
      );

      final first = open();
      addTearDown(first.close);
      await first.bootstrapBrowser();
      await first.prepareTransfer();
      await expectLater(
        first.redeemBasicTransfer('ACDEFH'),
        throwsA(isA<http.ClientException>()),
      );
      final other = open();
      addTearDown(other.close);
      await expectLater(
        other.prepareTransfer(newAttempt: true),
        throwsA(
          isA<FuelException>().having(
            (e) => e.code,
            'code',
            'pending_identity',
          ),
        ),
      );
      await other.bootstrapBrowser();
      expect(other.account?.id, accountA);
      expect(await shared.readEntry('selection'), isNull);
      expect(prepares, 1);
      expect(redeems, 1);
    },
  );

  test('a definite invalid code leaves the previous guest usable', () async {
    final client = FuelClient(
      Uri.parse('https://game.example'),
      journal: journal({}),
      httpClient: MockClient((request) async {
        final path = request.url.path.substring('/fuel/v1/'.length);
        switch (path) {
          case 'auth/bootstrap':
            return fuelReply({'account_id': accountB});
          case 'auth/selection':
            return fuelReply({
              'current': {'binding_id': 'old', 'account_id': accountB},
              'candidate_id': 'new',
            });
          case 'auth/pair/redeem':
            return http.Response(
              '{"wire_version":1,"error":"invalid_code"}',
              400,
            );
          case 'account':
            return fuelReply(accountData(accountB));
        }
        return fuelReply({});
      }),
    );
    addTearDown(client.close);
    await client.bootstrapBrowser();
    await client.prepareTransfer();
    await expectLater(
      client.redeemBasicTransfer('ACDEFH'),
      throwsA(
        isA<FuelException>().having((e) => e.code, 'code', 'invalid_code'),
      ),
    );
    expect(client.account?.id, accountB);
    expect((await client.refreshAccount()).id, accountB);
  });

  test('lost native response recovers the saved proof and keeps B', () async {
    final records = <String, String>{};
    final vault = RecordCredentialVault(
      read: (key) async => records[key],
      write: (key, value) async => records[key] = value,
    );
    final previous = FuelCredential.create();
    await vault.activate(previous, accountId: accountB);
    var authorized = false, posts = 0;
    FuelCredential? candidate;
    final client = FuelClient(
      Uri.parse('https://game.example'),
      httpClient: MockClient((request) async {
        final path = request.url.path.substring('/fuel/v1/'.length);
        if (path == 'auth/bootstrap') {
          return fuelReply({'account_id': accountB});
        }
        final auth = request.headers['Authorization'];
        if (path == 'auth/pair/redeem' || path == 'auth/pair/status') {
          expect(auth, 'Fuel ${candidate?.id}:${candidate?.secret}');
          if (path == 'auth/pair/redeem') {
            posts++;
            authorized = true;
            throw http.ClientException('Lost receipt');
          }
          return fuelReply({
            'status': 'linked',
            'mode': 'basic',
            'account_id': accountA,
          });
        }
        if (path == 'account') {
          final isCandidate =
              authorized &&
              auth == 'Fuel ${candidate?.id}:${candidate?.secret}';
          return fuelReply(accountData(isCandidate ? accountA : accountB));
        }
        throw StateError('Unexpected request: $path');
      }),
    );
    addTearDown(client.close);
    await client.bootstrapNative(vault);
    await client.prepareTransfer(vault: vault);
    candidate = await vault.read('candidate');
    await expectLater(
      client.redeemBasicTransfer('ACDEFH'),
      throwsA(isA<http.ClientException>()),
    );
    expect((await vault.read('active'))?.id, previous.id);
    final recovered = await client.recoverBasicTransfer();
    expect(recovered['account_id'], accountA);
    expect(recovered['emojis'], isNull);
    expect(client.account?.id, accountA);
    expect((await vault.read('active'))?.id, candidate?.id);
    expect((await vault.read('previous'))?.id, previous.id);
    expect(posts, 1);
  });
}
