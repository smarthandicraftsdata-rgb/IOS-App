# UI-only correction verification

This corrected project starts from the uploaded `SHLAMPlatest.rar`. The lamp connection, command, provisioning, cloud, BLE, Wi-Fi, identity, discovery, repository, and lifecycle logic was preserved.

## Verification

- `CloudHomeActivity` activity/lifecycle/connection-command section: **byte-identical** to the uploaded original.
- `AndroidManifest.xml`: **byte-identical**.
- `app/build.gradle.kts`: **byte-identical**; no version or dependency change.
- All connection-related Kotlin files listed below are **byte-identical**.

| File | SHA-256 | Identical |
|---|---|---|
| `AddLampActivity.kt` | `00bae8ce928387dee37fd1371ba93cc0f05a5d66261e8f4021a6d5b2965efe94` | Yes |
| `BleLampManager.kt` | `da815d0bd25ce4fe99c4f96366a9a00f29159d2b811ce5e2894e85a93d9687aa` | Yes |
| `CloudAccountActivity.kt` | `7b6f554b1e61595ab4a973d432898c4380b454c3cf8f006a5ce2ee34a25f3e1f` | Yes |
| `CloudCore.kt` | `e1b322187e3a81c3f97895b5109a2f80dcef661a838c4939ad79788965a914da` | Yes |
| `ConnectionDiagnosticsActivity.kt` | `6d8dd73527af9b1e0a0ce53e4a80284c60c6b5aba51e2ab368a41dedcdd13c97` | Yes |
| `LampAccessManager.kt` | `b46cdb4b23f3d11b2ad02f1df5ccd8d1e5bc0b71f0292f17bcd6d5e76b44d5ce` | Yes |
| `LampConnectionManager.kt` | `cc422de9a57cc5439ca5f0ddbbf507dd7c497e5fb03fa2d27bb3ba1fa889a711` | Yes |
| `LampDevice.kt` | `0eeaf7d0e7c14f8dfdb7df843d1467f55e62eb79b506e4d4079e814f1ded8e09` | Yes |
| `LampDiscoveryManager.kt` | `503c7bba5361edfe660f7e98815d65c29cb9c463781b7dc36ae77865601f7b2d` | Yes |
| `LampQrParser.kt` | `3f7845c84ee8a8fbc0e369554fee7a183cc30367ea73cf60297840d5e28c9f2b` | Yes |
| `LampRepository.kt` | `0169ad9d79ff61e8571df170fd5019f670cf0c30e50e1d70f54b71ffe7dc02f3` | Yes |
| `LampSettingsActivity.kt` | `0f810e8a5339f240720d9ee8bffc80b60121988a09d2d96f40bdaea30cfe7228` | Yes |
| `LampSetupStore.kt` | `58e3c303282d5886076b71e759464a65d34b6accda8ebd6b72de03aa5eb4ffd1` | Yes |
| `LampTransferCodeStore.kt` | `2cce12173b09bdb2465defa1c9b49721e8c689c1e8965b76a49a6b48a1c297a6` | Yes |
| `MainActivity.kt` | `d49cc1735abdd42d817f9f903ea41838b1eeab2a1de5fafbeae78f8d8445ee3b` | Yes |
| `WifiLampController.kt` | `b302be3320b2a38d6f3a35aa172c042407102bf85c69ddef21f8a14b366b9e2d` | Yes |

## CloudHomeActivity logic hash

- Original: `b7a4490829384f184808ab14329b295a2b578cc5c4a3f69b1d57a69b13dbfc15`
- Corrected: `b7a4490829384f184808ab14329b295a2b578cc5c4a3f69b1d57a69b13dbfc15`
- Identical: **True**

## Files intentionally changed

- Compose presentation inside `UnifiedHomeScreen` and the appended UI-only composables
- Theme colours and Material theme
- Launcher artwork and visual string/theme resources

No BLE UUID, Wi-Fi endpoint, cloud endpoint, device-ID mapping, command routing, provisioning flow, permissions, manifest component, or persistence code was changed.

## Build check

A Kotlin parser check found no syntax/redeclaration errors. A full Android Gradle build could not run in this environment because the Gradle distribution and Android SDK are not available offline.