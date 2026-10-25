import 'dart:convert';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'account_owner_test.dart'
    show accountA, accountB, accountData, fuelReply;
import 'operations_test.dart' show journal;

void main() {
  test(
    'deletion recovery reconciles a lost selection before reopening private actions',
    () async {
      final storage = journal({});
      var selected = accountA, switches = 0, chats = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/selection'))
            return fuelReply({
              'current': {'binding_id': 'a', 'account_id': accountA},
              'previous': {'binding_id': 'b', 'account_id': accountB},
            });
          if (request.url.path.endsWith('/auth/switch')) {
            switches++;
            selected = accountB;
            if (switches == 1)
              throw http.ClientException('cookie changed, body lost');
            return fuelReply({'account_id': selected});
          }
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(selected));
          if (request.url.path.endsWith('/chat')) {
            chats++;
            expect(request.headers['X-Fuel-Expected-Account'], accountB);
          }
          return fuelReply({});
        }),
      );
      await client.refreshAccount();
      await expectLater(
        client.switchPrevious(),
        throwsA(isA<http.ClientException>()),
      );
      await client.recoverDeletion();
      expect(client.account?.id, accountB);
      expect(client.accountStatus, FuelAccountStatus.ready);
      expect(await storage.readEntry('selection'), isNull);
      await client.postChat('global', '', 'confirmed actor');
      expect(chats, 1);
      expect(switches, 2);
      client.close();
    },
  );

  test(
    'a definite selection conflict releases only that intent so bootstrap can reconcile the newer choice',
    () async {
      final storage = journal({});
      await storage.writeEntry('selection', {
        'id': 'old',
        'kind': 'switch',
        'from': 'a',
        'to': 'b',
      });
      var swaps = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/switch')) {
            swaps++;
            return http.Response('{"wire_version":1,"error":"conflict"}', 409);
          }
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          return fuelReply({'account_id': accountA});
        }),
      );
      await expectLater(
        client.bootstrapBrowser(),
        throwsA(isA<FuelException>()),
      );
      await client.bootstrapBrowser();
      expect(swaps, 1);
      expect(client.account!.id, accountA);
      client.close();
    },
  );
  test(
    'browser swap keeps the frozen target after a lost cookie acknowledgement and restart',
    () async {
      final disk = <String, String>{};
      var selected = 'a', posts = 0;
      final bodies = <String>[];
      FuelClient make() => FuelClient(
        Uri.parse('https://game.example'),
        journal: journal(disk),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/selection'))
            return fuelReply({
              'current': {
                'binding_id': selected,
                'account_id': selected == 'a' ? accountA : accountB,
              },
              'previous': {
                'binding_id': selected == 'a' ? 'b' : 'a',
                'account_id': selected == 'a' ? accountB : accountA,
              },
            });
          if (request.url.path.endsWith('/auth/switch')) {
            bodies.add(request.body);
            posts++;
            selected = 'b';
            if (posts == 1) throw http.ClientException('lost after cookie');
            return fuelReply({'account_id': accountB});
          }
          if (request.url.path.endsWith('/account'))
            return fuelReply(
              accountData(selected == 'a' ? accountA : accountB),
            );
          return fuelReply({
            'account_id': selected == 'a' ? accountA : accountB,
          });
        }),
      );
      final first = make();
      await first.refreshAccount();
      await expectLater(
        first.switchPrevious(),
        throwsA(isA<http.ClientException>()),
      );
      expect(first.account, isNull);
      expect(first.accountStatus, FuelAccountStatus.identityPending);
      await expectLater(
        first.postChat('global', '', 'wrong identity'),
        throwsA(isA<FuelException>()),
      );
      first.close();
      final restored = make();
      await restored.bootstrapBrowser();
      expect(restored.account!.id, accountB);
      expect(bodies.length, 2);
      expect(bodies[1], bodies[0]);
      restored.close();
    },
  );

  test(
    'lost deletion is recovered by proof without recreating the guest after restart',
    () async {
      final disk = <String, String>{};
      var deleted = false, bootstraps = 0, deletes = 0;
      String? proof;
      FuelClient make() => FuelClient(
        Uri.parse('https://game.example'),
        journal: journal(disk),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/auth/delete/status')) {
            final value = jsonDecode(request.body) as Json;
            if (proof != null) expect(value['proof'], proof);
            return fuelReply(
              deleted
                  ? {
                      'status': 'deleted',
                      'removed_bindings': ['binding-a'],
                    }
                  : {'status': 'unknown'},
            );
          }
          if (request.url.path.endsWith('/auth/delete')) {
            final value = jsonDecode(request.body) as Json;
            expect(value['account_id'], accountA);
            proof = value['proof'] as String;
            expect(disk, isNotEmpty);
            deletes++;
            deleted = true;
            throw http.ClientException('deleted, body lost');
          }
          bootstraps++;
          return fuelReply({'account_id': accountA});
        }),
      );
      final first = make();
      await first.refreshAccount();
      await expectLater(
        first.deleteAccount(confirmed: true),
        throwsA(isA<http.ClientException>()),
      );
      expect(first.account, isNull);
      first.close();
      final restored = make();
      final result = await restored.bootstrapBrowser();
      expect(result['status'], 'deleted');
      expect(restored.accountStatus, FuelAccountStatus.deleted);
      expect(bootstraps, 0);
      expect(deletes, 1);
      restored.close();
    },
  );

  test(
    'deletion refuses before mutation when its recovery proof cannot be saved',
    () async {
      var calls = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: RecordJournal(
          read: (_) async => null,
          write: (_, _) async => throw StateError('disk unavailable'),
        ),
        httpClient: MockClient((_) async {
          calls++;
          return fuelReply(accountData(accountA));
        }),
      );
      await client.refreshAccount();
      await expectLater(
        client.deleteAccount(confirmed: true),
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'storage_error'),
        ),
      );
      expect(calls, 1);
      client.close();
    },
  );
}
