import 'dart:async';
import 'dart:convert';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'account_owner_test.dart' show accountA, accountData, fuelReply;

Json operation(String id, int cursor, {String source = 'effect'}) => {
  'operation_id': id,
  'cursor': '$cursor',
  'source': source,
  'session_id': 'room',
  'epoch': 'epoch',
  'terminal': source == 'effect',
  'action': 'finish',
  'occurred_at': 1800000000,
  'committed_at': 1800000000,
  'reply': {'status': 'banked', 'coins': 999},
};

RecordJournal journal(Map<String, String> disk) => RecordJournal(
  read: (slot) async => disk[slot],
  write: (slot, value) async {
    disk[slot] = value;
  },
);

void main() {
  test(
    'a fresh device recovers a terminal summary outside its recent ordinary history page',
    () async {
      final finalResult = operation('banked-before-later-events', 1);
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: journal({}),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.queryParameters['terminal'] == 'true')
            return fuelReply([finalResult]);
          return fuelReply(
            List.generate(
              64,
              (index) => {
                ...operation('later-$index', index + 2, source: 'event'),
                'terminal': false,
              },
            ),
          );
        }),
      );
      await client.refreshAccount();
      await client.recoverOperations();
      expect(client.lastOperation!.id, 'banked-before-later-events');
      client.close();
    },
  );
  test(
    'a definite rejected action releases its intent for the next deliberate action',
    () async {
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: journal({}),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          return http.Response('{"wire_version":1,"error":"forbidden"}', 403);
        }),
      );
      await client.refreshAccount();
      await expectLater(
        client.executeAction(FuelAction('invalid', {})),
        throwsA(isA<FuelException>()),
      );
      expect(await client.pendingActions(), isEmpty);
      client.close();
    },
  );
  test(
    'recovery claims presentation atomically between clients sharing a journal',
    () async {
      final disk = <String, String>{};
      final storage = journal(disk);
      final receipts = <Json>[];
      final responses = <Completer<http.Response>>[];
      FuelClient make() => FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (receipts.isEmpty) return fuelReply([]);
          final response = Completer<http.Response>();
          responses.add(response);
          return response.future;
        }),
      );
      final first = make(), second = make();
      await first.refreshAccount();
      await first.recoverOperations();
      await second.refreshAccount();
      receipts.add(operation('one-result', 1));
      final seen = <String>[];
      final a = first.operations.listen((value) => seen.add(value.id));
      final b = second.operations.listen((value) => seen.add(value.id));
      final one = first.recoverOperations(), two = second.recoverOperations();
      while (responses.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      for (final response in responses) {
        response.complete(fuelReply(receipts));
      }
      await Future.wait([one, two]);
      expect(seen, ['one-result']);
      await a.cancel();
      await b.cancel();
      first.close();
      second.close();
    },
  );

  test(
    'an oversized presentation backlog resynchronizes without playing stale effects',
    () async {
      final storage = journal({});
      var old = false;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (!old) return fuelReply([]);
          return fuelReply(
            List.generate(
              request.url.queryParameters.containsKey('after') ? 65 : 64,
              (index) => operation('result-$index', index + 1),
            ),
          );
        }),
      );
      await client.refreshAccount();
      await client.recoverOperations();
      old = true;
      final seen = <String>[];
      final listener = client.operations.listen((value) => seen.add(value.id));
      await client.recoverOperations();
      expect(seen, isEmpty);
      expect(client.operationGap, isTrue);
      expect(client.lastOperation!.id, 'result-63');
      await listener.cancel();
      client.close();
    },
  );

  test(
    'lost action acknowledgement keeps one immutable intent and recovers without another grant',
    () async {
      final disk = <String, String>{};
      final receipts = <Json>[];
      var coins = 100, posts = 0;
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/account'))
          return fuelReply(accountData(accountA, coins));
        if (request.url.path.endsWith('/actions')) {
          posts++;
          final body = jsonDecode(request.body) as Json;
          coins++;
          receipts.add(operation(body['id'] as String, 1, source: 'public'));
          throw http.ClientException('committed acknowledgement lost');
        }
        if (request.url.path.endsWith('/operations'))
          return fuelReply(
            request.url.queryParameters['after'] == '1' ? [] : receipts,
          );
        return fuelReply(receipts.single);
      });
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: transport,
        journal: journal(disk),
      );
      await client.refreshAccount();
      await client.recoverOperations();
      final payload = <String, dynamic>{'amount': 1};
      final intent = FuelAction('spend', payload);
      payload['amount'] = 999;
      await expectLater(
        client.executeAction(intent),
        throwsA(isA<http.ClientException>()),
      );
      await expectLater(
        client.executeAction(FuelAction('spend', {'amount': 2})),
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'pending_action'),
        ),
      );
      final recovered = await client.retryPendingActions();
      expect(recovered.single.id, intent.id);
      expect(posts, 1);
      expect(coins, 101);
      expect((client.account!.progress as Json)['coins'], 101);
      expect(await client.pendingActions(), isEmpty);
      client.close();
    },
  );

  test(
    'HTTP-only recovery after RAM loss presents once and never installs historical balances',
    () async {
      final disk = <String, String>{};
      final receipts = <Json>[];
      FuelClient makeClient() => FuelClient(
        Uri.parse('https://game.example'),
        journal: journal(disk),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA, 50));
          final after = BigInt.parse(
            request.url.queryParameters['after'] ?? '0',
          );
          return fuelReply(
            receipts
                .where(
                  (value) => BigInt.parse(value['cursor'] as String) > after,
                )
                .toList(),
          );
        }),
      );
      final first = makeClient();
      await first.refreshAccount();
      await first.recoverOperations();
      first.close();
      receipts.add(operation('durable-result', 10));
      final restored = makeClient();
      final delivered = <String>[];
      final listener = restored.operations.listen(
        (value) => delivered.add(value.id),
      );
      await restored.refreshAccount();
      await restored.recoverOperations();
      await restored.recoverOperations();
      expect(delivered, ['durable-result']);
      expect((restored.account!.progress as Json)['coins'], 50);
      expect(restored.lastOperation!.id, 'durable-result');
      await listener.cancel();
      restored.close();
      final again = makeClient();
      final repeated = <String>[];
      final next = again.operations.listen((value) => repeated.add(value.id));
      await again.refreshAccount();
      await again.recoverOperations();
      expect(repeated, isEmpty);
      expect(again.lastOperation!.id, 'durable-result');
      await next.cancel();
      again.close();
    },
  );

  test(
    'a fresh journal summarizes old results without replaying old animations',
    () async {
      final receipt = operation('old', 20);
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: journal({}),
        httpClient: MockClient(
          (request) async => request.url.path.endsWith('/account')
              ? fuelReply(accountData(accountA, 50))
              : fuelReply([receipt]),
        ),
      );
      final seen = <String>[];
      final listener = client.operations.listen((value) => seen.add(value.id));
      await client.refreshAccount();
      await client.recoverOperations();
      expect(seen, isEmpty);
      expect(client.lastOperation!.id, 'old');
      await listener.cancel();
      client.close();
    },
  );
}
