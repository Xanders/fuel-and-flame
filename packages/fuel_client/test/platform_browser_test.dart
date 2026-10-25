@TestOn('browser')
library;

import 'dart:async';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;
import 'account_owner_test.dart'
    show accountA, accountB, accountData, fuelReply;
import 'operations_test.dart' show operation;

void main() {
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
