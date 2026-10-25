import 'dart:async';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'account_owner_test.dart' show accountA, accountData, fuelReply;

void main() {
  test(
    'a lost preference response uses a fresh read to confirm the actual setting',
    () async {
      var enabled = true;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.method == 'POST') {
            enabled = false;
            throw http.ClientException('committed, lost body');
          }
          return fuelReply({
            ...accountData(accountA),
            'analytics_enabled': enabled,
            'analytics_revision': enabled ? '0' : '1',
          });
        }),
      );
      await client.refreshAccount();
      await client.analyticsEnabled(false);
      expect(client.account!.analyticsEnabled, isFalse);
      expect(client.analyticsSaving, isFalse);
      client.close();
    },
  );
  test(
    'a late preference acknowledgement cannot publish into another identity',
    () async {
      final response = Completer<http.Response>();
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient(
          (request) async => request.method == 'POST'
              ? response.future
              : fuelReply(accountData(accountA)),
        ),
      );
      await client.refreshAccount();
      final changed = client.analyticsEnabled(false);
      final assertion = expectLater(changed, throwsA(isA<FuelException>()));
      client.credential = FuelCredential.create();
      response.complete(fuelReply({'enabled': false}));
      await assertion;
      expect(client.account, isNull);
      expect(client.analyticsSaving, isFalse);
      client.close();
    },
  );
}
