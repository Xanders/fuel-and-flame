@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;
import 'account_owner_test.dart'
    show accountA, accountB, accountData, fuelReply;
import 'operations_test.dart' show operation;

void main() {
  test(
    'confirmed activation rejects a replacement candidate in the same browser profile',
    () async {
      final base = Uri.parse(
        'https://game.example/expected-target-${randomId()}/fuel/v1',
      );
      const accountC = 'cccccccccccccccccccccccccccccccc';
      var candidate = 'binding-a', active = accountB;
      final activations = <Json>[];
      final checked = <String?>[];
      final disk = <String, String>{};
      final shared = RecordJournal(
        read: (key) async => disk[key],
        write: (key, value) async => disk[key] = value,
      );
      FuelClient open() => FuelClient(
        base,
        journal: shared,
        httpClient: MockClient((request) async {
          final route = request.url.path.split('/fuel/v1/').last;
          switch (route) {
            case 'auth/prepare':
              return fuelReply({});
            case 'auth/bootstrap':
              return fuelReply({'account_id': active});
            case 'account':
              return fuelReply(accountData(active));
            case 'auth/pair/prepare':
              candidate = 'binding-c';
              return fuelReply({});
            case 'auth/selection':
              return fuelReply({
                'current': {'binding_id': 'binding-b', 'account_id': active},
                'candidate_id': candidate,
              });
            case 'auth/pair/status':
              checked.add(request.url.queryParameters['target_id']);
              return fuelReply({
                'status': 'linked',
                'account_id': candidate == 'binding-a' ? accountA : accountC,
              });
            case 'auth/pair/activate':
              activations.add(jsonDecode(request.body) as Json);
              active = accountC;
              return fuelReply({'account_id': active});
            default:
              throw StateError('Unexpected request $route');
          }
        }),
      );
      final first = open(), second = open();
      addTearDown(first.close);
      addTearDown(second.close);
      await first.bootstrapBrowser();
      await second.bootstrapBrowser();
      final reviewed = (await first.pairStatus())['account_id'] as String;
      expect(reviewed, accountA);
      final generation = first.generation;
      await second.prepareTransfer(newAttempt: true);
      await expectLater(
        first.activateTransfer(expectedAccountId: reviewed),
        throwsA(
          isA<FuelException>().having(
            (e) => e.code,
            'code',
            'selection_changed',
          ),
        ),
      );
      expect(first.account?.id, accountB);
      expect(first.generation, generation);
      expect(activations, isEmpty);
      expect(await shared.readEntry('selection'), isNull);
      expect(
        (await first.activateTransfer(
          expectedAccountId: accountC,
        ))['account_id'],
        accountC,
      );
      expect(checked, [null, 'binding-c', 'binding-c']);
      expect(activations, [
        {'target_id': 'binding-c', 'from': 'binding-b'},
      ]);
    },
  );

  for (final scenario in [
    'source_changed',
    'loss_before',
    'loss_after',
    'revoked',
  ]) {
    test(
      'guarded activation reconciles browser selection: $scenario',
      () async {
        final base = Uri.parse(
          'https://game.example/selection-${randomId()}/fuel/v1',
        );
        const accountC = 'cccccccccccccccccccccccccccccccc';
        const accountD = 'dddddddddddddddddddddddddddddddd';
        final accounts = {
          'binding-a': accountA,
          'binding-b': accountB,
          'binding-c': accountC,
          'binding-d': accountD,
        };
        var active = 'binding-b',
            previous = 'binding-d',
            candidate = 'binding-a';
        var activateCalls = 0;
        var revoked = false;
        final disk = <String, String>{};
        final shared = RecordJournal(
          read: (key) async => disk[key],
          write: (key, value) async => disk[key] = value,
        );
        FuelClient open() => FuelClient(
          base,
          journal: shared,
          httpClient: MockClient((request) async {
            switch (request.url.path.split('/fuel/v1/').last) {
              case 'auth/prepare':
                return fuelReply({});
              case 'auth/bootstrap':
                return fuelReply({'account_id': accounts[active]});
              case 'account':
                return fuelReply(accountData(accounts[active]!));
              case 'auth/selection':
                return fuelReply({
                  'current': {
                    'binding_id': active,
                    'account_id': accounts[active],
                  },
                  'previous': {'binding_id': previous},
                  'candidate_id': candidate,
                });
              case 'auth/switch':
                (active, previous) = (previous, active);
                return fuelReply({'account_id': accounts[active]});
              case 'auth/pair/prepare':
                candidate = 'binding-c';
                return fuelReply({});
              case 'auth/pair/status':
                if (revoked) {
                  return http.Response(
                    '{"wire_version":1,"error":"unauthorized"}',
                    401,
                  );
                }
                if (request.url.queryParameters['target_id'] case final target?
                    when target != candidate) {
                  return http.Response(
                    '{"wire_version":1,"error":"selection_changed"}',
                    400,
                  );
                }
                return fuelReply({
                  'status': 'linked',
                  'account_id': accounts[candidate],
                });
              case 'auth/pair/activate':
                activateCalls++;
                if (scenario == 'loss_before' || scenario == 'revoked')
                  throw TimeoutException('response lost');
                (active, previous) = (candidate, active);
                if (scenario == 'loss_after')
                  throw TimeoutException('response lost');
                return fuelReply({'account_id': accounts[active]});
              default:
                throw StateError('Unexpected request ${request.url.path}');
            }
          }),
        );
        final first = open(), second = open();
        addTearDown(first.close);
        addTearDown(second.close);
        await first.bootstrapBrowser();
        await second.bootstrapBrowser();
        final shown = (await first.pairStatus())['account_id'] as String;
        expect(shown, accountA);
        const changed = 'selection_changed';
        final changedError = throwsA(
          isA<FuelException>().having((error) => error.code, 'code', changed),
        );
        if (scenario == 'source_changed') {
          await second.switchPrevious();
          expect(first.account?.id, accountB);
          await expectLater(
            first.activateTransfer(expectedAccountId: shown),
            changedError,
          );
          expect(activateCalls, 0);
          expect(
            [active, previous, candidate],
            ['binding-d', 'binding-b', 'binding-a'],
          );
          expect(first.account?.id, accountD);
        } else {
          await expectLater(
            first.activateTransfer(expectedAccountId: shown),
            throwsA(isA<TimeoutException>()),
          );
          expect((await shared.readEntry('selection'))?['to'], 'binding-a');
          if (scenario == 'revoked') {
            revoked = true;
          } else {
            await second.prepareTransfer(newAttempt: true);
          }
          if (scenario == 'loss_after') {
            expect(
              (await first.activateTransfer(
                expectedAccountId: shown,
              ))['account_id'],
              accountA,
            );
            expect([active, previous], ['binding-a', 'binding-b']);
            expect(first.account?.id, accountA);
          } else {
            await expectLater(
              first.activateTransfer(expectedAccountId: shown),
              changedError,
            );
            expect([active, previous], ['binding-b', 'binding-d']);
            expect(first.account?.id, accountB);
          }
          expect(activateCalls, 1);
          if (revoked) {
            expect(candidate, 'binding-a');
            expect((await first.refreshAccount()).id, accountB);
            await first.prepareTransfer(newAttempt: true);
            expect(candidate, 'binding-c');
          } else {
            expect((await first.pairStatus())['account_id'], accountC);
          }
        }
        expect(await shared.readEntry('selection'), isNull);
      },
    );
  }

  for (final deliverStorageEvent in [false, true]) {
    test(
      'queued no-work recovery invalidates an older tab (storage event: $deliverStorageEvent)',
      () async {
        final entered = Completer<void>(), finish = Completer<void>();
        final base = Uri.parse(
          'https://game.example/basic-locked-${randomId()}/fuel/v1',
        );
        var selected = accountB;
        FuelClient make() => FuelClient(
          base,
          httpClient: MockClient((request) async {
            final path = request.url.path;
            if (path.endsWith('/auth/pair/redeem')) {
              entered.complete();
              await finish.future;
              selected = accountA;
              return fuelReply({
                'status': 'linked',
                'mode': 'basic',
                'account_id': accountA,
              });
            }
            if (path.endsWith('/auth/selection')) {
              return fuelReply({
                'current': {'binding_id': 'before', 'account_id': selected},
                'candidate_id': 'after',
              });
            }
            if (path.endsWith('/account'))
              return fuelReply(accountData(selected));
            return fuelReply({'account_id': selected});
          }),
        );
        final first = make(), older = make();
        try {
          await first.bootstrapBrowser();
          await older.bootstrapBrowser();
          await first.prepareTransfer();
          final committing = first.redeemBasicTransfer('ACDEFH');
          await entered.future;
          final stale = expectLater(
            older.recoverBasicTransfer(),
            throwsA(isA<FuelException>()),
          );
          if (deliverStorageEvent) {
            web.window.dispatchEvent(web.StorageEvent('storage'));
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          finish.complete();
          await committing;
          await stale;
          expect(first.account?.id, accountA);
          expect(older.account, isNull);
          expect(older.accountStatus, FuelAccountStatus.identityPending);
        } finally {
          if (!finish.isCompleted) finish.complete();
          first.close();
          older.close();
        }
      },
    );
  }

  test(
    'availability holds the browser identity lock and rejects a late result after identity invalidation',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final base = Uri.parse(
        'https://game.example/availability-${randomId()}/fuel/v1',
      );
      var prepares = 0;
      FuelClient make() => FuelClient(
        base,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/auth/prepare')) prepares++;
          if (request.url.path.endsWith('/auth/selection')) {
            entered.complete();
            await release.future;
            return fuelReply({
              'current': {'binding_id': 'a'},
              'previous': {'binding_id': 'b'},
            });
          }
          return fuelReply({'account_id': accountA});
        }),
      );
      final a = make(), b = make();
      try {
        await a.bootstrapBrowser();
        final first = a.hasPreviousAccount();
        final assertion = expectLater(
          first,
          throwsA(
            isA<FuelException>().having((e) => e.code, 'code', 'cancelled'),
          ),
        );
        await entered.future;
        final second = b.bootstrapBrowser();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final beforeRelease = prepares;
        a.credential = FuelCredential.create();
        release.complete();
        await assertion;
        await second;
        expect(beforeRelease, 1);
        expect(prepares, 2);
        expect(a.account, isNull);
        expect(b.account!.id, accountA);
      } finally {
        if (!release.isCompleted) release.complete();
        a.close();
        b.close();
      }
    },
  );
  for (final custom in [false, true])
    test(
      'browser owners serialize complete bootstrap before cookie preparation (custom journal: $custom)',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        final base = Uri.parse(
          'https://game.example/bootstrap-${randomId()}/fuel/v1',
        );
        String? selected;
        var prepares = 0;
        final created = <String>{};
        final records = <String, String>{};
        FuelClient make() => FuelClient(
          base,
          journal: custom
              ? RecordJournal(
                  read: (key) async => records[key],
                  write: (key, value) async {
                    records[key] = value;
                  },
                )
              : null,
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/auth/prepare')) {
              prepares++;
              final proof = selected ?? (prepares == 1 ? accountA : accountB);
              if (prepares == 1) {
                entered.complete();
                await release.future;
              }
              selected = proof;
              return fuelReply({});
            }
            if (request.url.path.endsWith('/account'))
              return fuelReply(accountData(selected!));
            created.add(selected!);
            return fuelReply({'account_id': selected});
          }),
        );
        final a = make(), b = make();
        final first = a.bootstrapBrowser();
        await entered.future;
        final second = b.bootstrapBrowser();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final beforeRelease = prepares;
        release.complete();
        await Future.wait([first, second]);
        expect(beforeRelease, 1);
        expect(created, {accountA});
        expect(a.account?.id, accountA);
        expect(b.account?.id, accountA);
        a.close();
        b.close();
      },
    );

  test(
    'another browser selection invalidates the old private owner before further actions',
    () async {
      final before = {
        for (var i = 0; i < web.window.localStorage.length; i++)
          web.window.localStorage.key(i),
      };
      final base = Uri.parse(
        'https://game.example/shared-${randomId()}/fuel/v1',
      );
      FuelClient make(String actor) => FuelClient(
        base,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(actor));
          return fuelReply({'account_id': actor});
        }),
      );
      final a = make(accountA), b = make(accountB);
      await a.bootstrapBrowser();
      await b.bootstrapBrowser();
      final key = {
        for (var i = 0; i < web.window.localStorage.length; i++)
          web.window.localStorage.key(i),
      }.difference(before).first!;
      web.window.dispatchEvent(
        web.StorageEvent('storage', web.StorageEventInit(key: key)),
      );
      for (var i = 0; i < 100 && a.account != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(a.account, isNull);
      expect(a.accountStatus, FuelAccountStatus.identityPending);
      await expectLater(
        a.postChat('global', '', 'wrong account'),
        throwsA(isA<FuelException>()),
      );
      expect(b.account!.id, accountB);
      a.close();
      b.close();
    },
  );
  test(
    'the browser default journal uses real Web Locks and verified local storage',
    () async {
      final base = Uri.parse(
        'https://game.example/title-${randomId()}/fuel/v1',
      );
      FuelClient make() => FuelClient(
        base,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/actions'))
            return fuelReply(operation('known-action', 1, source: 'public'));
          return fuelReply([]);
        }),
      );
      final client = make();
      await client.refreshAccount();
      await client.executeAction(FuelAction('save', {}, id: 'known-action'));
      expect(await client.pendingActions(), isEmpty);
      client.close();
      final again = make();
      await again.refreshAccount();
      expect(await again.pendingActions(), isEmpty);
      again.close();
    },
  );
}
