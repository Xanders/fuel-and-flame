# Fuel and Flame

MIT-licensed companion packages for the [Fuel Crystal backend](https://github.com/Xanders/fuel).

| Package | Role | Runtime dependencies |
|---|---|---|
| fuel_client | Account/identity owner, verified vault/journal, durable actions/recovery, session controller and transport | crypto, http, web, web_socket_channel |
| fuel_flutter | Optional notifier/lifecycle composition and input rearm | Flutter, fuel_client |
| fuel_flame | Optional snapshot/event presentation components | Flame, fuel_client |

The core Dart SDK has no Flutter or Flame dependency. The monorepo development workspace includes both optional packages, so its full test workflow requires Flutter. Registry publication has not been performed; use a reviewed Git commit and package path.

## Behavior

The server owns game rules, legal actions, scores, deadlines and private state. The SDK owns transport, IDs, cancellation/generation fences and recovery. Flutter owns platform UI/lifecycle; Flame displays accepted snapshots/events. Pausing Flame or backgrounding Flutter does not pause a server match.

Fuel sessions live in RAM and are lost on backend restart. `session_lost` is explicit; it never creates a replacement guest automatically. Permanent progress uses PostgreSQL on the server.

[Usage and recovery](docs/USAGE.md) · [Wire reference](https://github.com/Xanders/fuel/blob/main/docs/API.md) · [Roadmap](docs/ROADMAP.md)

```dart
final client = FuelClient(Uri.parse('https://game.example'));
await client.bootstrapBrowser(); // HttpOnly cookie, same-origin browser API
final game = FuelGameController(client);
await client.recoverOperations();
await game.recoverRoom();
if (game.sessionId == null) await game.create('duel');
```

Native apps use `bootstrapNative(vault)` with an OS-backed `CredentialVault`. Secrets must not be stored in ordinary preferences or logs.

## Install optional bridges from Git

Until registry publication, an external Flutter app must pin both its bridge and the core override to the same reviewed tag or immutable commit. The development workspace's sibling resolution does not carry into a consuming app.

```yaml
dependencies:
  flutter:
    sdk: flutter
  fuel_flutter:
    git:
      url: https://github.com/Xanders/fuel-and-flame.git
      ref: v0.3.0
      path: packages/fuel_flutter
dependency_overrides:
  fuel_client:
    git:
      url: https://github.com/Xanders/fuel-and-flame.git
      ref: v0.3.0
      path: packages/fuel_client
```

For Flame use the same Git mapping with package name `fuel_flame` and path `packages/fuel_flame`. If the app imports `fuel_client` directly, also declare it in `dependencies` with that core Git mapping. The override keeps transitive bridge dependencies on the same source.

## Development

The validated toolchain is Flutter 3.44.8 / Dart 3.12.2 and Flame 1.38.2. The workspace lockfile records exact test dependencies.

```sh
flutter pub get
dart analyze
cd packages/fuel_client
dart test
cd ../fuel_flutter
flutter test
cd ../fuel_flame
flutter test
```

[The counter client](packages/fuel_client/example/counter.dart) runs against Fuel's neutral counter server and verifies exact retry and persisted results. It deliberately uses process-local credentials for an isolated demo only.
