SH Lamp Android App - Battery Update R16
Version code: 3
Version name: 1.2

Implemented:
1. Reads the standard BLE Battery Service 0x180F / Battery Level 0x2A19.
2. Subscribes to battery notifications and performs an initial characteristic read.
3. Reads batteryValid, batteryPercent and batteryVoltageMv from local Wi-Fi /api/status.
4. Reads battery data from cloud state, including state.raw compatibility fields.
5. Stores and merges battery information with the existing local/cloud lamp identity.
6. Shows battery percentage on lamp cards, device detail, and the Care page.
7. Shows measured voltage when local Wi-Fi or cloud provides batteryVoltageMv.
8. Adds low-battery UI states at 20% and critical state at 10%.

Expected with the current firmware:
- BLE gives the final firmware-calculated percentage through 2A19.
- Local Wi-Fi and cloud can additionally provide batteryVoltageMv.
- The Android app does not recalculate SoC from voltage.

Open this folder in Android Studio and run the app module.
