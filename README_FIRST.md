# SH Lamp Android + iOS — Integrated 1.5.0

This package contains the complete Smart Handicrafts® SH Lamp source for both platforms:

- `android/` — Android app version 1.5.0 (`versionCode 7`).
- `iosApp/` — native SwiftUI iPhone app version 1.5.0 (build 10).
- `codemagic.yaml` — unsigned IPA workflow for Windows/Sideloadly.
- `docs/` — protocol notes, release changes and physical-lamp test checklist.

## What changed in 1.5.0

### One physical lamp, one device card

BLE, local Wi-Fi and cloud are now connection routes attached to one physical lamp record. The app reads the firmware identity characteristic (`FFE3`) to link the local ID, cloud ID and BLE peripheral before creating or updating a device. Existing linked duplicates are migrated and merged while retaining local details and cloud ownership.

### Live route switching

Automatic routing is:

`Local Wi-Fi → Bluetooth → Remote → Offline`

Phone Wi-Fi and Bluetooth changes are monitored while the app is open. A stale local route is invalidated immediately, known lamps are rediscovered over BLE, and commands retry through the next valid route. The control page also provides Automatic, Local Wi-Fi, Bluetooth and Remote preferences.

### Corrected Add Lamp workflow

Selecting a nearby lamp only connects and verifies it. It is not saved until the user explicitly chooses and completes one of these paths:

- Add Bluetooth Lamp
- Add Wi-Fi Lamp
- Enable Remote Access

Wi-Fi provisioning no longer requires a cloud claim code. Remote claiming is a separate optional step and can be completed immediately or later from Lamp Settings.

### New control experience

- Expanded control header at the top of the page
- Compact sticky banner while scrolling
- Automatic expansion when scrolling back up
- iPhone-style battery indicator
- Current route, power mode and runtime state
- Balanced, Maximum Backup, BLE Only and Touch Only controls
- Maximum Backup UI synchronized to the firmware's 70% ceiling
- Confirmation warnings before BLE Only and Touch Only

### Reliability changes

- Initial BLE status request is sent once and debounced
- Bluetooth identity setup is completed only once per connection
- Connections live at the app/manager level rather than inside a single screen
- Locally reported cloud identity is kept separate from verified account ownership
- Stored iOS records decode safely when new fields are added

## Firmware baseline

This app update targets:

`TTP2-WIFI-BLE-R19B-P3-20260806`

It uses:

- BLE service `FFE0`
- control/status characteristic `FFE1`
- Wi-Fi/status characteristic `FFE2`
- identity characteristic `FFE3`
- local power-mode endpoint `/api/power-mode`

## Build without a Mac

1. Upload this folder to the root of a private GitHub repository.
2. Run **SH Lamp iOS - unsigned IPA for Sideloadly** in Codemagic.
3. Download `SHLAMP-unsigned.ipa` from Artifacts.
4. Install it through Sideloadly or AltServer.

For Android, open `android/` in Android Studio and build the debug or release app normally.

## Validation completed in this environment

- Swift parser validation for all 19 Swift files
- Standalone Swift type-check of the backward-compatible data models
- Project structure, Xcode references, assets, permissions and Codemagic workflow checks
- Android source structural scan
- Cross-platform feature and protocol audit

A full Xcode build is not possible in this Linux environment. A full Android Gradle build also requires the Android/Gradle dependencies to be available. Run the physical-lamp checklist in `docs/TEST_CHECKLIST_1_5_0.md` after building.
