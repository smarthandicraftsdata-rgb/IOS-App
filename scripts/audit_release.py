#!/usr/bin/env python3
from __future__ import annotations
import hashlib, json, plistlib, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "iosApp" / "SHLAMP"
ANDROID = ROOT / "android"
errors: list[str] = []

def require(path: Path, snippets: list[str]) -> None:
    text = path.read_text()
    for snippet in snippets:
        if snippet not in text:
            errors.append(f"Missing protocol/release invariant in {path.relative_to(ROOT)}: {snippet}")

# Preserve legacy BLE/local API compatibility while auditing the additive RF5 path.
require(IOS / "BLELampManager.swift", [
    "writeControl([0x05, on ? 0x01 : 0x00])",
    "writeControl([0x02, UInt8(clamp(percent, 0...100))]",
    "writeControl([0x03, UInt8(clamp(mode, 0...3))])",
    "writeControl([0x04, UInt8([0, 15, 30, 60].contains(minutes) ? minutes : 0)])",
    "writeControl([0x07])", "writeControl([0x06])", "writeControl([0x08, mode.binaryValue])",
    "requestInitialState()", "connectionSetupCompleted", "guard isReady, let characteristic = controlCharacteristic",
    "writeWiFi([0x21])", "writeWiFi([0x22])", "writeWiFi([0x25])", "writeWiFi([0x51])",
])
require(IOS / "LocalLampController.swift", [
    'path: "/api/status"', 'path: "/api/power?state=', 'path: "/api/brightness?value=',
    'path: "/api/fade?mode=', 'path: "/api/timer?minutes=', 'path: "/api/identify"',
    '"/api/power-mode?mode=', 'path: "/api/name?value=', 'path: "/api/controllers"',
    "Task.sleep(for: .milliseconds(750))", "request.timeoutInterval = 1.0", "realtimeExpectedLampByHost",
])
require(IOS / "AppViewModel.swift", [
    "base = [.bluetooth, .wifi, .cloud]", "routeHedgeDelayMs = 180",
    "withTaskGroup(of: OrderedRouteAttemptOutcome.self", "same-ID cloud hedge",
    "Task.sleep(for: .milliseconds(220))", "timeout: 0.75", "timeout: 1.6",
    "there is deliberately NO Cloud→LAN time fence", "consecutiveFailures >= 2",
    "physicalLocalIDNormalized", "cloudIDNormalized", "setOutputState",
])
require(IOS / "CloudAPI.swift", ["controlPath: Bool = false", "waitsForConnectivity = false"])
require(IOS / "CloudRealtimeClient.swift", ["timeout: TimeInterval = 0.75"])
require(IOS / "UI/LampControlView.swift", [
    "compactHeader(lamp)", "IPhoneBatteryIndicator(", "ForEach(LampPowerMode.allCases)",
    "ForEach(LampRoutePreference.allCases)", 'brightnessStepButton(systemName: "minus", amount: -5',
    'brightnessStepButton(systemName: "plus", amount: 5', ".disabled(!lamp.uiSupportsNearbyControls)",
])
require(IOS / "UI/LampCard.swift", ["struct LampGridCell", "model.setPower(lamp, on: !lamp.state.power)"])
require(IOS / "SHLAMPApp.swift", ["SplashScreenView()", "model.startConnections()"])

# Android is not the target of this RF5.4 iOS release, but legacy project assets must not be silently removed.
if not ANDROID.exists(): errors.append("Bundled Android compatibility tree is missing")

with (IOS / "Info.plist").open("rb") as handle: plist = plistlib.load(handle)
if plist.get("CFBundleShortVersionString") != "$(MARKETING_VERSION)": errors.append("Info.plist marketing version is not inherited from Xcode")
if plist.get("CFBundleVersion") != "$(CURRENT_PROJECT_VERSION)": errors.append("Info.plist build number is not inherited from Xcode")
pbx = (ROOT / "iosApp/SHLAMP.xcodeproj/project.pbxproj").read_text()
if pbx.count("MARKETING_VERSION = 1.8.2") != 2: errors.append("Expected Debug and Release MARKETING_VERSION 1.8.1")
if pbx.count("CURRENT_PROJECT_VERSION = 24") != 2: errors.append("Expected Debug and Release CURRENT_PROJECT_VERSION 24")

expected_hashes = json.loads((ROOT / "docs/RF5.4.2_SOURCE_SHA256.json").read_text())
for name, expected in expected_hashes.items():
    actual = hashlib.sha256((IOS / name).read_bytes()).hexdigest()
    if actual != expected: errors.append(f"Core source integrity mismatch: {name}")

if errors:
    print("RELEASE AUDIT FAILED")
    for error in errors: print(f"- {error}")
    sys.exit(1)
print("RELEASE AUDIT PASSED")
print("- Legacy BLE/local API compatibility: passed")
print("- RF5.4.2 physical/cloud identity separation: passed")
print("- RF5.4.2 BLE/LAN/Cloud route hedging: passed")
print("- RF5.4.2 bounded LAN/Cloud control timeouts: passed")
print("- Version consistency: passed")
print("- Core source hash integrity: passed")
