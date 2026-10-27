import 'dart:async';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'account_owner_test.dart'
    show accountA, accountB, accountData, fuelReply;
import 'operations_test.dart' show journal;

const replacementAccount = 'cccccccccccccccccccccccccccccccc';

Future<(RecordCredentialVault, FuelCredential, FuelCredential)> retained({
  bool Function()? denyWrites,
}) async {
  final records = <String, String>{};
  final vault = RecordCredentialVault(
    read: (key) async => records[key],
    write: (key, value) async {
      if (denyWrites?.call() == true) throw StateError('storage unavailable');
      records[key] = value;
    },
  );
  final previous = FuelCredential.create(), revoked = FuelCredential.create();
  await vault.activate(previous, accountId: accountB);
  await vault.activate(revoked, accountId: accountA);
  return (vault, revoked, previous);
}

bool uses(http.Request request, FuelCredential proof) =>
    request.headers['Authorization'] == 'Fuel ${proof.id}:${proof.secret}';

http.Response unauthorized() =>
    http.Response('{"wire_version":1,"error":"unauthorized"}', 401);

void main() {
  test(
    'explicit browser guest recovers a definitively rejected cookie',
    () async {
      var rejected = true, bootstraps = 0;
      final preparations = <String?>[];
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: journal({}),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/prepare')) {
            preparations.add(request.url.queryParameters['new']);
            if (request.url.queryParameters['new'] == 'true') rejected = false;
            return fuelReply({});
          }
          if (request.url.path.endsWith('/auth/bootstrap')) {
            bootstraps++;
            return rejected
                ? unauthorized()
                : fuelReply({'account_id': accountA});
          }
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(accountA));
          if (request.url.path.endsWith('/auth/selection'))
            return fuelReply({
              'current': {'binding_id': 'new', 'account_id': accountA},
              'previous': {'binding_id': 'previous', 'account_id': accountB},
            });
          throw StateError('Unexpected request');
        }),
      );
      try {
        await client.bootstrapBrowser(newGuest: true);
        expect(client.account?.id, accountA);
        expect(preparations, [null, 'true']);
        expect(bootstraps, 2);
        expect(await client.hasPreviousAccount(), isTrue);
      } finally {
        client.close();
      }
    },
  );

  for (final explicit in [false, true]) {
    test(
      'browser bootstrap $explicit keeps valid or uncertain cookies',
      () async {
        final preparations = <String?>[];
        var failure = false;
        final client = FuelClient(
          Uri.parse('https://game.example'),
          journal: journal({}),
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/auth/prepare')) {
              preparations.add(request.url.queryParameters['new']);
              return fuelReply({});
            }
            if (request.url.path.endsWith('/auth/bootstrap'))
              return failure
                  ? http.Response(
                      '{"wire_version":1,"error":"unavailable"}',
                      503,
                    )
                  : fuelReply({'account_id': accountA});
            if (request.url.path.endsWith('/account'))
              return fuelReply(accountData(accountA));
            throw StateError('Unexpected request');
          }),
        );
        try {
          await client.bootstrapBrowser(newGuest: explicit);
          expect(client.account?.id, accountA);
          expect(preparations, [null]);
          failure = true;
          await expectLater(
            client.bootstrapBrowser(newGuest: explicit),
            throwsA(
              isA<FuelException>().having((e) => e.status, 'status', 503),
            ),
          );
          expect(preparations, [null, null]);
        } finally {
          client.close();
        }
      },
    );
  }

  test(
    'ordinary browser bootstrap does not replace a rejected cookie',
    () async {
      final preparations = <String?>[];
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: journal({}),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/prepare')) {
            preparations.add(request.url.queryParameters['new']);
            return fuelReply({});
          }
          return unauthorized();
        }),
      );
      try {
        await expectLater(
          client.bootstrapBrowser(),
          throwsA(isA<FuelException>()),
        );
        expect(preparations, [null]);
      } finally {
        client.close();
      }
    },
  );

  test('a late browser rejection cannot start cookie replacement', () async {
    final entered = Completer<void>(), response = Completer<http.Response>();
    var preparations = 0;
    final client = FuelClient(
      Uri.parse('https://game.example'),
      journal: journal({}),
      httpClient: MockClient((request) {
        if (request.url.path.endsWith('/auth/prepare')) {
          preparations++;
          return Future.value(fuelReply({}));
        }
        entered.complete();
        return response.future;
      }),
    );
    try {
      final assertion = expectLater(
        client.bootstrapBrowser(newGuest: true),
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await entered.future;
      client.credential = FuelCredential.create();
      response.complete(unauthorized());
      await assertion;
      expect(preparations, 1);
      expect(client.account, isNull);
    } finally {
      client.close();
    }
  });

  test(
    'browser retries a lost replacement bootstrap without rotating again',
    () async {
      var rejected = true, replacementPosts = 0, renewals = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        journal: journal({}),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/prepare')) {
            if (request.url.queryParameters['new'] == 'true') {
              renewals++;
              rejected = false;
            }
            return fuelReply({});
          }
          if (request.url.path.endsWith('/auth/bootstrap')) {
            if (rejected) return unauthorized();
            if (++replacementPosts == 1)
              throw http.ClientException('committed, lost response');
            return fuelReply({'account_id': accountA});
          }
          return fuelReply(accountData(accountA));
        }),
      );
      try {
        await expectLater(
          client.bootstrapBrowser(newGuest: true),
          throwsA(isA<http.ClientException>()),
        );
        expect(client.account, isNull);
        await client.bootstrapBrowser(newGuest: true);
        expect(client.account?.id, accountA);
        expect(renewals, 1);
        expect(replacementPosts, 2);
      } finally {
        client.close();
      }
    },
  );

  test(
    'a late rejection cannot replace the proof after identity changes',
    () async {
      final (vault, revoked, _) = await retained();
      final entered = Completer<void>(), response = Completer<http.Response>();
      var posts = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) {
          posts++;
          entered.complete();
          return response.future;
        }),
      );
      try {
        final starting = client.bootstrapNative(vault, newGuest: true);
        final assertion = expectLater(
          starting,
          throwsA(
            isA<FuelException>().having((e) => e.code, 'code', 'cancelled'),
          ),
        );
        await entered.future;
        client.credential = FuelCredential.create();
        response.complete(unauthorized());
        await assertion;
        expect(posts, 1);
        expect((await vault.read('active'))!.id, revoked.id);
        expect(client.account, isNull);
      } finally {
        client.close();
      }
    },
  );

  test(
    'explicit new guest replaces only a rejected proof and keeps previous guest',
    () async {
      final (vault, revoked, previous) = await retained();
      var posts = 0;
      final savedProofUsed = <bool>[];
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/bootstrap')) {
            posts++;
            if (uses(request, revoked)) return unauthorized();
            savedProofUsed.add(uses(request, (await vault.read('active'))!));
            return fuelReply({'account_id': replacementAccount});
          }
          if (request.url.path.endsWith('/account'))
            return fuelReply(accountData(replacementAccount));
          return fuelReply([]);
        }),
      );
      final game = FuelGameController(client);
      try {
        await expectLater(
          client.bootstrapNative(vault),
          throwsA(isA<FuelException>()),
        );
        expect((await vault.read('active'))!.id, revoked.id);
        await game.start(vault: vault, newGuest: true);
        expect(client.account!.id, replacementAccount);
        expect((await vault.read('active'))!.id, isNot(revoked.id));
        expect((await vault.read('active'))!.id, isNot(previous.id));
        expect((await vault.read('previous'))!.id, previous.id);
        expect(posts, 3);
        expect(savedProofUsed, [true]);
      } finally {
        await game.dispose();
        client.close();
      }
    },
  );

  test(
    'a lost replacement bootstrap reuses its saved proof on explicit retry',
    () async {
      final (vault, revoked, previous) = await retained();
      final replacementHeaders = <String>[];
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/bootstrap')) {
            if (uses(request, revoked)) return unauthorized();
            replacementHeaders.add(request.headers['Authorization']!);
            if (replacementHeaders.length == 1)
              throw http.ClientException('committed, lost response');
            return fuelReply({'account_id': replacementAccount});
          }
          return fuelReply(accountData(replacementAccount));
        }),
      );
      try {
        await expectLater(
          client.bootstrapNative(vault, newGuest: true),
          throwsA(isA<http.ClientException>()),
        );
        final saved = (await vault.read('active'))!.id;
        expect(saved, isNot(revoked.id));
        expect(client.account, isNull);
        await client.bootstrapNative(vault, newGuest: true);
        expect(replacementHeaders.length, 2);
        expect(replacementHeaders[0] == replacementHeaders[1], isTrue);
        expect((await vault.read('active'))!.id, saved);
        expect((await vault.read('previous'))!.id, previous.id);
      } finally {
        client.close();
      }
    },
  );

  for (final pending in ['deletion', 'selection']) {
    test('explicit guest cannot bypass uncertain $pending', () async {
      final (vault, revoked, previous) = await retained();
      final key = pending == 'deletion'
          ? 'account:$accountA:deletion'
          : 'selection';
      final intent = pending == 'deletion'
          ? {'account_id': accountA, 'proof': randomId(32)}
          : {
              'id': randomId(),
              'kind': 'switch',
              'from': revoked.id,
              'to': previous.id,
            };
      await vault.writeEntry(key, intent);
      var bootstraps = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/bootstrap')) bootstraps++;
          throw http.ClientException('identity outcome unavailable');
        }),
      );
      try {
        await expectLater(
          client.bootstrapNative(vault, newGuest: true),
          throwsA(isA<http.ClientException>()),
        );
        expect(bootstraps, 0);
        expect(await vault.readEntry(key), intent);
        expect((await vault.read('active'))!.id, revoked.id);
      } finally {
        client.close();
      }
    });
  }

  for (final failure in ['network', '503', '500-unauthorized']) {
    test('explicit guest does not replace on $failure', () async {
      final (vault, revoked, previous) = await retained();
      var posts = 0;
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          posts++;
          if (failure == 'network') throw http.ClientException('offline');
          return http.Response(
            '{"wire_version":1,"error":"${failure == '503' ? 'unavailable' : 'unauthorized'}"}',
            failure == '503' ? 503 : 500,
          );
        }),
      );
      try {
        await expectLater(
          client.bootstrapNative(vault, newGuest: true),
          throwsA(isA<Exception>()),
        );
        expect(posts, 1);
        expect((await vault.read('active'))!.id, revoked.id);
        expect((await vault.read('previous'))!.id, previous.id);
      } finally {
        client.close();
      }
    });
  }

  test(
    'replacement storage failure stops before sending the new proof',
    () async {
      var denyWrites = false, posts = 0;
      final (vault, revoked, previous) = await retained(
        denyWrites: () => denyWrites,
      );
      final client = FuelClient(
        Uri.parse('https://game.example'),
        httpClient: MockClient((request) async {
          posts++;
          denyWrites = true;
          return unauthorized();
        }),
      );
      try {
        await expectLater(
          client.bootstrapNative(vault, newGuest: true),
          throwsA(
            isA<FuelException>().having((e) => e.code, 'code', 'storage_error'),
          ),
        );
        expect(posts, 1);
        denyWrites = false;
        expect((await vault.read('active'))!.id, revoked.id);
        expect((await vault.read('previous'))!.id, previous.id);
      } finally {
        client.close();
      }
    },
  );
}
