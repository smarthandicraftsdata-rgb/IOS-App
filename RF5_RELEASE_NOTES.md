# RF5.4.1 iOS release notes

Version **1.8.1 (23)**.

RF5.4.1 is the iOS component of the SH Lamp Hardware Acceptance Candidate. It builds on RF5.4 routing hedging/circuit breakers and adds production local-route ownership and stale-DHCP identity protection.

Changed control behavior:
- automatic BLE > LAN > Cloud semantic-health priority;
- 180 ms same-ID cross-route hedge slots;
- BLE semantic ACK budget 800 ms;
- LAN WS ACK budget 750 ms, ordered HTTP request budget 1.0 s;
- Cloud WS ACK budget 750 ms with same-ID REST hedge after ~220 ms and a bounded REST status path;
- one starting/healthy Local WS generation per expected lamp identity;
- Local WS health is bound to the actual lamp ID reported by that host;
- local HTTP fallback probes `/api/status` identity before mutation;
- Wi-Fi disappearance no longer forces an artificial Offline state when BLE/Cloud is already usable.

BLE packet format, controller/session/sequence ordering, remembered-brightness behavior and UI lamp semantics are intentionally preserved.
