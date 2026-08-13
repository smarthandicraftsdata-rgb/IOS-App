# SH Lamp iOS 1.8.1 (23) — RF5.4.1 Hardware Acceptance Candidate

Use this project with the matching RF5.4.1 Render backend and ESP32 firmware.

RF5.4.1 retains RF5 ordered controller/session/sequence semantics and RF5.4 same-ID route hedging, then adds the local-route lifecycle/identity hardening required by the RF5.3 field logs:

- Automatic command priority remains BLE > Local Wi-Fi > Cloud.
- Same logical command can be hedged across routes without duplicate physical execution.
- BLE ordered protocol and ACK path are unchanged from RF5.4.
- Local WebSocket ownership is limited to one starting/healthy generation per expected physical lamp before identity arrives.
- A local host is command-healthy only when the state received from that host identifies the expected lamp.
- Ordered HTTP fallback performs a bounded identity status probe before mutation, preventing stale DHCP/IP reuse from controlling a different lamp.
- Wi-Fi loss uses make-before-break route selection, so a healthy BLE/Cloud route does not unnecessarily pass through Offline.
- LAN and Cloud control waits remain short and independent; no fixed Cloud→LAN time fence is used.

Version: 1.8.1
Build: 23
Codemagic workflow: ios-unsigned-sideloadly

Validation performed in this environment:
- Swift parser: 19/19 files
- project integrity verifier: PASS
- release auditor: PASS
- deterministic routing/state/backend playgrounds: PASS

Not performed here: Apple SDK/Xcode signed build or physical iPhone installation. Those remain hardware-acceptance gates.
