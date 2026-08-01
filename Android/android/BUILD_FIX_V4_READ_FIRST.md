# SH Lamp UI V4 — duplicate UI declaration fix

The previous archive omitted `ModernLampUi.kt`. When it was extracted over an older project folder, the older file remained on disk and Kotlin compiled both copies of the UI.

This archive deliberately includes an empty compatibility `ModernLampUi.kt` so extraction overwrites the obsolete file.

Verified conditions:
- `ModernLampApp` is declared only in `CloudHomeActivity.kt`.
- `ModernAppTab`, `ModernGlyph`, and `ModernMenuRowData` are declared only in `CloudHomeActivity.kt`.
- `ModernLampApp` is private, so it does not expose private UI model types.
- BLE, Wi-Fi, cloud, provisioning, device identity, and lamp command files are unchanged from V3.

Recommended: extract into a new folder and open the folder that directly contains `settings.gradle.kts`.
