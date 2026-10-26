import 'package:fuel_client/fuel_client.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'account_owner_test.dart' show accountA, accountData, fuelReply;

void main() {
  test(
    'a ranking page includes own standing outside the page and preserves the legacy array facade',
    () async {
      final client = FuelClient(
        Uri.parse('https://game.example/service/api'),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          expect(request.method, 'GET');
          expect(request.headers['X-Fuel-Expected-Account'], accountA);
          expect(request.url.queryParameters['limit'], '1');
          if (request.url.path == '/service/api/leaderboards/classic/page')
            return fuelReply({
              'entries': [
                {
                  'rank': '1',
                  'name': 'Bright Owl',
                  'score': '90',
                  'is_player': false,
                },
              ],
              'player_rank': '500',
              'player_best': '10',
            });
          expect(request.url.path, '/service/api/leaderboards/classic');
          return fuelReply([
            {'account_id': accountA, 'name': 'Fox', 'score': '10'},
          ]);
        }),
      );
      try {
        await client.refreshAccount();
        final page = await client.leaderboardPage('classic', limit: 1);
        expect(page['player_rank'], '500');
        expect((page['entries'] as List), hasLength(1));
        expect(await client.leaderboard('classic', limit: 1), isA<List>());
      } finally {
        client.close();
      }
    },
  );
}
