# Changelog

## 0.2.0 — transport adoption preview

Shared bounded HTTP and JSON WebSocket engines for canonical clients and compatible wire adapters. HTTP preserves response metadata without retries; socket replacement fences late callbacks, bounds handshake/cleanup and supports qualified heartbeat deadlines. Canonical realtime also fences reentrant identity changes during snapshot delivery and closes channels rejected before readiness. Existing public wire shapes and credential formats are unchanged.

## 0.1.0 — development preview

Pure Dart client and service facades; optional Flutter lifecycle/input helpers and Flame snapshot/reliable-event presentation components. Public APIs are experimental.
