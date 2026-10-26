import 'dart:convert';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'account_owner_test.dart' show accountA, accountData, fuelReply;
import 'operations_test.dart' show journal;

void main() {
  test(
    'UI events carry confirmed consent and never become persistent actions',
    () async {
      var enabled = true;
      final events = <Json>[];
      final storage = journal({});
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply({
              ...accountData(accountA),
              'analytics_enabled': enabled,
              'analytics_revision': '7',
            });
          expect(request.url.path, '/fuel/v1/analytics/events');
          expect(request.headers['X-Fuel-Expected-Account'], accountA);
          events.add(jsonDecode(request.body) as Json);
          return fuelReply({'status': 'queued'});
        }),
      );
      try {
        await client.refreshAccount();
        expect(
          await client.analyticsEvent('screen_viewed', {
            'screen': 'home',
          }, session: 'room'),
          'queued',
        );
        expect(events.single, containsPair('revision', '7'));
        expect(events.single, containsPair('session', 'room'));
        expect(events.single, containsPair('name', 'screen_viewed'));
        expect(events.single['id'], matches(RegExp(r'^[a-f0-9]{32}$')));
        expect(await storage.readEntry('account:$accountA:action'), isNull);
        enabled = false;
        await client.refreshAccount();
        expect(
          await client.analyticsEvent('screen_viewed', {'screen': 'home'}),
          'disabled',
        );
        expect(events, hasLength(1));
      } finally {
        client.close();
      }
    },
  );
}
