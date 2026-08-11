# SH Lamp iOS 1.4.2 — Codemagic Compile Fix

## Build failure diagnosed

The 1.4.1 Codemagic build reached Swift compilation and failed at every call that used `SectionHeader("…")`. The `SectionHeader` view had only the compiler-generated memberwise initializer, whose first argument is `title:`. The UI call sites intentionally used an unlabeled first argument.

## Fix

`Theme.swift` now declares an explicit initializer:

```swift
init(
    _ title: String,
    subtitle: String? = nil,
    action: String? = nil,
    onAction: (() -> Void)? = nil
)
```

This supports all existing calls in AccountView, DiagnosticsView, and HomeViews without changing those screens or any app behavior.

## Integrity

- No BLE, Wi-Fi, cloud, QR, Keychain, model, or command-routing source changed.
- The 11 protected backend/protocol files still match the baseline SHA-256 manifest.
- All 19 Swift files pass Swift parser validation.
- Info.plist and all asset catalog JSON files validate.
- Xcode marketing version is 1.4.2 and build number is 9 in Debug and Release.

The next Codemagic build remains the authoritative Apple SDK type-check and link test.
