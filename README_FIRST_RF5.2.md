# READ FIRST — SH Lamp iOS RF5.2

Version: **1.7.6 (18)**

Purpose: fix the app showing **Offline** / refusing controls after BLE → cellular/cloud → Wi-Fi transitions even though the ESP is still connected to Wi-Fi/cloud.

This is an **iOS-only route-health/lifecycle patch**. It is compatible with the RF5 firmware already flashed and with RF5.1 firmware. The RF5.1 firmware is still recommended because it separately fixes the saved-brightness 4% → 20% regression.

Test sequence:

1. BLE connected: ON/OFF.
2. Turn Bluetooth off while phone Wi-Fi remains on: app should promote to Local Wi-Fi as soon as protocol-v3 realtime state arrives.
3. Turn phone Wi-Fi off, leave cellular on: app should remain Remote/Cloud using live WebSocket or the REST semantic-ACK fallback.
4. Turn phone Wi-Fi back on: Local Wi-Fi should recover without showing Offline for a long period and without clearing the remembered host.
5. Repeat several times and include a long idle period.
