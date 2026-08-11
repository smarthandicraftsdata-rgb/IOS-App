# SH Lamp iOS 1.6.0 — realtime stability candidate

This build is a synchronization-focused candidate derived from the uploaded 1.5.0 project.

## Implemented in this candidate

- Direct handling of Render WebSocket `state` and `ack` events; no 700 ms dashboard refresh after cloud control.
- Cloud commands prefer the existing authenticated WebSocket and fall back to durable REST queueing if the socket send fails.
- Fade and auto-off timer are enabled over the cloud protocol (`setFadeMode`, `setTimer`).
- Local Wi-Fi is considered healthy only after a recent successful lamp response; a remembered host alone is not enough.
- Bonjour discovery no longer tears itself down and restarts on every connection-start call.
- A 2-second local status heartbeat keeps timer/battery/power state fresh while the phone is on the same Wi-Fi.
- Persisted local state no longer overrides newer cloud state merely because an old battery reading was valid.
- BLE state no longer pretends the active route is Wi-Fi solely because a historical local host exists.
- Timer UI is deadline-based and updates once per second without requiring lifecycle refreshes.
- A local iOS notification is scheduled from the same auto-off deadline and is replaced/cancelled when the timer changes or is cancelled.
- Brightness slider streams coalesced intermediate values. Local Wi-Fi uses a fast unverified request for drag updates, cloud uses ephemeral `liveCommand`, and the final release uses the normal verified/durable command.
- Cloud battery parser accepts both live `raw` and persisted Prisma `rawJson` telemetry.
- Cloud snapshots subtract snapshot age from `timerRemaining` so a stale stored countdown does not restart visually when the app opens.

## Deliberately not included yet

- APNs remote push delivery. Local timer notifications are included, but true cloud push while iOS is terminated requires Apple push credentials/capability and a backend token-delivery path.
- A local ESP WebSocket/SSE transport. Local status is currently kept fresh with a lightweight 2-second `/api/status` heartbeat.
- Any change to the validated R20E4 2.903 V FINAL cutoff, 2.700 V emergency path, warning blink sequence, or recharge-release qualification.

## Required matching components

Use this iOS build with the matching Render realtime patch and ESP32 R20E5 sync firmware candidate produced with it.
