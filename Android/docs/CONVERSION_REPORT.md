# Conversion report

## Source used

The conversion is based on the uploaded **SHLAMP Battery Percentage app** Android source, version 1.3.1 (`versionCode 6`, package `com.example.shlamp`). The original Android source is included in `android/`.

The Android application is approximately 13,000 lines of Kotlin. Its main Android-specific implementation was concentrated in cloud/home UI, connection management, BLE, Wi-Fi provisioning, account flows and lamp setup.

## Conversion approach

The iPhone app is a native SwiftUI application rather than an APK wrapper or a web view. Android-only APIs were replaced with native Apple frameworks:

| Android implementation | iOS replacement |
|---|---|
| Jetpack Compose | SwiftUI |
| `BluetoothGatt` | CoreBluetooth |
| `NsdManager` | Network framework / Bonjour |
| Android Keystore | iOS Keychain |
| Google code scanner | AVFoundation QR scanner |
| SharedPreferences/session storage | Keychain-backed session model |
| Android HTTP/WebSocket stack | URLSession and URLSessionWebSocketTask |

## Preserved behavior

The iOS source keeps the existing:

- Cloud base URL and account endpoints
- Lamp claim and command routes
- WebSocket authentication and update flow
- BLE service and characteristic UUIDs
- Binary lamp-control commands
- Wi-Fi provisioning packet formats
- Lamp identity parsing
- Battery service and custom status parsing
- Local HTTP endpoint paths
- QR claim formats

## Files created

```text
iosApp/SHLAMP.xcodeproj/
iosApp/SHLAMP/
  AppViewModel.swift
  BLELampManager.swift
  CloudAPI.swift
  CloudRealtimeClient.swift
  KeychainStore.swift
  LocalLampController.swift
  QRScannerView.swift
  UI/
  Assets.xcassets/
  Info.plist
codemagic.yaml
```

## Validation performed

- Swift parser validation on every `.swift` file
- XML property-list parsing
- JSON asset-catalog parsing
- YAML parsing
- Verification that every Swift/resource file exists in the Xcode project
- Verification of required privacy usage descriptions
- Scan for accidental signing keys and private-key material

## What still requires real Apple tooling

This execution environment is Linux-based, so it cannot run `xcodebuild`, the iOS simulator, CoreBluetooth or a physical iPhone. The first Codemagic build will perform the authoritative Apple SDK type-check and link step. Physical BLE, local Wi-Fi, QR camera and cloud behavior must then be tested on the iPhone 15 Pro with the actual lamp.
