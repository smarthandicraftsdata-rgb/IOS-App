# RF5.4 iOS change manifest

Primary changed control-path files:

- `iosApp/SHLAMP/AppViewModel.swift`: semantic route health/circuit breaker, same-ID cross-route hedging, removal of RF4 Cloud→LAN fence for ordered commands, structured command trace.
- `iosApp/SHLAMP/BLELampManager.swift`: full BLE setup/identity readiness gate and bounded ordered ACK health budget.
- `iosApp/SHLAMP/LocalLampController.swift`: dedicated short-timeout control URLSession, 750 ms WS semantic ACK, 1.0 s ordered HTTP budget.
- `iosApp/SHLAMP/CloudAPI.swift`: dedicated no-wait control URLSession and bounded command/status path.
- `iosApp/SHLAMP/CloudRealtimeClient.swift`: bounded semantic ACK/authentication timing while retaining JWT refresh/rebind recovery.
- `iosApp/SHLAMP/Models.swift`: route value made Sendable for the RF5.4 async routing harness/control flow.
- Xcode project: marketing version 1.8.0, build 22.

The complete project is included; no isolated snippet is required.
