#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
checks: list[tuple[str, Path, str]] = [
    ("Android canonical device model", ROOT / "android/app/src/main/java/com/example/shlamp/LampDevice.kt", "LampRoutePreference"),
    ("Android duplicate migration", ROOT / "android/app/src/main/java/com/example/shlamp/LampRepository.kt", "migrateLinkedLampRecords"),
    ("Android known BLE identity probing", ROOT / "android/app/src/main/java/com/example/shlamp/LampConnectionManager.kt", "beginNextIdentityProbe"),
    ("Android transient Add Lamp", ROOT / "android/app/src/main/java/com/example/shlamp/LampConnectionManager.kt", "transientLampIds"),
    ("Android explicit setup commit", ROOT / "android/app/src/main/java/com/example/shlamp/LampConnectionManager.kt", "commitSelectedLamp"),
    ("Android network invalidation", ROOT / "android/app/src/main/java/com/example/shlamp/CloudHomeActivity.kt", "registerDefaultNetworkCallback"),
    ("Android Bluetooth state reaction", ROOT / "android/app/src/main/java/com/example/shlamp/CloudHomeActivity.kt", "BluetoothAdapter.ACTION_STATE_CHANGED"),
    ("Android compact control banner", ROOT / "android/app/src/main/java/com/example/shlamp/CloudHomeActivity.kt", "ModernAdaptiveLampHeader"),
    ("Android power modes", ROOT / "android/app/src/main/java/com/example/shlamp/CloudHomeActivity.kt", "LampPowerMode.TOUCH_ONLY"),
    ("Android remote later", ROOT / "android/app/src/main/java/com/example/shlamp/LampSettingsActivity.kt", "Add remote access"),
    ("iOS canonical route preference", ROOT / "iosApp/SHLAMP/Models.swift", "enum LampRoutePreference"),
    ("iOS session-scoped cloud ownership", ROOT / "iosApp/SHLAMP/AppViewModel.swift", "Account ownership is session-scoped"),
    ("iOS known BLE identity probing", ROOT / "iosApp/SHLAMP/AppViewModel.swift", "shouldIdentityProbe"),
    ("iOS automatic route order", ROOT / "iosApp/SHLAMP/AppViewModel.swift", "order = [.wifi, .bluetooth, .cloud]"),
    ("iOS live phone network monitor", ROOT / "iosApp/SHLAMP/AppViewModel.swift", "NWPathMonitor"),
    ("iOS BLE setup dedupe", ROOT / "iosApp/SHLAMP/BLELampManager.swift", "connectionSetupCompleted"),
    ("iOS transient Add Lamp", ROOT / "iosApp/SHLAMP/AppViewModel.swift", "transientLocalIDs"),
    ("iOS explicit Bluetooth add", ROOT / "iosApp/SHLAMP/UI/AddLampView.swift", "Add Bluetooth Lamp"),
    ("iOS optional remote access", ROOT / "iosApp/SHLAMP/UI/AddLampView.swift", "Enable Remote Access"),
    ("iOS compact sticky header", ROOT / "iosApp/SHLAMP/UI/LampControlView.swift", "compactHeader(lamp)"),
    ("iOS battery indicator", ROOT / "iosApp/SHLAMP/UI/LampControlView.swift", "IPhoneBatteryIndicator"),
    ("iOS power modes", ROOT / "iosApp/SHLAMP/UI/LampControlView.swift", "ForEach(LampPowerMode.allCases)"),
]

errors: list[str] = []
for label, path, marker in checks:
    if not path.exists() or marker not in path.read_text():
        errors.append(f"{label}: missing {marker} in {path.relative_to(ROOT)}")

android_build = (ROOT / "android/app/build.gradle.kts").read_text()
if 'versionCode = 7' not in android_build or 'versionName = "1.5.0"' not in android_build:
    errors.append("Android version is not 1.5.0 (7)")

pbx = (ROOT / "iosApp/SHLAMP.xcodeproj/project.pbxproj").read_text()
if pbx.count("MARKETING_VERSION = 1.5.0") != 2 or pbx.count("CURRENT_PROJECT_VERSION = 10") != 2:
    errors.append("iOS version is not 1.5.0 (10) in Debug and Release")

# Guard the exact setup regression: tapping a nearby lamp may call addLamp, but
# addLamp itself must be transient and the permanent write must be explicit.
manager = (ROOT / "android/app/src/main/java/com/example/shlamp/LampConnectionManager.kt").read_text()
add_match = re.search(r"fun addLamp\(nearby: NearbyLamp\)(.*?)\n    fun commitSelectedLamp", manager, re.S)
if not add_match or "persist = false" not in add_match.group(1):
    errors.append("Android nearby selection is not guaranteed transient")

ios_model = (ROOT / "iosApp/SHLAMP/Models.swift").read_text()
if "decodeIfPresent(LampPowerMode.self" not in ios_model or "decodeIfPresent(LampRoutePreference.self" not in ios_model:
    errors.append("iOS stored-record migration defaults are missing")

if errors:
    print("SH LAMP 1.5.0 FEATURE VERIFICATION FAILED")
    for error in errors:
        print(f"- {error}")
    sys.exit(1)

print("SH LAMP 1.5.0 FEATURE VERIFICATION PASSED")
for label, _, _ in checks:
    print(f"- {label}: present")
