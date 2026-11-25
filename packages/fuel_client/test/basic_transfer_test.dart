import 'dart:async';
import 'dart:convert';

import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'account_owner_test.dart'
    show accountA, accountB, accountData, fuelReply;
import 'operations_test.dart' show journal;
import 'review_regression_test.dart' show TestChannel;

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
    'ordinary room frames survive a delayed no-work transfer lookup',
    () async {
      final records = <String, String>{};
      final entered = Completer<void>(), release = Completer<void>();
      var delay = false;
      final storage = RecordJournal(
        read: (key) async {
          if (delay) {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          }
          return records[key];
        },
        write: (key, value) async => records[key] = value,
      );
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: storage,
        httpClient: MockClient(
          (request) async => request.url.path.endsWith('/account')
              ? fuelReply(accountData(accountA))
              : fuelReply({'account_id': accountA}),
        ),
      );
      final session = FuelSession(client)..select('room');
      final channel = TestChannel();
      final live = FuelRealtime(channel, session);
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await live.close();
        await session.dispose();
        client.close();
      });
      await client.bootstrapBrowser();
      session.select('room');
      await live.connect();
      channel.emit('ready', '0');
      delay = true;
      final noWork = expectLater(
        client.recoverBasicTransfer(),
        throwsA(
          isA<FuelException>().having(
            (e) => e.code,
            'code',
            'missing_transfer',
          ),
        ),
      );
      await entered.future;
      channel.emit('during lookup', '1');
      release.complete();
      await noWork;
      expect(live.generation, 'g');
      expect(session.current?.state['private'], 'during lookup');
      expect((await client.refreshAccount()).id, accountA);
    },
  );

  for (final linked in [false, true]) {
    test(
      'an unanswered deletion cannot strand transfer recovery (linked: $linked)',
      () async {
        final shared = journal({});
        const retained = 'cccccccccccccccccccccccccccccccc';
        String active = 'old';
        var revoked = false, receiptAvailable = false, deletes = 0;
        FuelClient open() => FuelClient(
          Uri.parse('https://game.example'),
          journal: shared,
          httpClient: MockClient((request) async {
            final path = request.url.path.substring('/fuel/v1/'.length);
            final account = switch (active) {
              'old' => accountB,
              'target' => accountA,
              _ => retained,
            };
            final valid = active != 'old' || !revoked;
            final denied = http.Response(
              '{"wire_version":1,"error":"unauthorized"}',
              401,
            );
            switch (path) {
              case 'auth/bootstrap':
                return valid ? fuelReply({'account_id': account}) : denied;
              case 'account':
                return valid ? fuelReply(accountData(account)) : denied;
              case 'auth/selection':
                return fuelReply({
                  'current': {
                    'binding_id': active,
                    'account_id': valid ? account : null,
                  },
                  'previous': {
                    'binding_id': 'retained',
                    'account_id': retained,
                  },
                  'candidate_id': 'target',
                });
              case 'auth/pair/redeem':
                throw http.ClientException('Held redemption');
              case 'auth/pair/status':
                return revoked && linked ? basicReply() : denied;
              case 'auth/pair/abandon':
                return fuelReply({'status': 'retired'});
              case 'auth/pair/activate':
                active = 'target';
                return fuelReply({'account_id': accountA});
              case 'auth/delete/status':
                if (receiptAvailable) {
                  return fuelReply({
                    'status': 'deleted',
                    'removed_bindings': ['old', 'target'],
                  });
                }
                return fuelReply({'status': 'unknown'});
              case 'auth/delete/with-transfer':
                if (++deletes == 1) throw http.ClientException('Held deletion');
                return denied;
              case 'auth/switch':
                active = 'retained';
                return fuelReply({'account_id': retained});
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
        final prior = open();
        addTearDown(prior.close);
        await prior.bootstrapBrowser();
        await expectLater(
          prior.deleteAccount(confirmed: true),
          throwsA(isA<http.ClientException>()),
        );
        final key = 'account:$accountB:deletion';
        final proof = (await shared.readEntry(key))?['proof'];
        expect(proof, isA<String>());
        revoked = true;
        final reopened = open();
        addTearDown(reopened.close);
        if (linked) {
          await reopened.bootstrapBrowser();
          expect(reopened.account?.id, accountA);
        } else {
          await expectLater(
            reopened.bootstrapBrowser(),
            throwsA(
              isA<FuelException>().having(
                (e) => e.code,
                'code',
                'unauthorized',
              ),
            ),
          );
          await reopened.switchPrevious();
          expect(reopened.account?.id, retained);
        }
        expect(await shared.readEntry('selection'), isNull);
        expect((await shared.readEntry(key))?['proof'], proof);
        await reopened.bootstrapBrowser();
        expect(deletes, 2);
        if (!linked) {
          receiptAvailable = true;
          await reopened.bootstrapBrowser();
          expect(reopened.account?.id, retained);
          expect(await shared.readEntry(key), isNull);
          expect(deletes, 2);
        }
      },
    );
  }

  for (final revokedTarget in [true, false]) {
    test(
      'recovers after independent revocation (target: $revokedTarget)',
      () async {
        final shared = journal({});
        const retained = 'cccccccccccccccccccccccccccccccc';
        var revoked = false, previous = false, abandons = 0;
        FuelClient open() => FuelClient(
          Uri.parse('https://game.example'),
          journal: shared,
          httpClient: MockClient((request) async {
            final path = request.url.path.substring('/fuel/v1/'.length);
            final valid = previous || !revoked || revokedTarget;
            final actor = previous ? retained : accountB;
            switch (path) {
              case 'auth/bootstrap':
                if (!valid)
                  return http.Response(
                    '{"wire_version":1,"error":"unauthorized"}',
                    401,
                  );
                return fuelReply({'account_id': actor});
              case 'auth/selection':
                return fuelReply({
                  'current': {
                    'binding_id': previous ? 'retained' : 'old',
                    'account_id': valid ? actor : null,
                  },
                  'previous': {
                    'binding_id': 'retained',
                    'account_id': retained,
                  },
                  'candidate_id': 'candidate',
                });
              case 'auth/pair/redeem':
                throw http.ClientException('No response');
              case 'auth/pair/status':
                expect(request.url.queryParameters['target_id'], 'candidate');
                if (revokedTarget) return fuelReply({'status': 'retired'});
                return http.Response(
                  '{"wire_version":1,"error":"unauthorized"}',
                  401,
                );
              case 'auth/pair/abandon':
                expect(jsonDecode(request.body), {'target_id': 'candidate'});
                abandons++;
                return fuelReply({'status': 'retired'});
              case 'auth/switch':
                previous = true;
                return fuelReply({'account_id': retained});
              case 'account':
                return fuelReply(accountData(actor));
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
        revoked = true;
        final reopened = open();
        addTearDown(reopened.close);
        if (revokedTarget) {
          await reopened.bootstrapBrowser();
          expect(reopened.account?.id, accountB);
        } else {
          await expectLater(
            reopened.bootstrapBrowser(),
            throwsA(
              isA<FuelException>().having(
                (e) => e.code,
                'code',
                'unauthorized',
              ),
            ),
          );
        }
        expect(abandons, revokedTarget ? 0 : 1);
        expect(await shared.readEntry('selection'), isNull);
        await reopened.switchPrevious();
        expect(reopened.account?.id, retained);
      },
    );
  }

  for (final linked in [false, true]) {
    test('deleting B reconciles a lost transfer (linked: $linked)', () async {
      final shared = journal({});
      const other = 'cccccccccccccccccccccccccccccccc';
      String? active = 'old';
      var deleted = false, committed = false;
      FuelClient open() => FuelClient(
        Uri.parse('https://game.example'),
        journal: shared,
        httpClient: MockClient((request) async {
          final path = request.url.path.substring('/fuel/v1/'.length);
          final id = switch (active) {
            'old' => accountB,
            'incoming' => accountA,
            _ => other,
          };
          switch (path) {
            case 'auth/bootstrap':
              return fuelReply({'account_id': id});
            case 'auth/selection':
              return fuelReply({
                'current': active == null
                    ? null
                    : {'binding_id': active, 'account_id': id},
                'previous': {'binding_id': 'retained', 'account_id': other},
                'candidate_id': deleted ? null : 'incoming',
              });
            case 'auth/pair/redeem':
              throw http.ClientException('No reply');
            case 'auth/pair/status':
              if (committed) return basicReply();
              return http.Response(
                '{"wire_version":1,"error":"unauthorized"}',
                401,
              );
            case 'auth/pair/activate':
              active = 'incoming';
              return fuelReply({'account_id': accountA});
            case 'auth/delete/status':
              return fuelReply({'status': 'unknown'});
            case 'auth/delete/with-transfer':
              expect(
                jsonDecode(request.body),
                containsPair('abandon_candidate_id', 'incoming'),
              );
              if (linked) {
                return http.Response(
                  '{"wire_version":1,"error":"transfer_completed"}',
                  400,
                );
              }
              active = null;
              deleted = true;
              return fuelReply({
                'status': 'deleted',
                'removed_bindings': ['old', 'incoming'],
              });
            case 'auth/switch':
              expect(jsonDecode(request.body), {
                'from': null,
                'to': 'retained',
              });
              active = 'retained';
              return fuelReply({'account_id': other});
            case 'account':
              return fuelReply(accountData(id));
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
      final prior = open();
      addTearDown(prior.close);
      await prior.bootstrapBrowser();
      expect(prior.account?.id, accountB);
      committed = linked;
      if (linked) {
        await expectLater(
          prior.deleteAccount(confirmed: true),
          throwsA(
            isA<FuelException>().having(
              (e) => e.code,
              'code',
              'transfer_completed',
            ),
          ),
        );
        expect(await shared.readEntry('account:$accountB:deletion'), isNull);
      } else {
        await prior.deleteAccount(confirmed: true);
        expect(await shared.readEntry('selection'), isNull);
      }
      final restarted = open();
      addTearDown(restarted.close);
      final result = await restarted.bootstrapBrowser();
      if (linked) {
        expect(result['account_id'], accountA);
        expect(deleted, isFalse);
      } else {
        expect(result['status'], 'deleted');
        await restarted.switchPrevious();
        expect(restarted.account?.id, other);
      }
    });
  }

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
                'previous': {
                  'binding_id': 'retained',
                  'account_id': 'cccccccccccccccccccccccccccccccc',
                },
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
      expect(restarted.recoveredBasicTransferOnStartup, isFalse);
      expect((await shared.readEntry('selection'))?['to'], 'candidate');
      expect(await restarted.hasPreviousAccount(), isTrue);
      await expectLater(
        restarted.switchPrevious(),
        throwsA(
          isA<FuelException>().having(
            (e) => e.code,
            'code',
            'pending_identity',
          ),
        ),
      );
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
      expect(other.recoveredBasicTransferOnStartup, isTrue);
      expect(await shared.readEntry('selection'), isNull);
      expect(prepares, 1);
      expect(redeems, 1);
      expect((await other.refreshAccount()).id, accountA);
      expect(other.recoveredBasicTransferOnStartup, isTrue);
      expect(await other.bootstrapBrowser(), {'account_id': accountA});
      expect(other.recoveredBasicTransferOnStartup, isFalse);
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

  test(
    'native controller reports saved Basic even when room startup fails',
    () async {
      final records = <String, String>{};
      final vault = RecordCredentialVault(
        read: (key) async => records[key],
        write: (key, value) async => records[key] = value,
      );
      final previous = FuelCredential.create(),
          candidate = FuelCredential.create();
      await vault.activate(previous, accountId: accountB);
      await vault.write('candidate', candidate);
      await vault.writeEntry('selection', {
        'id': randomId(),
        'kind': 'basic',
        'from': previous.id,
        'to': candidate.id,
      });
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          final path = request.url.path.substring('/fuel/v1/'.length);
          switch (path) {
            case 'auth/pair/status':
              expect(
                request.headers['Authorization'],
                'Fuel ${candidate.id}:${candidate.secret}',
              );
              return fuelReply({
                'status': 'linked',
                'mode': 'basic',
                'account_id': accountA,
              });
            case 'account':
              expect(
                request.headers['Authorization'],
                'Fuel ${candidate.id}:${candidate.secret}',
              );
              return fuelReply(accountData(accountA));
            case 'auth/bootstrap':
              return fuelReply({'account_id': accountA});
            default:
              return http.Response(
                '{"wire_version":1,"error":"maintenance"}',
                503,
              );
          }
        }),
      );
      final game = FuelGameController(client);
      addTearDown(() async {
        await game.dispose();
        client.close();
      });
      await expectLater(
        game.start(vault: vault),
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'maintenance'),
        ),
      );
      expect(game.client.account?.id, accountA);
      expect(game.client.recoveredBasicTransferOnStartup, isTrue);
      expect(await vault.readEntry('selection'), isNull);
      expect((await vault.read('previous'))?.id, previous.id);
      expect(await client.bootstrapNative(vault), {'account_id': accountA});
      expect(client.recoveredBasicTransferOnStartup, isFalse);
    },
  );

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
    final generation = client.generation;
    await expectLater(
      client.recoverBasicTransfer(),
      throwsA(
        isA<FuelException>().having((e) => e.code, 'code', 'missing_transfer'),
      ),
    );
    expect(client.generation, generation);
    expect((await client.refreshAccount()).id, accountA);
  });
}
