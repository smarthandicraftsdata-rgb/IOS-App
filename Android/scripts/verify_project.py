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

errors: list[str] = []

required = [
    ROOT / "android",
    IOS / "SHLAMPApp.swift",
    IOS / "BLELampManager.swift",
    IOS / "CloudAPI.swift",
    IOS / "Info.plist",
    IOS / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png",
    PBX,
    ROOT / "iosApp" / "SHLAMP.xcodeproj" / "xcshareddata" / "xcschemes" / "SHLAMP.xcscheme",
    YAML,
]
for path in required:
    if not path.exists():
        errors.append(f"Missing: {path.relative_to(ROOT)}")

try:
    with (IOS / "Info.plist").open("rb") as handle:
        plist = plistlib.load(handle)
    for key in ["NSBluetoothAlwaysUsageDescription", "NSCameraUsageDescription", "NSLocalNetworkUsageDescription"]:
        if not plist.get(key):
            errors.append(f"Info.plist missing {key}")
except Exception as exc:
    errors.append(f"Info.plist is invalid: {exc}")

for catalog in (IOS / "Assets.xcassets").rglob("Contents.json"):
    try:
        json.loads(catalog.read_text())
    except Exception as exc:
        errors.append(f"Invalid asset JSON {catalog.relative_to(ROOT)}: {exc}")

pbx_text = PBX.read_text() if PBX.exists() else ""
for swift_file in sorted(IOS.rglob("*.swift")):
    if swift_file.name not in pbx_text:
        errors.append(f"Swift file not referenced by Xcode project: {swift_file.relative_to(ROOT)}")

for expected in ["SHLAMP", "com.smarthandicrafts.shlamp", "IPHONEOS_DEPLOYMENT_TARGET = 17.0"]:
    if expected not in pbx_text:
        errors.append(f"Xcode project is missing setting: {expected}")

try:
    import yaml  # type: ignore
    parsed = yaml.safe_load(YAML.read_text())
    if "ios-unsigned-sideloadly" not in parsed.get("workflows", {}):
        errors.append("Codemagic workflow ios-unsigned-sideloadly is missing")
except ModuleNotFoundError:
    # Basic fallback checks when PyYAML is unavailable.
    text = YAML.read_text()
    if "workflows:" not in text or "ios-unsigned-sideloadly:" not in text:
        errors.append("Codemagic YAML structure is missing")
except Exception as exc:
    errors.append(f"codemagic.yaml is invalid: {exc}")

secret_patterns = [
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
]
for path in ROOT.rglob("*"):
    if not path.is_file() or path.suffix.lower() in {".jar", ".png", ".rar", ".zip"}:
        continue
    try:
        content = path.read_text(errors="ignore")
    except Exception:
        continue
    for pattern in secret_patterns:
        if pattern.search(content):
            errors.append(f"Possible private credential in {path.relative_to(ROOT)}")

if errors:
    print("PROJECT VERIFICATION FAILED")
    for error in errors:
        print(f"- {error}")
    sys.exit(1)

swift_files = list(IOS.rglob("*.swift"))
sha = hashlib.sha256("".join(sorted(p.read_text() for p in swift_files)).encode()).hexdigest()
print("PROJECT VERIFICATION PASSED")
print(f"Swift files: {len(swift_files)}")
print(f"Swift source SHA-256: {sha}")
print("Codemagic workflow: ios-unsigned-sideloadly")
