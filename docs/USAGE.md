# SDK use and recovery

## Identity

Browser apps use the same-origin Fuel HTTP adapter. Call `bootstrapBrowser`: prepare an HttpOnly cookie, then create/restore the permanent guest. The SDK cannot read that cookie. All browser mutations must have an allowed Origin; cross-origin CORS is not part of this preview.

Native apps implement `CredentialVault` using OS secure storage. `bootstrapNative` saves the generated 32-byte secret before the network write. Network/5xx errors keep that credential; retry never silently replaces the guest.

For transfer, A calls `issuePair`. B calls `prepareTransfer(vault: nativeVault)` (omit vault in browsers), then `requestPair(code)`. A reads `pendingPairs`, compares the same phrase with B and approves the exact ID. B calls `pairStatus`, then `activateTransfer` only after linked. `switchPrevious` returns to the retained prior guest. Progress is not merged. Preserve slots and candidate proof when a response is lost. Secrets are never printed or put in a URL.

## Commands

Construct one `FuelCommand(id, epoch, revision, action)` per semantic intent. Keep it until the outcome is known. Calling `command` again with that same object sends the same body; nested caller mutations cannot alter its stored action. Optional `PendingCommands` saves before the request and removes only after acceptance. Storage durability is the consumer's policy; pending gameplay commands cannot restore a lost RAM session.

Timeout/unavailable may mean committed. Retry the exact command; never generate a new ID or silently change the expected revision. Revision conflict needs a current snapshot and a new deliberate player intent. Session loss abandons old session actions; permanent account credentials remain.

## Sessions

`FuelSession#poll` permits one in-flight request. `select`, suspend and dispose invalidate late callbacks; HTTP requests use abort triggers. Identity changes also fence callbacks. Snapshots use BigInt revision/input counters. Older/repeated snapshots do not replay effects. A different epoch is session loss.

Call `poll` in your connection loop; handle errors with a bounded backoff. The session object intentionally does not start an unbounded background retry loop. On resume, call poll for the current snapshot before enabling input.

`FuelRealtime` accepts a caller-created `WebSocketChannel`, so browser cookies and native header transports remain platform choices. Wait for `connect` and an accepted snapshot before sending transient input. Do not replay inputs after disconnect. Supply onError and reconnect explicitly. Message queues and release/device-specific network policy remain the application's responsibility.

## Flutter and Flame

`FuelLifecycle` observes app lifecycle, suspends local polling and disarms held input. Resume changes local status and requires neutral input before retriggering actions. Dispose it when its UI owner leaves.

`FuelSnapshotComponent` coalesces full authoritative snapshots until the next update. Do not use it for dependent deltas or ordered animation events.

`FuelEventComponent<T>` presents at most one reliable event per interval (default 100 ms), with a bounded queue. Overflow or source error calls onResync and pauses presentation; install a current snapshot and call reset. It never divides one event's readable duration by the backlog size. Unmount cancels subscriptions and clears queued presentation.

Neither component executes game rules, awards a score, chooses a camera nor pauses the backend clock.

## Service facades

FuelClient exposes room create/list/code/public join, matching/cancellation, account transfer/bindings/revocation/deletion, chat history/posting, leaderboards, outcome ratings and analytics opt-out. Raw `request` is available for compatible additive endpoints. The server validates all authority and membership; client account IDs confer no rights.
