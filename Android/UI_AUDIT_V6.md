# SH Lamp UI V6 audit

This build starts from V5 and keeps the existing lamp connection implementation.

## UI corrections included

- Devices uses a compact adaptive two-column grid on normal phone widths.
- Connection Diagnostics receives the selected local and cloud lamp identity.
- Inactive backup routes (for example Bluetooth while Wi-Fi is active) are shown as informational instead of a failure.
- The diagnostic summary explains that one working route is sufficient.
- The complete Add Lamp wizard has been redesigned with:
  - ThinQ-inspired header and four-stage progress indicator
  - lamp hero/status card on every stage
  - improved nearby-lamp result cards
  - clearer Wi-Fi versus nearby-only choices
  - QR/manual identity screen
  - Wi-Fi setup status presentation
  - quick room choices
  - keyboard-safe scrolling
- Account and Lamp Settings forms now move above the software keyboard.
- Deprecated `quadraticBezierTo()` calls were replaced by `quadraticTo()`.
- `ModernLampUi.kt` remains an empty compatibility file, preventing duplicate UI declarations when this project is extracted over an older copy.

## Logic preservation

The `AddLampActivity` activity/manager/cloud setup implementation before the Compose UI section is byte-for-byte unchanged from V5. BLE discovery, QR parsing, Wi-Fi provisioning, cloud claim/link, name/room persistence, and completion callbacks were not rewritten.

Only these Kotlin files differ from V5:

- `AddLampActivity.kt` — Compose UI and keyboard handling
- `ConnectionDiagnosticsActivity.kt` — customer-facing diagnostic presentation and wording
- `CloudHomeActivity.kt` — deprecated drawing API replacement only
- `CloudAccountActivity.kt` — keyboard inset handling only
- `LampSettingsActivity.kt` — keyboard inset handling only

## Verification performed

- Kotlin delimiter/brace checks passed for all changed files.
- Duplicate declaration counts are one each for `ModernLampApp`, `ModernAppTab`, and `ModernGlyph`.
- No `quadraticBezierTo()` calls remain.
- A full Gradle build could not be run in this environment because the Gradle distribution requires internet access. Build it in Android Studio using Clean Project, then Rebuild Project.
