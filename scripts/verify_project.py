#!/usr/bin/env python3
from __future__ import annotations
import hashlib, json, plistlib, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "iosApp" / "SHLAMP"
PBX = ROOT / "iosApp" / "SHLAMP.xcodeproj" / "project.pbxproj"
HASHES = ROOT / "docs" / "RF6.0_SOURCE_SHA256.json"
errors: list[str] = []

required = [
    IOS / "SHLAMPApp.swift",
    IOS / "AppViewModel.swift",
    IOS / "BLELampManager.swift",
    IOS / "CloudAPI.swift",
    IOS / "CloudRealtimeClient.swift",
    IOS / "LocalLampController.swift",
    IOS / "Models.swift",
    IOS / "UI" / "HomeViews.swift",
    IOS / "Info.plist",
    PBX,
    ROOT / "codemagic.yaml",
    HASHES,
]
for path in required:
    if not path.exists():
        errors.append(f"Missing: {path.relative_to(ROOT)}")

try:
    with (IOS / "Info.plist").open("rb") as handle:
        plist = plistlib.load(handle)
    if plist.get("CFBundleShortVersionString") != "$(MARKETING_VERSION)":
        errors.append("Info.plist must inherit MARKETING_VERSION")
    if plist.get("CFBundleVersion") != "$(CURRENT_PROJECT_VERSION)":
        errors.append("Info.plist must inherit CURRENT_PROJECT_VERSION")
except Exception as exc:
    errors.append(f"Invalid Info.plist: {exc}")

pbx = PBX.read_text() if PBX.exists() else ""
if pbx.count("MARKETING_VERSION = 2.0.0") != 2:
    errors.append("Expected Debug/Release MARKETING_VERSION = 2.0.0")
if pbx.count("CURRENT_PROJECT_VERSION = 28") != 2:
    errors.append("Expected Debug/Release CURRENT_PROJECT_VERSION = 28")

for swift_file in sorted(IOS.rglob("*.swift")):
    if swift_file.name not in pbx:
        errors.append(f"Swift file not referenced by Xcode project: {swift_file.relative_to(ROOT)}")

try:
    expected = json.loads(HASHES.read_text())
    for rel, sha in expected.items():
        path = IOS / rel
        if not path.exists():
            errors.append(f"Hash target missing: {rel}")
            continue
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != sha:
            errors.append(f"Source integrity mismatch: {rel}")
except Exception as exc:
    errors.append(f"RF6 source hash manifest invalid: {exc}")

checks = {
    "Models.swift": [
        "var remoteAccessEnabled = false",
        "var remoteAccessEnabled: Bool = false",
    ],
    "BLELampManager.swift": [
        "didReceiveRemoteAccess enabled: Bool",
        "func remoteAccess(_ enabled: Bool)",
        'text == "R:ON" || text == "R:OFF"',
    ],
    "LocalLampController.swift": [
        "func setIPControlMode(",
        'path: "/api/ip-mode?mode=',
        'json.bool("remoteAccessEnabled")',
    ],
    "AppViewModel.swift": [
        "@Published var remoteLamps: [LampRecord] = []",
        "func setRemoteAccess(",
        "func setRemotePower(",
        "func setRemoteBrightness(",
        "private func performRemoteOrdered(",
        "// RF6.0: Devices never route through Cloud.",
        "remoteLamps = dashboard.lamps.map",
        "lamps = normalizedLocal.values",
        "Cloud health is not an",
    ],
    "UI/HomeViews.swift": [
        "NavigationStack { RemoteView() }",
        "struct RemoteView: View",
        "private struct RemoteLampCard: View",
        "model.setRemoteAccess(",
        "model.setRemotePower(",
        "model.setRemoteBrightness(",
    ],
}
for rel, snippets in checks.items():
    text = (IOS / rel).read_text()
    for snippet in snippets:
        if snippet not in text:
            errors.append(f"RF6 invariant missing in {rel}: {snippet}")

app = (IOS / "AppViewModel.swift").read_text()
route_start = app.find("private func routeOrder(for lamp:")
route_end = app.find("private func routeCanBeAttempted", route_start)
if route_start < 0 or route_end < 0:
    errors.append("Unable to locate RF6 routeOrder")
else:
    route_body = app[route_start:route_end]
    if ".cloud" in route_body:
        errors.append("Devices routeOrder still contains Cloud")

home = (IOS / "UI" / "HomeViews.swift").read_text()
if "onEditingChanged" not in home or "model.setRemoteBrightness" not in home:
    errors.append("Remote final-value slider path missing")

if errors:
    print("RF6 PROJECT VERIFICATION FAILED")
    for e in errors:
        print(f"- {e}")
    sys.exit(1)

print("RF6 PROJECT VERIFICATION PASSED")
print("- Version: 2.0.0 build 28")
print("- Devices routing: BLE/LAN only")
print("- Remote store/tab: separate Cloud plane")
print("- Remote Access toggle protocol: present")
print("- RF6 Swift source hash integrity: passed")
