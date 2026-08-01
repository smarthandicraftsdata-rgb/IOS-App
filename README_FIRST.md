# SH Lamp Android + iOS conversion

This package contains:

- `android/` — the original Android 1.3.1 project, preserved without generated build caches.
- `iosApp/` — a native SwiftUI iPhone application created from the Android app's actual cloud, BLE, local-network, QR and battery protocols.
- `codemagic.yaml` — builds an unsigned device IPA for installation through Sideloadly on Windows.
- `docs/` — conversion, protocol and installation documentation.

## What is implemented on iPhone

- Account registration, login and password reset
- Cloud dashboard, rooms and multiple lamps
- Cloud command and WebSocket updates
- Bluetooth discovery and control through service `FFE0`
- Wi-Fi provisioning over characteristic `FFE2`
- Local Bonjour discovery and HTTP control
- QR-code lamp claiming
- Power, brightness, fade, timer and identify commands
- Battery percentage, voltage and charging-state display
- Home, Devices, Care and Menu tabs
- Lamp rename, room assignment, unlinking and diagnostics
- Secure token storage in iOS Keychain

## Build it without owning a Mac

1. Create a new private GitHub repository.
2. Upload the **contents of this folder**, so `codemagic.yaml` is at the repository root.
3. Add the repository in Codemagic.
4. Start the workflow named **SH Lamp iOS - unsigned IPA for Sideloadly**.
5. Download `SHLAMP-unsigned.ipa` from the build artifacts.
6. Follow `docs/CODEMAGIC_SIDELOADLY.md` to install it on the iPhone 15 Pro.

## Validation status

- All generated Swift files pass Swift parser validation.
- The property list, asset catalog, Xcode references and Codemagic YAML are checked by `scripts/verify_project.py`.
- This environment does not contain macOS/Xcode and cannot connect to the physical lamp. The first Codemagic build is therefore the final Xcode compiler check, and real BLE/Wi-Fi behavior must be tested with the iPhone and lamp.

## Open first

Read:

1. `docs/CODEMAGIC_SIDELOADLY.md`
2. `docs/CONVERSION_REPORT.md`
3. `docs/KNOWN_LIMITATIONS.md`
