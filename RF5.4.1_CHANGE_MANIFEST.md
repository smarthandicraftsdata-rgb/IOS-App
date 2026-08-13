# RF5.4.1 iOS change manifest

- `AppViewModel.swift`: preserves RF5.4 same-ID route hedging/circuit breakers; propagates expected local lamp identity into all LAN control/recovery paths; make-before-break Wi-Fi loss selection.
- `LocalLampController.swift`: pre-identity one-generation ownership, actual host→lamp identity tracking, expected-ID-bound realtime health, ACK identity validation before completion, and HTTP status identity probe before mutation.
- `CloudAPI.swift`, `CloudRealtimeClient.swift`: RF5.4.1 User-Agent/version label.
- Xcode project: marketing version 1.8.1, build 23.
- `BLELampManager.swift`: unchanged from RF5.4.
