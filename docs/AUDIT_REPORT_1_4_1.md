# SH Lamp iOS 1.4.1 — Final Audit Report

Audit date: 2026-08-06

## Release identity

- iOS marketing version: **1.4.1**
- iOS build: **8**
- Bundle identifier: `com.smarthandicrafts.shlamp`
- Deployment target: iOS 17.0
- Codemagic workflow: `ios-unsigned-sideloadly`

## Bugs fixed

1. **Version mismatch:** `Info.plist` was hard-coded to 1.3.1 (6) while Xcode was set to 1.4.0 (7). It now reads `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`; the project is 1.4.1 (8).
2. **Device-card tap conflict:** the power button was nested inside an outer `NavigationLink`. Navigation and power controls are now separate hit targets.
3. **Remote control disabled:** claimed cloud lamps could appear disabled when not locally reachable. Power and brightness may now be attempted for a cloud-linked lamp, matching the existing backend route selection.
4. **Unsupported remote fade/timer:** fade and timer controls are now disabled unless the active route is Bluetooth or local Wi-Fi, matching backend support.
5. **Preset inconsistency:** brightness presets and timer presets now follow the same availability rules as their sliders/sections.
6. **Battery validity:** Care and Diagnostics no longer display stale battery percentages unless `batteryValid` is true.
7. **Cloud-linked count:** Care now counts actual claimed cloud records rather than every ID beginning with `SH-`.
8. **Diagnostics empty state:** an account with no lamps now shows a neutral “No lamps to check” state rather than “Everything is ready.”
9. **Stale room filter:** Devices resets to “All” when the selected room no longer exists.
10. **Add-lamp validation:** lamp IDs follow the Android `SH-[A-Z0-9]{4,16}` rule; claim codes must be present; Wi-Fi SSID/password byte limits are checked before showing success.
11. **Account form:** trimmed validation, correct name capitalization, stale messages cleared when switching modes, and visibly disabled primary buttons.
12. **Loading icon overlap:** refresh/loading buttons no longer draw the icon beneath the spinner.
13. **Status truncation:** status pills scale/limit text safely on narrow iPhone layouts.
14. **Misleading account chevron:** removed because the account summary card has no destination.
15. **App version label:** Menu reads the installed bundle version instead of hard-coding it.
16. **Splash/session transition:** the splash has a minimum branded duration and waits briefly for a saved-session load, reducing login-screen flashes.
17. **Foreground reconnection:** when the signed-in app becomes active, it restarts the existing BLE/local/cloud connection discovery flow.
18. **Lamp settings guards:** room/release actions require a cloud-linked lamp; BLE-only network/controller actions require the correct connected BLE lamp.

## UI requirements verified in source

- Animated Smart Handicrafts® splash and branded account screen.
- Android-style Home, Devices, Care, Menu, Add Lamp, Diagnostics, Settings and lamp-control hierarchy.
- Restrained glass treatment rather than full-screen heavy glass.
- Fixed lamp hero while lower controls scroll.
- Large battery progress ring around lamp artwork.
- Animated lamp glow/light cone tied to power and brightness.
- Minus/plus brightness buttons in 5% steps, slider and presets synchronized.
- Rectangular battery panel removed from the lamp-control page.

## Backend integrity

The following working backend/protocol files are byte-for-byte unchanged from the installed 1.4.0 baseline:

- `AppEnvironment.swift`
- `AppViewModel.swift`
- `BLELampManager.swift`
- `CloudAPI.swift`
- `CloudRealtimeClient.swift`
- `JSONHelpers.swift`
- `KeychainStore.swift`
- `LampQRParser.swift`
- `LocalLampController.swift`
- `Models.swift`
- `QRScannerView.swift`

Their SHA-256 values are stored in `docs/BACKEND_BASELINE_SHA256.json`. The Android tree and `codemagic.yaml` are also unchanged.

## Protocol checks

- BLE service/control/Wi-Fi/identity UUIDs match Android.
- Control opcodes match Android: power `0x05`, brightness `0x02`, fade `0x03`, timer `0x04`, status `0x06`, identify `0x07`.
- Wi-Fi provisioning/status/controller opcodes match Android, including chunked provisioning `0x30/0x31/0x32`.
- Local HTTP paths for status, power, brightness, fade, timer, identify, name and controllers remain unchanged.
- Cloud command action/payload mapping remains unchanged.

## Validation completed

- All 19 Swift source files passed Swift parser validation.
- Xcode project file references, scheme, assets, permissions and Codemagic YAML passed project verification.
- Asset catalogs parse as valid JSON; app icon and logo files are present.
- Version settings are internally consistent.
- Backend SHA-256 integrity passed.
- Android source-tree integrity passed.
- Secret-pattern scan passed.
- Release ZIP integrity is checked after packaging.

## Remaining authoritative tests

This Linux environment cannot run Apple’s Xcode/SwiftUI type checker, iOS Simulator, CoreBluetooth hardware, local-network discovery, or a physical lamp. Therefore the final authority is:

1. Codemagic `xcodebuild` compile.
2. Installation on the iPhone 15 Pro.
3. Physical tests over BLE, local Wi-Fi and remote cloud with the lamp.

No claim is made that those hardware/runtime tests were performed here.
