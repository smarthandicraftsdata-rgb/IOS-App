# SH Lamp protocol parity

This document records the Android protocol values carried into the iOS conversion.

## BLE UUIDs

| Purpose | UUID |
|---|---|
| Lamp service | `0000FFE0-0000-1000-8000-00805F9B34FB` |
| Control | `0000FFE1-0000-1000-8000-00805F9B34FB` |
| Wi-Fi provisioning/status | `0000FFE2-0000-1000-8000-00805F9B34FB` |
| Identity | `0000FFE3-0000-1000-8000-00805F9B34FB` |
| Standard battery service | `0000180F-0000-1000-8000-00805F9B34FB` |
| Standard battery level | `00002A19-0000-1000-8000-00805F9B34FB` |

## Control opcodes

| Action | Opcode | Payload |
|---|---:|---|
| Power | `0x05` | `0` or `1` |
| Brightness | `0x02` | `0…100` |
| Fade mode | `0x03` | `0…3` |
| Auto-off timer | `0x04` | `0`, `15`, `30`, `60` minutes |
| Request status | `0x06` | none |
| Identify | `0x07` | none |

## Wi-Fi/control characteristic opcodes

| Action | Opcode(s) |
|---|---|
| Send Wi-Fi credentials | `0x20`, or chunked `0x30 / 0x31 / 0x32` |
| Wi-Fi status | `0x21` |
| Retry connection | `0x22` |
| Saved-network list | `0x25 / 0x26 / 0x27` and notification frames |
| Rename lamp | `0x40` |
| Controller access list | `0x50 / 0x51 / 0x52` and notification frames |

## Local HTTP API

The iOS app attempts the same local routes as Android:

```text
/api/status
/api/power
/api/brightness
/api/fade
/api/timer
/api/identify
/api/name
/api/controllers
```

Bonjour discovery uses `_http._tcp` and filters discovered services/lamp identity rather than assuming a fixed IP address.

## Cloud base URL

```text
https://sh-lamp-cloud-render.onrender.com
```

Account, dashboard, room, claim, device and command paths were taken from the Android `CloudCore` implementation and mirrored in `CloudAPI.swift`.

## QR formats

`LampQRParser.swift` accepts the same claim information patterns used by the Android app, including URL query values and delimited lamp-ID/claim-code text. A claim is not submitted unless both lamp ID and claim code are resolved.
