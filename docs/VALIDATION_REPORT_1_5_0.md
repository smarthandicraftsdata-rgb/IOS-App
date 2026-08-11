# SH Lamp 1.5.0 validation report

Validation date: 2026-08-06

## Passed in this environment

- Swift parser validation passed for all 19 Swift source files.
- `Models.swift` passed standalone Swift type-checking.
- An old-format stored `LampRecord` was decoded, migrated to the new default route/mode fields, encoded and decoded again successfully.
- Xcode project references, asset catalogs, Info.plist permissions and Codemagic workflow passed `scripts/verify_project.py`.
- BLE command, local HTTP endpoint, route/identity, setup-flow and UI invariants passed `scripts/audit_release.py`.
- The complete 1.5.0 feature marker and regression scan passed `scripts/verify_1_5_0_features.py`.
- Kotlin compiler parsing produced no Kotlin syntax (`expecting ...`) errors. Dependency-resolution errors are expected when compiling Android/Compose source without the Android SDK classpath.

## Build boundary

A complete Android Gradle build could not run in this offline container because the project wrapper needs to download Gradle 9.4.1 and no cached distribution is installed.

A complete iOS/Xcode build could not run because this container is Linux and does not include Xcode or the SwiftUI SDK.

Therefore the final required checks are:

1. Android Studio Gradle sync and Make Project.
2. Codemagic/Xcode unsigned iPhone build.
3. Physical R19B lamp tests from `TEST_CHECKLIST_1_5_0.md`.

## Cloud limitation

Both apps parse `powerMode` and `runtimeState` from cloud state when those fields are supplied. The uploaded archive did not include the Render backend source, so remote-only live mode/runtime display still depends on the backend forwarding these fields. Nearby BLE and local Wi-Fi mode/runtime support is included.
