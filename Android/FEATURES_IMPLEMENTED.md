# SH Lamp Phase 3.5 — Implemented features

1. **My Lamps unified screen** — claimed and Bluetooth-only lamps are merged by public `lampId`, preventing separate Wi-Fi/Bluetooth/cloud cards.
2. **One `+ Add Lamp` flow** — a four-step wizard: Find, Connect, Wi-Fi, Name.
3. **Automatic Bluetooth discovery** — scanning starts when the wizard opens after permission is granted.
4. **QR and manual-code fallback** — accepts QR, Lamp ID, and claim code.
5. **Wi-Fi recommended / Bluetooth-only choice** — both finish in the same My Lamps list.
6. **Identify Lamp blink** — available while confirming a discovered lamp and from lamp settings.
7. **Resume failed setup** — setup progress is saved for 24 hours; Wi-Fi passwords are never persisted.
8. **Name and optional room** — local details are saved on the phone; claimed-lamp name/room are synchronized with the account.
9. **Automatic routing** — claimed-lamp commands use local Wi-Fi, then connected Bluetooth, then internet. Bluetooth-only lamps use nearby routes only.
10. **Change Wi-Fi** — available in Lamp Settings without deleting or reclaiming the lamp.
11. **Remove/transfer** — local-only lamps can be removed from the phone; an owner can release a claimed lamp and receive a new transfer claim code.
12. **Connection diagnostics** — checks permissions, phone Bluetooth, phone Wi-Fi/internet, saved nearby identity, Bluetooth link, local Wi-Fi response, account access, and remote status.

## QR formats accepted

JSON:
```json
{"lampId":"SH-0727182134","claimCode":"AB7K9P2X","model":"SH-LAMP-01"}
```

URI:
```text
shlamp://add?lampId=SH-0727182134&claimCode=AB7K9P2X&model=SH-LAMP-01
```

Separated text:
```text
SH-0727182134|AB7K9P2X|SH-LAMP-01
```

The QR must never include `deviceSecret`, `deviceSecretHash`, an admin key, or a Wi-Fi password.

## Backend compatibility

This update uses the already deployed account API for:

- loading homes, rooms, and devices;
- claiming a device;
- creating a room;
- renaming/assigning a room;
- releasing ownership and generating a transfer code;
- sending remote commands.

No database migration is included in this Android update.
