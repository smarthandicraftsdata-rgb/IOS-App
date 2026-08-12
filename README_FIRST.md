# SH Lamp iOS 1.7.6 — R21A RF5.2 Route Recovery

Build: **1.7.6 (18)**  
Base: **RF5.1 remembered-brightness fix + RF5 universal ordered transport**

## Why RF5.2 exists

The extended physical test/video showed the app reporting **Offline** while the ESP was still connected to router Wi-Fi/cloud and, later, while the ESP logged a connected local realtime client. This exposed stale RF2-era route-health rules in the iOS app rather than a loss of ESP connectivity.

## RF5.2 corrections

- A validated RF5 protocol-v3 local WebSocket is now sufficient proof of Local Wi-Fi reachability.
- The app no longer requires a separate HTTP `/api/status` success before promoting LAN when the v3 realtime socket is healthy.
- Remote/Cloud remains usable through RF5's REST + semantic-ACK fallback while the iPhone account WebSocket is rebinding.
- Route badges are rebuilt immediately when the app cloud socket connects/disconnects.
- Backend device-online state is reconciled by REST after phone network-interface changes.
- App cloud WebSocket authentication has a 6-second timeout/reconnect guard.
- A 12-second Wi-Fi attachment grace prevents transient path-change misses from erasing the remembered local host.
- RF5.1 remembered-brightness alias/BLE correction is retained.
- RF5 ordered command/sequence logic is retained.

## Compatibility

This iOS build works with the **RF5 firmware already flashed**. The RF5.1 firmware remains recommended separately because it fixes the saved-brightness 4% → 20% issue. No Render backend change is required for RF5.2.

## Physical test order

1. BLE ON/OFF.
2. Turn Bluetooth off while phone Wi-Fi stays on. Expect Local Wi-Fi quickly, not Offline.
3. Turn phone Wi-Fi off with cellular on. Expect Cloud/Remote and working ON/OFF.
4. Turn phone Wi-Fi on again. Expect Local Wi-Fi to return without a long Offline period.
5. Repeat rapidly and after a long idle.
