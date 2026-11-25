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
  test('browser basic redemption loads A in the same user action', () async {
    final requests = <String>[];
    var selected = accountB;
    final client = FuelClient(
      Uri.parse('https://game.example'),
      journal: journal({}),
      httpClient: MockClient((request) async {
        final path = request.url.path.substring('/fuel/v1/'.length);
        requests.add(path);
        if (path == 'auth/pair/redeem') {
          expect(request.body, '{"code":"ACDEFH"}');
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
    expect(requests, ['auth/pair/prepare', 'auth/pair/redeem', 'account']);
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
          return basicReply();
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
    expect(await client.recoverBasicTransfer(), receipt);
    expect(client.account?.id, accountA);
    expect((await vault.read('active'))?.id, candidate?.id);
    expect((await vault.read('previous'))?.id, previous.id);
    expect(posts, 1);
  });
}
