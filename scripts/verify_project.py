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
PBX = ROOT / "iosApp" / "SHLAMP.xcodeproj" / "project.pbxproj"
YAML = ROOT / "codemagic.yaml"
HASHES = ROOT / "docs" / "RF5.4.3_SOURCE_SHA256.json"
errors: list[str] = []

required = [
    IOS / "SHLAMPApp.swift",
    IOS / "AppViewModel.swift",
    IOS / "BLELampManager.swift",
    IOS / "CloudAPI.swift",
    IOS / "CloudRealtimeClient.swift",
    IOS / "LocalLampController.swift",
    IOS / "Info.plist",
    IOS / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png",
    IOS / "Assets.xcassets" / "BrandLogo.imageset" / "logo.png",
    PBX,
    ROOT / "iosApp" / "SHLAMP.xcodeproj" / "xcshareddata" / "xcschemes" / "SHLAMP.xcscheme",
    YAML,
    HASHES,
]
for path in required:
    if not path.exists(): errors.append(f"Missing: {path.relative_to(ROOT)}")

try:
    with (IOS / "Info.plist").open("rb") as handle:
        plist = plistlib.load(handle)
    for key in ["NSBluetoothAlwaysUsageDescription", "NSCameraUsageDescription", "NSLocalNetworkUsageDescription"]:
        if not plist.get(key): errors.append(f"Info.plist missing {key}")
    if plist.get("CFBundleShortVersionString") != "$(MARKETING_VERSION)":
        errors.append("Info.plist must source CFBundleShortVersionString from MARKETING_VERSION")
    if plist.get("CFBundleVersion") != "$(CURRENT_PROJECT_VERSION)":
        errors.append("Info.plist must source CFBundleVersion from CURRENT_PROJECT_VERSION")
except Exception as exc:
    errors.append(f"Info.plist is invalid: {exc}")

for catalog in (IOS / "Assets.xcassets").rglob("Contents.json"):
    try: json.loads(catalog.read_text())
    except Exception as exc: errors.append(f"Invalid asset JSON {catalog.relative_to(ROOT)}: {exc}")

try:
    from PIL import Image
    icon = Image.open(IOS / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png")
    if icon.size != (1024, 1024): errors.append(f"App icon must be 1024x1024, got {icon.size}")
except Exception as exc:
    errors.append(f"Unable to validate app icon: {exc}")

pbx_text = PBX.read_text() if PBX.exists() else ""
for swift_file in sorted(IOS.rglob("*.swift")):
    if swift_file.name not in pbx_text:
        errors.append(f"Swift file not referenced by Xcode project: {swift_file.relative_to(ROOT)}")
for expected in [
    "SHLAMP", "com.smarthandicrafts.shlamp", "IPHONEOS_DEPLOYMENT_TARGET = 17.0",
    "MARKETING_VERSION = 1.8.4", "CURRENT_PROJECT_VERSION = 26",
]:
    if expected not in pbx_text: errors.append(f"Xcode project is missing setting: {expected}")
if pbx_text.count("MARKETING_VERSION = 1.8.4") != 2:
    errors.append("Expected Debug and Release MARKETING_VERSION 1.8.4")
if pbx_text.count("CURRENT_PROJECT_VERSION = 26") != 2:
    errors.append("Expected Debug and Release CURRENT_PROJECT_VERSION 26")

try:
    import yaml  # type: ignore
    parsed = yaml.safe_load(YAML.read_text())
    if "ios-unsigned-sideloadly" not in parsed.get("workflows", {}):
        errors.append("Codemagic workflow ios-unsigned-sideloadly is missing")
except ModuleNotFoundError:
    text = YAML.read_text()
    if "workflows:" not in text or "ios-unsigned-sideloadly:" not in text:
        errors.append("Codemagic YAML structure is missing")
except Exception as exc:
    errors.append(f"codemagic.yaml is invalid: {exc}")

try:
    expected_hashes = json.loads(HASHES.read_text())
    for name, expected_hash in expected_hashes.items():
        path = IOS / name
        if not path.exists():
            errors.append(f"Core source hash target missing: {name}")
            continue
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != expected_hash: errors.append(f"Core source integrity mismatch: {name}")
except Exception as exc:
    errors.append(f"Core source hash manifest is invalid: {exc}")

# RF5.4.2 production-routing invariants.
checks = {
    "BLELampManager.swift": [
        "connectionSetupCompleted", "guard isReady, let characteristic = controlCharacteristic",
        "Task.sleep(for: .milliseconds(800))",
    ],
    "LocalLampController.swift": [
        "timeoutIntervalForRequest = 1.15", "timeoutIntervalForResource = 1.5",
        "Task.sleep(for: .milliseconds(750))", "request.timeoutInterval = 1.0",
        "realtimeExpectedLampByHost", "expectedLampID: snapshot.lampId",
    ],
    "CloudAPI.swift": [
        "controlConfiguration.timeoutIntervalForRequest = 1.15",
        "controlConfiguration.waitsForConnectivity = false", "controlPath: Bool = false",
    ],
    "CloudRealtimeClient.swift": ["timeout: TimeInterval = 0.75", "Task.sleep(for: .seconds(4))"],
    "AppViewModel.swift": [
        "private let routeHedgeDelayMs = 180", "base = [.bluetooth, .wifi, .cloud]",
        "there is deliberately NO Cloud→LAN time fence", "timeout: 0.75", "timeout: 1.6",
        "Task.sleep(for: .milliseconds(220))", "same-ID cloud hedge",
        "record.route = self.selectedRoute(for: record, local: record, cloud: cloud)",
        "physicalLocalIDNormalized", "cloudIDNormalized", "setOutputState",
        "durableDeliveryRetryDelaysMs = [0, 140, 320]", "reissuedForTransportRetry",
        "RF5.4.3 CMD retry",
        "wifiInterfaceMonitor", "localWiFiAvailable",
        "guard localWiFiAvailable else { return false }",
    ],
}
for name, snippets in checks.items():
    text = (IOS / name).read_text()
    for snippet in snippets:
        if snippet not in text: errors.append(f"RF5.4.2 invariant missing in {name}: {snippet}")

ui_text = "\n".join(path.read_text() for path in (IOS / "UI").glob("*.swift"))
for required_ui in ["LampGridCell", "uiCanAttemptBasicControl", "uiSupportsNearbyControls", "BrandLogoView", "LampHeroRingView"]:
    if required_ui not in ui_text: errors.append(f"Required audited UI component missing: {required_ui}")
home_text = (IOS / "UI" / "HomeViews.swift").read_text()
if re.search(r"NavigationLink\(value:\s*lamp\.id\)\s*\{\s*LampCard", home_text, re.S):
    errors.append("Home/Devices still nest LampCard directly inside NavigationLink; power hit targets may conflict")

secret_patterns = [
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
]
for path in ROOT.rglob("*"):
    if not path.is_file() or path.suffix.lower() in {".jar", ".png", ".rar", ".zip"}: continue
    try: content = path.read_text(errors="ignore")
    except Exception: continue
    for pattern in secret_patterns:
        if pattern.search(content): errors.append(f"Possible private credential in {path.relative_to(ROOT)}")

if errors:
    print("PROJECT VERIFICATION FAILED")
    for error in errors: print(f"- {error}")
    sys.exit(1)

swift_files = list(IOS.rglob("*.swift"))
sha = hashlib.sha256("".join(sorted(p.read_text() for p in swift_files)).encode()).hexdigest()
print("PROJECT VERIFICATION PASSED")
print(f"Swift files: {len(swift_files)}")
print(f"Swift source SHA-256: {sha}")
print("iOS version: 1.8.4 (26)")
print("RF5.4.3 routing/control invariants: passed")
print("Core source integrity: passed")
print("Codemagic workflow: ios-unsigned-sideloadly")
