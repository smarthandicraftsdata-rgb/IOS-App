SH Lamp iOS 1.6.0 realtime stability candidate
===============================================

This folder is based on the full IOS-APP-1-main project supplied on 11 Aug 2026.

Android code is intentionally unchanged. iOS is advanced from 1.5.0 (10) to
1.6.0 (11) for the synchronization candidate.

Matching components:
- iOS 1.6.0 build 11 from this folder
- Render backend realtime stability revision
- ESP32 firmware TTP2-WIFI-BLE-R20E5-SYNC-20260811

Main fixes:
- direct cloud state/ACK consumption
- no 700 ms dashboard refresh after commands
- confirmed local-Wi-Fi route health instead of stale-host routing
- state freshness ordering across Wi-Fi/BLE/cloud
- realtime/coalesced brightness slider
- cloud fade + cloud timer
- deadline-based 1-second timer UI
- local timer completion notification
- battery rawJson parsing + 1% firmware telemetry

See docs/STABILITY_1_6_0.md for the detailed scope and deliberate exclusions.
