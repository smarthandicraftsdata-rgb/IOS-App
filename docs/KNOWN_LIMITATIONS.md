# Known limitations and first-build checklist

## Not yet physically tested

The generated iOS app has not been run against:

- Xcode's Apple SDK compiler
- An iPhone simulator
- The user's iPhone 15 Pro
- The actual ESP32-C3 lamp
- The live cloud account with production credentials

The Swift source is parser-valid, but the first Codemagic build can still reveal Apple-framework type or availability errors that a Linux parser cannot detect. Any such error should be fixed from the first compiler message rather than by replacing the project.

## Wi-Fi setup on iOS

The app provisions the lamp over BLE and asks the user to enter the Wi-Fi SSID/password. It does not attempt to read the password saved by iOS. The lamp, phone and router behavior must be tested with the office router and hotspot separately because the Android project previously showed router-specific authentication and handshake failures.

## App icon

A clean temporary SH Lamp icon is included so the Xcode build has a valid app icon. It can be replaced later with the final Smart Handicrafts® / EKAKI™ artwork.

## UI parity

The iOS app reproduces the major behavior and navigation, but it is not a pixel-for-pixel port of every Android composable. The goal of this conversion is functional parity with a native iPhone interface. Visual fine-tuning should be done after the first physical-device test.

## Signing

`codemagic.yaml` deliberately produces an unsigned device IPA. Sideloadly performs personal signing on Windows. Do not add random online signing certificates or third-party profiles to the repository.

## First-build checklist

- `codemagic.yaml` is at GitHub repository root
- Workflow selected: `ios-unsigned-sideloadly`
- Artifact contains `SHLAMP-unsigned.ipa`
- iPhone permissions allowed: Bluetooth, Camera, Local Network
- iPhone and lamp are close during initial BLE test
- Cloud login succeeds before testing remote-only operation
- Diagnostics screenshots and ESP32 serial logs are collected for failures
