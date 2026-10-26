# SDK use and recovery

Pin the backend and all imported SDK packages to the same reviewed release. These development APIs may change; the envelope's wire_version alone does not imply compatibility with older packages. The core is pure Dart. Flutter and Flame are optional presentation/lifecycle bridges.

## One application owner

```dart
final fuel = FuelClient(Uri.parse('https://game.example/app/fuel/v1'));
final game = FuelGameController(fuel);
await game.start(); // browser: restore identity, pending actions, receipts, membership
if (fuel.account != null && game.sessionId == null) await game.create('solo');
```

An origin-only base uses `/fuel/v1/`. A configured path is the complete application API prefix. Relative request paths cannot escape that prefix/host. Browser API is same-origin; native requests use HTTPS outside loopback tests.

FuelClient owns account/progress, identity generation, storage/journal, profile single-flight and service facades. FuelGameController composes FuelSession and FuelRealtime for one selected room, readiness, liveness, reconnect backoff and disposal. Listen to their update streams. Account progress and operation payload accessors return copies.

`game.input` accepts only transient intent after an authoritative socket snapshot. Do not replay movement after loss. `game.ready`, create/code/public join, match, leave and recoverRoom share canonical session routes. An unknown room creation is recovered with recoverRoom, not another create. Match intents retain their explicit ticket ID; cancellation uses the same ID.

States distinguish offline, unauthorized, identity pending, deleted, storage failure, lost RAM session and saving backpressure. Lost sessions offer a deliberate new session; they never create a new guest automatically. Saving blocks input until authoritative snapshots clear the backlog. Suspending local presentation does not pause server deadlines.

Leaving a room can enqueue a final persistent effect before the next admission. If create, code/public join or matchmaking receives an explicit HTTP 400 `pending_result` rejection, the game controller waits in `saving` and retries the same admission, preserving the match ticket. Waiting is bounded by the existing client timeout budget; each HTTP request retains its transport timeout. Suspension, identity changes and disposal stop it. An unknown admission outcome still requires membership recovery; it is never blindly repeated.

## Identity and storage

Browser bootstrap prepares a namespace-specific HttpOnly cookie before creating/restoring the permanent guest. The SDK cannot read its secret. The default journal uses namespaced localStorage, two verified records and Web Locks. It contains public selection metadata and pending operation/deletion proofs, never a device login secret. Storage/lock failures fail closed; clearing all browser storage can still lose access. One selected browser account per application/origin is shared across tabs. Selection changes invalidate other tabs' private projections; expected-account headers and socket admission prevent a stale tab acting as another player.

Browser identity transitions hold a separate namespace Web Lock across cookie preparation, reconciliation and verified journal publication, including when a custom journal is supplied. Record transactions use their own lock so saving within a transition cannot deadlock. Deletion recovery cannot clear an unrelated pending selection without confirming the selected account.

Native products supply OS-protected callbacks:

```dart
final vault = RecordCredentialVault(
  read: (slot) => secureStorage.read(key: 'my-game-fuel-$slot'),
  write: (slot, value) => secureStorage.write(key: 'my-game-fuel-$slot', value: value),
);
await game.start(vault: vault);
```

The `secureStorage` object above is the application's OS adapter. Do not replace it with ordinary preferences or logs. Callbacks must store independent slots a/b; use one serialized vault instance per record pair, or supply a process-wide lock when sharing it. The vault checks written records by reading them, preserves active/previous/candidate and pending intents, and refuses corrupt records rather than generating replacement credentials. Retained previous bindings are bounded, never silently evicted to make room. Native WebSocket authorization headers are supplied by the SDK; browser sockets use cookies, never secrets in URLs.

For explicit custom ports, FuelJournal supplies atomic updateEntry, completeSelection and completeDeletion semantics. A native CredentialVault additionally implements read/write/activate, including conditional selectionId completion. Use the supplied record implementations rather than copying rotation logic. MemoryFuelJournal is intentionally nondurable; persistent actions/deletion/account changes require a durable journal.

A issues issuePair; B calls prepareTransfer then requestPair(code). A compares the phrase from pendingPairs/issuedPair and approves the exact ID. B checks pairStatus then activateTransfer. switchPrevious returns to a retained guest without merging progress. Linked activation is idempotent. Preparation retains an outstanding proof; newAttempt is a deliberate abandonment, never an automatic timeout response.

Identity admission is synchronous and exclusive before any await. Transitions clear private state and stop old sockets. Frozen source/target intents are saved before selection; atomic completion cannot erase a newer intent. A lost response remains identityPending and blocks private activity until bootstrap/retry reconciles it. Native activation saves and verifies the proof before publishing selection. Socket reconnect does not change HTTP identity or cancel unrelated account requests.

`deleteAccount(confirmed:true)` needs a loaded account and saved random deletion proof. A timeout is unknown, not success. recoverDeletion or bootstrap checks that proof after restart, even when the old login proof is gone. Confirmed deletion atomically forgets only returned removed binding IDs and that account's journal; another retained account is preserved. A durable deleted marker prevents automatic guest recreation. `game.start(newGuest:true)` is an explicit new-guest intent after confirmed deletion; switchPrevious can instead recover a surviving guest. Revoke the last active binding only with confirmedLast:true.

## Permanent actions and confirmed results

```dart
final intent = FuelAction('buy', {'item': 'blade'});
final committed = await fuel.executeAction(intent);
```

One immutable intent owns one random operation ID. The journal saves it before network mutation. An unknown response retains it and blocks a different intent. retryPendingActions first reads the original receipt, then posts exactly the same action only if unknown. A definite rejection releases the intent. A known commit stays successful if subsequent profile synchronization fails; surface lastError and retry synchronization rather than repeating the purchase with a new ID.

`recoverOperations` works without a socket, including after server RAM loss. The per-account presentation cursor is saved before emitting each recovered page. Repeated recovery cannot replay those animations after a successful save. A fresh journal anchors the latest page and exposes lastOperation as the latest terminal summary without animating old history. More than 64 pending presentations requests resync and exposes operationGap. The latest terminal summary is independently recoverable behind ordinary history. Old receipts never overwrite current balances: the owner refreshes account progress from the server.

Durable receipts do not restore a RAM match. Unsaved session state/work can be lost on process restart under Fuel's explicit storage contract. Committed permanent actions/receipts remain in PostgreSQL until account deletion.

Session commands are separate: construct one FuelCommand(id,epoch,revision,action) for an intent, retain it after uncertainty and retry the same body. A revision conflict requires current state and a new deliberate intent; never silently rebase. Optional PendingCommands ports cannot restore a lost session.

## Flutter and Flame

FuelGameModel owns FuelClient/FuelGameController, adapts update streams into ChangeNotifier, observes Flutter lifecycle and disarms FuelInputGate. Disposal closes its owned account/session/transports. Use its fuel/game fields directly from settings and menus. The smaller FuelLifecycle remains available for standalone FuelSession integrations.

FuelInputGate rearms a held discrete action only after neutral. The application still maps platform keys/axes into game actions and owns HUD/modal focus.

FuelSnapshotComponent coalesces full snapshots until the next frame. FuelEventComponent presents ordered events at a readable interval (default100ms) with a bounded queue; supply owner:fuel to clear queued events across account changes. Overflow/source error pauses presentation and calls onResync; install current state/summary then call reset. These components never run game rules, award time/scores, choose a camera or pause server deadlines.

## Service facades and low-level integration

FuelClient exposes account/actions/history, device transfer/bindings/revocation/deletion, room admission/matching/commands, chat history/posting/mutes/reports, leaderboards/ratings and confirmed analytics opt-out. IDs in request bodies confer no authority. Analytics choices publish only after fresh server confirmation; stale account reads cannot overwrite a newer confirmation.

FuelHttpTransport and FuelConnection remain bounded low-level IO engines for controlled incremental integrations. They do not implement identity, durable intents or game rules. Importing them alone is transport adoption, not a complete framework migration. Canonical new clients should compose the owners above.

HTTP defaults: 64KiB request, 1MiB response, 64 pending requests, one20-second headers/body deadline. Cancellation/timeout/close reject late completion; cleanup is bounded to3seconds. Socket defaults:20-second readiness,1MiB message,32 early messages,3-second cleanup. FuelRealtime additionally requires snapshots for its12-second liveness deadline; ordinary feedback cannot hide a stale world. Low-level budgets remain configurable positive values.
