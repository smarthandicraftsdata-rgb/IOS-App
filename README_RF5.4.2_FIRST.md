# SH Lamp iOS 1.8.2 build 24 — RF5.4.2 Hardware Acceptance Candidate

Base: exact iOS project from `SH-Lamp-R21A-RF5.4.1-HardwareAcceptanceCandidate-20260813`.

RF5.4.2 post-hardware corrections are integrated into the actual project, not supplied as a standalone helper patch.

Key changes:
- Explicit physical/local identity and Cloud identity domains.
- LAN/BLE use the physical lamp ID; Cloud uses the Render/cloud lamp ID.
- Local `setPowerMode`, `identify`, and `rename` now prove physical identity before mutation.
- Automatic route remains BLE -> LAN -> Cloud with the same ordered command identity for hedges.
- Modern power remains absolute `setOutputState`; Cloud live slider uses ordered absolute `setOutputState`.
- BLELampManager.swift is byte-for-byte preserved from RF5.4.1.

Validation performed in the Linux acceptance environment:
- 19/19 Swift files parser-clean.
- Models.swift type-checks with warnings treated as errors.
- Actual Models migration/identity runtime tests pass.
- 1,000,000 compiled identity/migration vectors pass.
- Actual-source iOS RF5.4.2 audit passes 26/26 checks.

Still required before production-final status: actual Xcode/Codemagic Release archive and physical iPhone/lamp acceptance.
