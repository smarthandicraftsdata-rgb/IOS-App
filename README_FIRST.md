# SH Lamp iOS 1.7.4 — R21A RF5 Production Candidate

Build: **1.7.4 (16)**  
RF5 focus: **ordered BLE / Local Wi-Fi / Cloud control with latest-user-intent semantics**.

This source is the RF5 continuation of the R21A RF4 Handover Ordering release. RF5 does not race multiple transports to mutate the lamp. Instead, every mutating user intent receives a persistent controller identity/session/sequence and the **same ordered intent** is reused if routing falls back from one transport to another.

## RF5 behavior

- Power and brightness are one ordered **output domain**.
- An output intent carries the complete desired output state: power, visible brightness, and remembered next-ON brightness.
- Fade and timer have their own ordered domains but use the same controller-wide monotonically increasing intent sequence.
- Local Wi-Fi, BLE and Cloud reuse the same command identity during fallback.
- Old asynchronous iOS work is blocked by the latest-user-intent generation.
- Rapid slider frames are ordered and are cancelled by later final/discrete output intent.
- Cloud ACK means the ESP accepted/executed the command, not merely that Render attempted a send.
- Local WebSocket command ACK and exact-ID HTTP fallback are supported.
- BLE ordered ACKs are serialized so an ACK cannot be consumed by the wrong waiter.
- Focused-lamp BLE ownership prevents multiple lamp views from competing for one central connection.
- Many-lamp local polling is bounded/round-robin rather than polling every saved lamp each cycle.
- Phone Wi-Fi/cellular path changes explicitly rebind the account Cloud WebSocket.

## Persistent command sequence

The app stores a stable controller ID and persistent session/high-water sequence in UserDefaults. Sequence numbers are leased in blocks of **4096** so a crash/relaunch cannot normally reuse a previously transmitted sequence. A relaunch may therefore jump forward (for example 1 → 4097); that is intentional.

## Build

The Xcode project is in:

`iosApp/SHLAMP.xcodeproj`

Codemagic configuration is at `codemagic.yaml`.

Static validation in this release passed Swift 5 parsing for all 19 Swift files and an extracted RF5 sequence-core type/execution test. A real Xcode/Codemagic Release build cannot be performed in the Linux validation environment and remains a release-gate test on your build system.

## Deployment compatibility

Deploy the matching RF5 Render backend first, then RF5 ESP firmware to one test lamp, then install this iOS build. RF5 ordering depends on all three layers understanding the ordered command/ACK contract. Do not mix this iOS app with RF4 firmware for production handover testing.

See `RF5_RELEASE_NOTES.md` for the detailed changes and the outer bundle's `READ_ME_FIRST.md` for the exact hardware test sequence.
