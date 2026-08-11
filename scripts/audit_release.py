#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "iosApp" / "SHLAMP"
ANDROID = ROOT / "android"
errors: list[str] = []


def require(path: Path, snippets: list[str]) -> None:
    text = path.read_text()
    for snippet in snippets:
        if snippet not in text:
            errors.append(f"Missing protocol/UI invariant in {path.relative_to(ROOT)}: {snippet}")

require(IOS / "BLELampManager.swift", [
    "writeControl([0x05, on ? 0x01 : 0x00])",
    "writeControl([0x02, UInt8(clamp(percent, 0...100))]",
    "writeControl([0x03, UInt8(clamp(mode, 0...3))])",
    "writeControl([0x04, UInt8([0, 15, 30, 60].contains(minutes) ? minutes : 0)])",
    "writeControl([0x07])",
    "writeControl([0x06])",
    "writeControl([0x08, mode.binaryValue])",
    "requestInitialState()",
    "connectionSetupCompleted",
    "writeWiFi([0x21])",
    "writeWiFi([0x22])",
    "writeWiFi([0x25])",
    "writeWiFi([0x51])",
    "writeWiFi([0x30, UInt8(ssidBytes.count), UInt8(passwordBytes.count)])",
    "writeWiFi([0x31, UInt8(offset), UInt8(length)]",
    "writeWiFi([0x32])",
])
require(ANDROID / "app/src/main/java/com/example/shlamp/BleLampManager.kt", [
    "byteArrayOf(0x05, if (on) 0x01 else 0x00)",
    "byteArrayOf(0x02, percent.coerceIn(0, 100).toByte())",
    "byteArrayOf(0x03, mode.coerceIn(0, 3).toByte())",
    "byteArrayOf(0x04, value.toByte())",
    "byteArrayOf(0x07)",
    "byteArrayOf(0x06)",
    "byteArrayOf(0x08, mode.binaryValue)",
    "byteArrayOf(0x21)",
    "byteArrayOf(0x22)",
    "byteArrayOf(0x25)",
    "byteArrayOf(0x51)",
    "byteArrayOf(0x30, ssidBytes.size.toByte(), passwordBytes.size.toByte())",
    "packet[0] = 0x31",
    "byteArrayOf(0x32)",
])
require(IOS / "LocalLampController.swift", [
    'path: "/api/status"',
    'path: "/api/power?state=',
    'path: "/api/brightness?value=',
    'path: "/api/fade?mode=',
    'path: "/api/timer?minutes=',
    'path: "/api/identify"',
    '"/api/power-mode?mode=',
    'path: "/api/name?value=',
    'path: "/api/controllers"',
])
require(IOS / "UI/LampControlView.swift", [
    "compactHeader(lamp)",
    "IPhoneBatteryIndicator(",
    "ForEach(LampPowerMode.allCases)",
    "ForEach(LampRoutePreference.allCases)",
    'brightnessStepButton(systemName: "minus", amount: -5',
    'brightnessStepButton(systemName: "plus", amount: 5',
    ".disabled(!lamp.uiSupportsNearbyControls)",
])
require(IOS / "UI/LampCard.swift", ["struct LampGridCell", "model.setPower(lamp, on: !lamp.state.power)"])
require(IOS / "SHLAMPApp.swift", ["SplashScreenView()", "model.startConnections()"])
require(IOS / "AppViewModel.swift", [
    "order = [.wifi, .bluetooth, .cloud]",
    "shouldIdentityProbe",
    "didResolveLocalID",
    "cloudClaimed",
    "performRouted",
])
require(IOS / "UI/AddLampView.swift", [
    '"Add with Bluetooth only"',
    '"Connect to Wi-Fi"',
    '"Enable Remote Access"',
])
require(ANDROID / "app/src/main/java/com/example/shlamp/LampConnectionManager.kt", [
    "discoverKnownBluetoothLamps",
    "recordReportedIdentity",
    "commitSelectedLamp",
    "LampRoutePreference.REMOTE",
])
require(ANDROID / "app/src/main/java/com/example/shlamp/AddLampActivity.kt", [
    '"Use Bluetooth only"',
    '"Connect to Wi-Fi"',
    '"Enable remote access"',
])

with (IOS / "Info.plist").open("rb") as handle:
    plist = plistlib.load(handle)
if plist.get("CFBundleShortVersionString") != "$(MARKETING_VERSION)":
    errors.append("Info.plist marketing version is not inherited from Xcode")
if plist.get("CFBundleVersion") != "$(CURRENT_PROJECT_VERSION)":
    errors.append("Info.plist build number is not inherited from Xcode")

pbx = (ROOT / "iosApp/SHLAMP.xcodeproj/project.pbxproj").read_text()
if pbx.count("MARKETING_VERSION = 1.5.0") != 2:
    errors.append("Expected Debug and Release MARKETING_VERSION 1.5.0")
if pbx.count("CURRENT_PROJECT_VERSION = 10") != 2:
    errors.append("Expected Debug and Release CURRENT_PROJECT_VERSION 10")

expected_hashes = json.loads((ROOT / "docs/BACKEND_BASELINE_SHA256.json").read_text())
for name, expected in expected_hashes.items():
    actual = hashlib.sha256((IOS / name).read_bytes()).hexdigest()
    if actual != expected:
        errors.append(f"Core source integrity mismatch: {name}")

if errors:
    print("RELEASE AUDIT FAILED")
    for error in errors:
        print(f"- {error}")
    sys.exit(1)

print("RELEASE AUDIT PASSED")
print("- BLE protocol invariants: passed")
print("- Local API path invariants: passed")
print("- UI requirement invariants: passed")
print("- Version consistency: passed")
print("- Core source hash integrity: passed")
