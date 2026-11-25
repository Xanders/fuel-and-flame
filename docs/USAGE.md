# SDK use and recovery

Pin the backend and SDK to a reviewed compatible pair; their release numbers may differ. Pin all imported SDK packages to the same reviewed SDK commit. These development APIs may change; the envelope's wire_version alone does not imply compatibility with older packages. The core is pure Dart. Flutter and Flame are optional presentation/lifecycle bridges.

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

During initial identity admission, `game.start` retries transient ordinary `auth/prepare` and account reads up to three times, after 500ms, 1s and 2s. Each request retains the normal HTTP deadline. Retries stay inside the original identity transition and browser identity lock, using the same native proof or browser cookie and journal. A lost bootstrap POST response is reconciled with account reads, including bounded waiting for an account not yet visible; the POST is never automatically replayed. If it did not commit or cannot be confirmed within that budget, start throws and exposes `offline` with `identityPending`, preserving the proof for deliberate retry. It does not create another guest or schedule an endless initial loop. Definite authority/protocol/storage failures stop immediately; explicit new-guest cookie rotation and pending selection/deletion recovery are not automatically retried. Suspend, disposal and generation changes stop further initial requests. Standalone `bootstrapBrowser`/`bootstrapNative` retain their single-attempt behavior.

After successful bootstrap, transient startup failures before room selection and unknown create/join outcomes use the controller's existing exponential reconnect backoff, capped at eight seconds with no attempt limit. Without a selected room, recovery first reads durable operations and reconciles the original pending account action, then reads `sessions/mine`. It never repeats the unknown admission POST or creates a replacement room. A confirmed empty membership returns to idle. The initial call still reports its failure; observe controller updates for background recovery rather than treating that first network error as terminal. Suspend, disposal, identity changes, confirmed authority failures and connection displacement retain their stopping rules.

One socket per player owns each room's input generation. A newer connection replaces the old one. On the server's `connection_replaced` envelope the controller stays `offline`, retains the room/board and stops automatic reconnect, including through background/foreground transitions and same-room `recoverRoom()`. Explain the other active connection in the UI and let an explicit `game.connect()` reclaim the room. Identity changes, leaving, empty membership or selecting another room clear that displacement. Ordinary network failures still use automatic backoff. This requires a backend that sends the replacement envelope.

Leaving a room can enqueue a final persistent effect before the next admission. If create, code/public join, matchmaking or leave receives an explicit HTTP 400 `pending_result` rejection, the game controller waits in `saving` and retries the same membership change, preserving the match ticket. Waiting is bounded by the existing client timeout budget; each HTTP request retains its transport timeout. Suspension, identity changes and disposal stop it. An unknown admission outcome still requires membership recovery; it is never blindly repeated.

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

After a native binding is rejected, an explicit `game.start(vault: vault, newGuest: true)` first retries the retained proof. Only a definitive HTTP 401 `unauthorized` permits replacing that active proof. The replacement is verified in the vault before network use; retrying a lost bootstrap reuses it. A retained previous guest survives. Pending deletion/selection reconciliation runs first and cannot be bypassed by this flag. Ordinary bootstrap, network failures and server errors never trigger replacement.

With Fuel0.3.6 or later, browser `game.start(newGuest:true)` follows the same explicit recovery policy. After a definitive bootstrap HTTP401 `unauthorized`, the SDK prepares a replacement active cookie and retries bootstrap once. The backend preserves any still-valid active cookie and the separate previous/candidate slots. A lost replacement-bootstrap response is reconciled using its retained cookie; network/server errors and ordinary startup never trigger replacement. Cookie secrets remain inaccessible to the SDK.

For explicit custom ports, FuelJournal supplies atomic updateEntry, completeSelection and completeDeletion semantics. A native CredentialVault additionally implements read/write/activate, including conditional selectionId completion. Use the supplied record implementations rather than copying rotation logic. MemoryFuelJournal is intentionally nondurable; persistent actions/deletion/account changes require a durable journal.

### Device transfer

Fuel 0.4.0 with SDK 0.4.0 supports both server modes. A calls `issuePair(supportsBasic: true)` when its UI supports the basic flow and reads the server's `mode`. B uses the matching flow for the deployed backend. Code input is one action on a basic server:

```dart
final issued = await deviceA.issuePair(supportsBasic: true);
// On B, prepare the proof once before submitting the entered code.
await deviceB.prepareTransfer(vault: vaultOnNative);
final completed = await deviceB.redeemBasicTransfer(enteredCode);
// deviceB.account is now A's account; its own guest remains available.
if (completed['emojis'] case final List emojis) showDone(emojis);
// On A, read when connected, with this device's own current credential.
final notice = await deviceA.issuedPair(issued['id'] as String);
if (notice['status'] == 'linked') showDone(notice['emojis'] as List);
```

Pass no vault on web. The SDK saves the source and candidate IDs in the selection journal before sending the code. Normal startup with the same storage can resume a committed selection after a lost answer. If the app is still open, call `recoverBasicTransfer()` to check the same proof, or resubmit the code on that proof. A `transfer_pending` result means the server has no confirmed link for the saved attempt yet. The SDK can restore the old guest when its exact binding is still active. It retains the unresolved intent and candidate in case the original request later completes. If the code expires, ask A for a fresh code. Candidate preparation is blocked while this selection is pending. A definitive first rejection, including an invalid code, throttling or maintenance, leaves a verified prior guest usable and releases that attempt. If the already selected basic binding is revoked, recovery can select the verified retained guest. A completion can omit the notice after expiry and still select the account.

A can keep the issued ID and read it again when it reconnects, until the receipt expires one day after the code expiry. If B resumed during startup, it can read the notice with `pairStatus()` on the retained candidate. Use bounded polling while the transfer is visible and deduplicate by receipt ID. Fuel has no transfer push channel. Show the three ordered server emoji under “Done!” with a comparison sentence (“If the same symbols appear on both devices, you're all set”), a support link and an “OK” dismiss action. The consumer owns or can omit this UI.

In confirmed mode, A issues the code and B calls `prepareTransfer` then `requestPair(code)`. A compares the phrase shown on both devices and approves the exact ID with `approvePair`. B checks `pairStatus` and calls `activateTransfer` only after it is linked. `switchPrevious` returns to the retained guest in either mode, without merging progress. A successful link is idempotent. Preparation retains the outstanding proof; `newAttempt` intentionally abandons it. See the [server upgrade guide](https://github.com/Xanders/fuel/blob/v0.4.0/docs/MIGRATION.md#device-transfer-at-040) before changing modes.

`await fuel.hasPreviousAccount()` is a read-only availability hint for account settings, including after confirmed deletion when a previous account may survive. It reads the native vault or browser selection metadata through the SDK, without changing selection, publishing account data, creating a guest or returning credentials. Use it to offer `switchPrevious` only when a different retained binding exists. The hint does not prove that the server still accepts that binding; the ordinary verified transition remains authoritative. Identity changes fence stale replies, and storage/network errors propagate instead of becoming a false absence.

Identity admission is synchronous and exclusive before any await. Transitions clear private state and stop old sockets. Frozen source/target intents are saved before selection; atomic completion cannot erase a newer intent. A lost response remains identityPending and blocks private activity until bootstrap/retry reconciles it. Native activation saves and verifies the proof before publishing selection. Socket reconnect does not change HTTP identity or cancel unrelated account requests.

`deleteAccount(confirmed:true)` needs a loaded account and saved random deletion proof. A timeout is unknown, not success. recoverDeletion or bootstrap checks that proof after restart, even when the old login proof is gone. Confirmed deletion atomically forgets only returned removed binding IDs and that account's journal; another retained account is preserved. A durable deleted marker prevents automatic guest recreation. `game.start(newGuest:true)` is an explicit new-guest intent after confirmed deletion; switchPrevious can instead recover a surviving guest. Revoke the last active binding only with confirmedLast:true.

## Permanent actions and confirmed results

```dart
final intent = FuelAction('buy', {'item': 'blade'});
final committed = await fuel.executeAction(intent);
```

One immutable intent owns one random operation ID. The journal saves it before network mutation. An unknown response retains it and blocks a different intent. retryPendingActions first reads the original receipt, then posts exactly the same action only if unknown. A definite rejection releases the intent. A known commit stays successful if subsequent profile synchronization fails; surface lastError and retry synchronization rather than repeating the purchase with a new ID.

Standalone `executeAction` and `retryPendingActions` perform one attempt; they do not own a background retry loop. A connected game controller reconciles operations and pending actions every five seconds without an attempt limit. The no-room startup recovery above also reconciles pending actions before resolving membership. Successful idle startup without a selected room does not install a permanent action scheduler; call the explicit recovery methods when using the client independently.

Controllers skip permanent-action recovery for nondurable journals, where persistent mutations cannot be admitted. Session-only clients using `MemoryFuelJournal` can still recover membership; this does not make permanent actions or their intents durable.

`recoverOperations` works without a socket, including after server RAM loss. The per-account presentation cursor is saved before emitting each recovered page. Repeated recovery cannot replay those animations after a successful save. A fresh journal anchors the latest page and exposes lastOperation as the latest terminal summary without animating old history. More than 64 pending presentations requests resync and exposes operationGap. The latest terminal summary is independently recoverable behind ordinary history. Old receipts never overwrite current balances: the owner refreshes account progress from the server.

Durable receipts do not restore a RAM match. Unsaved session state/work can be lost on process restart under Fuel's explicit storage contract. Committed permanent actions/receipts remain in PostgreSQL until account deletion.

For discrete session actions, `await game.command({'type':'move', ...})` freezes one ID, epoch, revision and action in the account journal before sending. `game.pendingCommand` exposes an uncertain intent; `retryCommand()` sends that exact body. Reconnect and periodic recovery reconcile it before accepting another command. A definite revision conflict releases the rejected intent and reads current authority; choosing another action remains deliberate. A lost session/epoch discards its old transient intent without replaying it into a replacement room. Identity changes and disposal fence late replies. Native restart recovery requires an OS-backed vault, browser recovery its durable journal.

`game.ready()` uses the membership-readiness endpoint without a command revision. Game-specific acceptance of terms is an ordinary semantic command: a stale revision can require fresh player confirmation. The SDK reads current authority but never automatically changes its revision, accepts changed terms or invents a replacement intent. A rejected command alone does not mean that membership was lost.

An account has at most one uncertain discrete command across its controllers. Selecting another live room never deletes that command; that room may be left or observed, while a new discrete action waits for the original intent to settle. Shared-journal recovery clears stale local pending indicators after another controller resolves the intent. A rejected old move during reconnect does not invalidate a successfully recovered room.

The lower-level `FuelClient.command` still accepts a caller-owned `FuelCommand`. Its optional `PendingCommands` port does not supply the game controller's recovery policy. Neither API restores a RAM session after backend loss or turns gameplay commands into permanent actions.

## Flutter and Flame

FuelGameModel owns FuelClient/FuelGameController, adapts update streams into ChangeNotifier, observes Flutter lifecycle and disarms FuelInputGate. Disposal closes its owned account/session/transports. Use its fuel/game fields directly from settings and menus. The smaller FuelLifecycle remains available for standalone FuelSession integrations.

FuelInputGate rearms a held discrete action only after neutral. The application still maps platform keys/axes into game actions and owns HUD/modal focus.

`FuelAudioPolicy` is optional local playback policy over an existing backend; it has no Flame dependency:

```dart
final audio = FuelAudioPolicy(
  music: 'music/menu.mp3',
  startMusic: backend.playMusic,
  stopMusic: backend.stopMusic,
  disposeBackend: backend.dispose,
  effectsActive: backend.setEffectsActive,
);
await audio.setMusicEnabled(savedMusicChoice); // does not invent a gesture
await audio.onUserInteraction(); // call from the actual input gesture
await audio.setAppActive(isForegroundAndVisible);
await audio.playEffect(backend.playConfirmedMove);
await audio.dispose();
```

Music starts/stops serially and follows the latest track, foreground and setting, including changes during an awaited backend call. `setMusic(null)` selects silence. An idle driver enters the playback callback in the gesture stack. A failed play is cleaned up best effort and retries on a later request; it never spins in an automatic retry loop. Effects require foreground and their independent setting. The optional `effectsActive` callback lets the backend cancel already-started or loading cues when disabled/backgrounded/disposed. The backend retains ownership of bounded pools, asset loading and late-resource cleanup; music and effects must not depend on each other's preload. Choose cues from confirmed presentation outcomes rather than replaying restored snapshots. Local visibility does not pause server authority.

FuelSnapshotComponent coalesces full snapshots until the next frame. FuelEventComponent presents ordered events at a readable interval (default100ms) with a bounded queue; supply owner:fuel to clear queued events across account changes. Overflow/source error pauses presentation and calls onResync; install current state/summary then call reset. These components never run game rules, award time/scores, choose a camera or pause server deadlines.

## Service facades and low-level integration

FuelClient exposes account/actions/history, device transfer/bindings/revocation/deletion, room admission/matching/commands, chat history/posting/mutes/reports, leaderboards/ratings and confirmed analytics opt-out. IDs in request bodies confer no authority. Analytics choices publish only after fresh server confirmation; stale account reads cannot overwrite a newer confirmation.

`leaderboardPage(board, limit:100)` returns `{entries,player_rank,player_best}`. Entries expose public `name`, decimal-string `rank`/`score` and `is_player`; own standing may be outside the page and is null before the first score. The server may supply a trusted common-board projection without sharing account authority. The older `leaderboard` array facade remains available.

`analyticsEvent('screen_viewed', {'screen':'home'}, session: game.sessionId ?? '')` submits optional UI telemetry through the authenticated backend with the current confirmed consent revision. The backend must explicitly allow the event and validate its properties; server outcome events cannot use this path. Disabled or changing consent suppresses submission. UI submission is best effort, has no automatic retry or gameplay journal, and must not block play. Fuel0.3.14 uses bounded RAM-only, single-attempt background delivery: queued events may be lost, a delayed first request after opt-out is not accepted, and already accepted tail may finish. Older backend pins had a durable outbox; changing this SDK alone does not migrate their sender or clean old rows. Read the pinned backend's delivery/adoption contract. Use durable server effects for authoritative results, with optional telemetry offered after commit, and keep free text, player names and credentials out of telemetry.

FuelHttpTransport and FuelConnection remain bounded low-level IO engines for controlled incremental integrations. They do not implement identity, durable intents or game rules. Importing them alone is transport adoption, not a complete framework migration. Canonical new clients should compose the owners above.

HTTP defaults: 64KiB request, 1MiB response, 64 pending requests, one20-second headers/body deadline. Cancellation/timeout/close reject late completion; cleanup is bounded to3seconds. Socket defaults:20-second readiness,1MiB message,32 early messages,3-second cleanup. FuelRealtime additionally requires snapshots for its12-second liveness deadline; ordinary feedback cannot hide a stale world. Low-level budgets remain configurable positive values.
