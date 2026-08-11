# SH Lamp iOS 1.6.0 — Codemagic Build Fix 1

This archive fixes the three Swift compiler failures reported by Codemagic/Xcode 26.4 on 2026-08-11.

## Fixes
1. AppViewModel.swift
   - Replaced `local.map(isWiFiHealthy)` with an explicit closure because `isWiFiHealthy(_:now:)` has a defaulted second parameter and cannot be passed directly where `(LampRecord) -> Bool` is required.

2. LampControlView.swift — `controlMetrics(_:)`
   - Added explicit `return` before `HStack` because the function declares a local variable before the view expression.

3. LampControlView.swift — `fadeAndTimerCard(_:)`
   - Added explicit `return` before `VStack` for the same Swift opaque-return rule.

No realtime protocol, timer, battery, notification, BLE, Wi-Fi, or cloud behavior was changed in this build-fix archive.
