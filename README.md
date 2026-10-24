# Fuel and Flame

MIT-licensed companion packages for the [Fuel Crystal backend](https://github.com/Xanders/fuel).

| Package | Role | Runtime dependencies |
|---|---|---|
| fuel_client | Pure Dart API, credentials/vault contract, exact commands, polling/recovery, realtime inputs | http, web_socket_channel |
| fuel_flutter | Optional application lifecycle and input rearm helpers | Flutter, fuel_client |
| fuel_flame | Optional snapshot/event presentation components | Flame, fuel_client |

The core Dart SDK has no Flutter or Flame dependency. The monorepo development workspace includes both optional packages, so its full test workflow requires Flutter. Registry publication has not been performed; use a reviewed Git commit and package path.

## Behavior

The server owns game rules, legal actions, scores, deadlines and private state. The SDK owns transport, IDs, cancellation/generation fences and recovery. Flutter owns platform UI/lifecycle; Flame displays accepted snapshots/events. Pausing Flame or backgrounding Flutter does not pause a server match.

Fuel sessions live in RAM and are lost on backend restart. `session_lost` is explicit; it never creates a replacement guest automatically. Permanent progress uses PostgreSQL on the server.

[Usage and recovery](docs/USAGE.md) · [Wire reference](https://github.com/Xanders/fuel/blob/main/docs/API.md) · [Roadmap](docs/ROADMAP.md)

```dart
final client = FuelClient(Uri.parse('https://game.example'));
await client.bootstrapBrowser(); // HttpOnly cookie, same-origin browser API
final room = await client.createRoom('duel');
final session = FuelSession(client)..select(room['session_id'] as String);
await session.poll();
```

Native apps use `bootstrapNative(vault)` with an OS-backed `CredentialVault`. Secrets must not be stored in ordinary preferences or logs.

## Development

The validated toolchain is Flutter 3.44.0 / Dart 3.12.0 and Flame 1.38.2. The workspace lockfile records exact test dependencies.

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
