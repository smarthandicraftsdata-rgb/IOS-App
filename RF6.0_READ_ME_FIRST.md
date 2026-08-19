# SH Lamp iOS 2.0.0 build 28 — RF6.0

RF6.0 separates local Devices from Remote Cloud control.

- Devices: Bluetooth / local Wi-Fi only.
- Remote: Render Cloud only.
- Remote Access OFF: ESP Cloud is stopped and LAN mutations are enabled.
- Remote Access ON: Wi-Fi remains associated, LAN mutations are disabled, Cloud is enabled.
- Bluetooth remains available in both modes.

RF6 verification:

```bash
python3 scripts/verify_project.py
python3 scripts/audit_release.py
```
