# SH Lamp iOS 1.7.9 (21) — RF5.3 Cloud Slider Stability

This build is based directly on RF5.2.2 Token Recovery and therefore retains:
- RF5.2 Local Wi-Fi route recovery,
- RF5.2.1 LAN/BLE self-healing connection supervisor,
- RF5.2.2 JWT refresh before /ws/app reconnect,
- RF5 ordered cross-transport commands and semantic ACK handling.

## RF5.3 change

The physical test showed a reproducible trigger: while Remote/Cloud control was healthy, dragging brightness rapidly produced a burst of ordered `setOutputState` frames and was immediately followed by ESP device-WebSocket disconnects while router Wi-Fi remained associated.

RF5.3 reduces only intermediate Cloud slider traffic:
- BLE/LAN streaming remains 100 ms (10 Hz).
- Cloud streaming is coalesced to 250 ms (4 Hz).
- Slider release still sends one immediate durable ordered command and waits for the ESP semantic ACK.

Use together with the RF5.3 Render backend and RF5.3 ESP firmware. The backend/firmware add the `ephemeral: true` live-slider contract; running this app with older backend/firmware is safe but does not receive the full traffic reduction.
