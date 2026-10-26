# Changelog

## 0.3.1 — admission after settlement

The game controller waits in `saving` when a room admission is explicitly rejected with `pending_result`, then retries the same intent within the existing client timeout budget. Create, code/public join and matchmaking share this behavior; a match retains its ticket ID. Suspension, identity changes and disposal cancel the wait. Unknown outcomes and unrelated errors are never automatically resubmitted.

## 0.3.0 — shared account and session ownership preview

Canonical account/progress state, verified two-copy vault/journal, exact persistent actions and durable HTTP receipt/terminal recovery. Frozen identity selection and deletion proofs survive lost acknowledgements without replacement guests. Default browser storage uses Web Locks and expected-account fences; native sockets use secure headers. Shared game/controller lifecycle, readiness/reconnect/saving/loss states, Flutter notifier composition and identity-fenced Flame events replace consumer state machines. Development API changes require updating both peers; old switch/delete shapes and custom vault implementations must be updated.

## 0.2.0 — transport adoption preview

Shared bounded HTTP and JSON WebSocket engines for canonical clients and compatible wire adapters. HTTP preserves response metadata without retries; socket replacement fences late callbacks, bounds handshake/cleanup and supports qualified heartbeat deadlines. Canonical realtime also fences reentrant identity changes during snapshot delivery and closes channels rejected before readiness. Existing public wire shapes and credential formats are unchanged.

## 0.1.0 — development preview

Pure Dart client and service facades; optional Flutter lifecycle/input helpers and Flame snapshot/reliable-event presentation components. Public APIs are experimental.
