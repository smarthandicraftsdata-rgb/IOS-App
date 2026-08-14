# RF5.4.3-R3.1 Physical Connection Recovery

This project is iOS 1.8.4 build 26.

R3 final-command retry semantics are retained. R3.1 changes route health so an authenticated/validated Local WebSocket remains authoritative LAN reachability even when iOS selects cellular as the default Internet path. A dedicated Wi-Fi interface monitor independently drives LAN discovery/recovery. Cloud default-path rebinding remains separate.
