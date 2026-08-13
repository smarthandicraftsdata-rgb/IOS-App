# SH Lamp iOS 1.8.0 (22) — R21A RF5.4 Routing Hardening

Use this iOS project only with the matched RF5.4 backend and ESP32 firmware during hardware acceptance.

RF5.4 changes the command transport/routing layer, not the visual lamp-control semantics:

- Automatic ordered route priority is BLE > Local Wi-Fi > Cloud.
- The same RF5 logical command ID/controller/session/sequence can be hedged to a fallback route; the ESP ordering/idempotency layer prevents duplicate physical execution.
- Route health is based on semantic command success/failure, not merely socket-connected flags.
- Two consecutive semantic failures temporarily circuit-break a route while healthier routes remain immediately eligible.
- RF5 ordered LAN and Cloud waits are bounded; no RF4 Cloud→LAN command fence remains.
- Cloud same-ID WebSocket + REST hedge is retained with short semantic ACK budgets.
- BLE is not route-ready until identity/setup completion.
- RF5.2.x LAN/BLE recovery and Cloud JWT refresh recovery are retained.
- RF5.3 cloud slider throttling/final durable release behavior is retained.

Before release, use `scripts/verify_project.py` and `scripts/audit_release.py`. Physical acceptance still requires a real signed iOS build and iPhone testing.
