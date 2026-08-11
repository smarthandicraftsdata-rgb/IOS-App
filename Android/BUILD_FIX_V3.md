# Build fix V3

Fixed the reported Kotlin compile errors:

- Removed the duplicate-source risk from the obsolete `ModernLampUi.kt` file.
- Changed `ModernLampApp` from `internal` to `private`, because it accepts the private `UnifiedLampItem` UI model and is called only inside `CloudHomeActivity.kt`.
- Kept BLE, local Wi-Fi, cloud, provisioning, device identity, command routing, and persistence source files unchanged.
