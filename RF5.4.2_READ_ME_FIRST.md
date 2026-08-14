# SH Lamp iOS 1.8.2 build 24 — R21A RF5.4.2

This tree is merged from the exact RF5.4.1 HAC iOS source contained in
`SH-Lamp-R21A-RF5.4.1-HardwareAcceptanceCandidate-20260813`.

RF5.4.2 changes are deliberately limited to the post-hardware findings:
- explicit physical/local lamp identity vs Render/cloud identity;
- physical-ID preflight for LAN mutation/realtime health;
- same logical ordered command across BLE → LAN → Cloud hedging;
- modern power/brightness uses absolute ordered `setOutputState`;
- Cloud live slider frames use ordered `setOutputState`, followed by a durable release;
- version 1.8.2, build 24.

`BLELampManager.swift` is byte-for-byte unchanged from RF5.4.1 HAC.

Validation:
- `python scripts/verify_project.py`
- `python scripts/audit_release.py`
- all 19 Swift source files parse with Swift 6.2.1 in the acceptance environment.

The historical RF5.4/RF5.4.1 reports remain in the tree for traceability.
