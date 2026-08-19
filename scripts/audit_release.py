#!/usr/bin/env python3
from __future__ import annotations
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "iosApp" / "SHLAMP"
errors: list[str] = []

def require(rel: str, snippets: list[str]) -> None:
    text = (IOS / rel).read_text()
    for snippet in snippets:
        if snippet not in text:
            errors.append(f"Missing RF6 release invariant in {rel}: {snippet}")

require("AppViewModel.swift", [
    "@Published var remoteLamps: [LampRecord] = []",
    "lamps = normalizedLocal.values",
    "remoteLamps = dashboard.lamps.map",
    "// RF6.0: Devices never route through Cloud.",
    "private func performRemoteOrdered(",
    "Remote slider is final-value only",
])
require("BLELampManager.swift", [
    "func remoteAccess(_ enabled: Bool)",
    "didReceiveRemoteAccess enabled: Bool",
])
require("LocalLampController.swift", [
    "func setIPControlMode(",
    '/api/ip-mode?mode=',
])
require("UI/HomeViews.swift", [
    "struct RemoteView: View",
    "private struct RemoteLampCard: View",
    'title: "Remote"',
])
require("CloudAPI.swift", ["SHLAMP-iOS/2.0.0-RF6.0"])
require("CloudRealtimeClient.swift", ["SHLAMP-iOS/2.0.0-RF6.0"])

# Fail release if local Devices route order reintroduces Cloud.
app = (IOS / "AppViewModel.swift").read_text()
s = app.find("private func routeOrder(for lamp:")
e = app.find("private func routeCanBeAttempted", s)
if s < 0 or e < 0 or ".cloud" in app[s:e]:
    errors.append("Local Devices route order must contain BLE/Wi-Fi only")

if errors:
    print("RF6 RELEASE AUDIT FAILED")
    for e in errors:
        print(f"- {e}")
    sys.exit(1)

print("RF6 RELEASE AUDIT PASSED")
print("- Local Devices and Remote Cloud state/health are separated")
print("- BLE remains available as local route")
print("- LAN/Cloud are not combined in Devices route order")
print("- Remote final brightness is sent on release")
