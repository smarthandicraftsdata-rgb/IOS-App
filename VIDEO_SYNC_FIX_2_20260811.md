# SH Lamp iOS 1.6.0 - Video Sync Fix 2

Based on the 2026-08-11 17:09 screen recording.

Confirmed fixes in this candidate:

1. Brightness slider owns its draft value while the finger is down. Delayed BLE/Wi-Fi/cloud echoes cannot move the thumb during a drag.
2. Short-lived per-field control holds protect power, brightness and fade from an older transport echo immediately after a user command. A matching device state clears the hold; otherwise it expires automatically.
3. Timer commands use a short-lived pending deadline. An older cloud/BLE/Wi-Fi timer snapshot cannot overwrite a newly selected 15/30/60 minute timer before its acknowledgement arrives.
4. Timer remaining is calculated with a fresh Date() while liveClock is used only to trigger SwiftUI refreshes. This removes the one-frame 15:01 problem caused by a clock tick being up to one second old.
5. Timer preset classification has a five-second transport tolerance so a boundary frame cannot highlight the next preset.
6. State freshness is decoupled from route health. If Local Wi-Fi temporarily falls back to Remote, a newer known local state is not discarded only because the Wi-Fi route became unhealthy.

Not changed:
- ESP32 firmware
- Render backend
- battery protection thresholds or battery estimator
- BLE/Wi-Fi protocol
- notification policy

Video observations that are already working:
- Cloud -> Bluetooth -> Local Wi-Fi route fallback
- power control on Cloud/BLE/Local Wi-Fi
- local timer second-by-second countdown
- fade selection
- lamp battery settling to 79% and remaining consistent across routes after the fresh BLE measurement

The recording does not run a timer to completion, so it cannot verify the SH Lamp timer-complete notification.
