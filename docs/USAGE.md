# SDK use and recovery

## Identity

Browser apps use the same-origin Fuel HTTP adapter. Call `bootstrapBrowser`: prepare an HttpOnly cookie, then create/restore the permanent guest. The SDK cannot read that cookie. All browser mutations must have an allowed Origin; cross-origin CORS is not part of this preview.

Native apps implement `CredentialVault` using OS secure storage. `bootstrapNative` saves the generated 32-byte secret before the network write. Network/5xx errors keep that credential; retry never silently replaces the guest.

Use `RecordCredentialVault(read: ..., write: ...)` with one OS-protected value and atomic whole-value writes. It serializes slot changes and stores active/previous in one record, so activation or switching cannot overwrite the sole durable copy of a binding halfway through a swap. Use one vault instance per stored value. Custom vaults must implement the same atomic `activate` contract; separate independent writes are insufficient. Corrupt storage fails explicitly and must never trigger replacement bootstrap.

For transfer, A calls `issuePair`. B calls `prepareTransfer(vault: nativeVault)` (omit vault in browsers), then `requestPair(code)`. A reads `pendingPairs`, compares the same phrase with B and approves the exact ID. B calls `pairStatus`, then `activateTransfer` only after linked. `switchPrevious` returns to the retained prior guest. Progress is not merged. Preserve slots and candidate proof when a response is lost. Secrets are never printed or put in a URL.

Repeating activation is idempotent and preserves the prior guest. Preparation renews consumed or expired candidates while retaining pending operations. `newAttempt: true` explicitly abandons the pending candidate for a new deliberate attempt; do not use it automatically after timeout/5xx.

Browser activation and switching clear old projections and close old sockets before sending the request, and invalidate again when it finishes, including failure. A lost response may already have changed the HttpOnly cookie. Concurrent requests and new realtime connections fail with `identity_changing`; fetch a fresh snapshot after the operation. Identity changes preserve a suspended session until the application explicitly resumes it.

## Commands

Construct one `FuelCommand(id, epoch, revision, action)` per semantic intent. Keep it until the outcome is known. Calling `command` again with that same object sends the same body; nested caller mutations cannot alter its stored action. Optional `PendingCommands` saves before the request and removes only after acceptance. Storage durability is the consumer's policy; pending gameplay commands cannot restore a lost RAM session.

Timeout/unavailable may mean committed. Retry the exact command; never generate a new ID or silently change the expected revision. Revision conflict needs a current snapshot and a new deliberate player intent. Session loss abandons old session actions; permanent account credentials remain.

## Sessions

`FuelSession#poll` permits one in-flight request. `select`, suspend and dispose invalidate late callbacks; HTTP requests use abort triggers. Identity changes also fence callbacks. Snapshots use BigInt revision/input counters. Older/repeated snapshots do not replay effects. A different epoch is session loss.

Call `poll` in your connection loop; handle errors with a bounded backoff. The session object intentionally does not start an unbounded background retry loop. On resume, call poll for the current snapshot before enabling input.

`FuelRealtime` accepts a caller-created `WebSocketChannel`, so browser cookies and native header transports remain platform choices. Wait for `connect` and an accepted snapshot before sending transient input. Do not replay inputs after disconnect. Supply onError and reconnect explicitly. Its shared connection engine bounds readiness, JSON message size and cleanup; reconnect policy remains the application's responsibility.

Identity changes immediately clear the previous viewer projection and cursor. Realtime uses the same identity/session generation fences as polling; suspend, reselect, loss or identity change closes the old channel. Normal completion/errors clear readiness and notify onError; only a fresh channel and accepted snapshot allow further input. An unchanged valid snapshot confirms resume without replaying presentation events.

## Flutter and Flame

`FuelLifecycle` observes app lifecycle, suspends local polling and disarms held input. Resume changes local status and requires neutral input before retriggering actions. Dispose it when its UI owner leaves.

`FuelSnapshotComponent` coalesces full authoritative snapshots until the next update. Do not use it for dependent deltas or ordered animation events.

`FuelEventComponent<T>` presents at most one reliable event per interval (default 100 ms), with a bounded queue. Overflow or source error calls onResync and pauses presentation; install a current snapshot and call reset. It never divides one event's readable duration by the backlog size. Unmount cancels subscriptions and clears queued presentation.

Neither component executes game rules, awards a score, chooses a camera nor pauses the backend clock.

## Incremental transport adoption

Existing wire protocols can use the same IO engines as `FuelClient` and `FuelRealtime` while retaining their account schema and message adapters. This adopts transport only; it does not migrate authentication, rules, storage or durable session promises. Pin both server and client contracts and test old/new peer compatibility before cutover.

`FuelHttpTransport(client: ...)` owns its supplied `http.Client` until `close()`. `get`, `post` and `request` preserve status, headers and response bytes. Defaults: 64 KiB UTF-8 request, 1 MiB response, 64 pending requests and one 20-second deadline covering headers **and** body. Limits and deadlines are configurable positive values. A cancellation future, timeout or close aborts IO and rejects the response, including late completion. Cleanup is bounded to three seconds. Oversize and saturation fail with `too_large`/`busy`. No status interpretation, retry, guest creation or semantic ID generation occurs. Aborting a mutation does not prove the server rolled it back; retain its exact operation for recovery.

`FuelConnection` owns one replaceable `WebSocketChannel`. `connect(channel, onMessage: ..., onError: ..., hello: ...)` returns whether that attempt became ready. It subscribes before readiness, sends the optional hello first, then delivers buffered JSON objects. Defaults: 20-second ready deadline, 1 MiB per message, at most 32 early messages and three-second cleanup. `send` is allowed only while connected. `disconnect()` fences callbacks immediately and permits a fresh connection without waiting for a hung old close; `close()` permanently disposes it. Malformed/oversized input, stream failures and consumer callback failures terminate the current attempt once. Never replay transient inputs automatically.

Optional `heartbeatTimeout` starts at readiness; `isHeartbeat` chooses which accepted messages renew it. For periodic authoritative snapshots, select only snapshots: ordinary feedback must not hide a stale world. The application still owns identity/lifetime/request generations, clears old private projections before a browser identity transition, and rechecks ownership after awaited or reentrant callbacks. Socket reconnect must not dispose HTTP or cancel unrelated requests of the same identity. Private wire adapters must not bypass these fences or reinterpret unknown mutation outcomes as failure.

## Service facades

FuelClient exposes room create/list/code/public join, matching/cancellation, account transfer/bindings/revocation/deletion, chat history/posting, leaderboards, outcome ratings and analytics opt-out. Raw `request` is available for compatible additive endpoints. The server validates all authority and membership; client account IDs confer no rights.
