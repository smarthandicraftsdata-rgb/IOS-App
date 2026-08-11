# SH Lamp 1.5.0 physical-device test checklist

Use firmware `TTP2-WIFI-BLE-R19B-P3-20260806`.

## Existing-device migration

- [ ] Install/update over the previous app without clearing storage.
- [ ] Confirm an existing cloud and BLE duplicate becomes one device card.
- [ ] Confirm custom lamp name and room remain intact.
- [ ] Confirm remote access is shown only for lamps owned by the signed-in account.

## Automatic route sequence

Starting with mobile data only:

- [ ] Open the app; the single lamp card shows Remote.
- [ ] Turn Bluetooth on; the same card changes to Bluetooth without using Add Lamp.
- [ ] Confirm no second card is created.
- [ ] Turn Wi-Fi on while connected to the lamp's network; the same card changes to Local Wi-Fi.
- [ ] Turn Wi-Fi off; the route changes to Bluetooth without restarting the app.
- [ ] Turn Bluetooth off; the route changes to Remote.
- [ ] At every step, power and brightness commands work and exactly one card remains.

## Manual route preference

- [ ] Select Bluetooth while Wi-Fi is available; the app stays on Bluetooth when BLE is connected.
- [ ] Select Remote; commands use cloud while internet is available.
- [ ] Return to Automatic; route priority becomes Local Wi-Fi, Bluetooth, Remote.
- [ ] Select an unavailable route and confirm clear reconnect/fallback feedback.

## Add Lamp

- [ ] Start Add Lamp and tap a nearby device.
- [ ] Confirm it does not appear in Devices before final confirmation.
- [ ] Complete Add Bluetooth Lamp and confirm one new card appears.
- [ ] Repeat with Connect to Wi-Fi and confirm no claim code is required.
- [ ] Confirm setup visibly advances after selection and after Wi-Fi provisioning.
- [ ] Choose Enable Remote Access and confirm Lamp ID plus claim code are required.
- [ ] Choose Not now and add remote access later from Lamp Settings.
- [ ] Confirm claiming updates the same card rather than creating another one.

## Lamp control page

- [ ] At the top, confirm the expanded controls are visible.
- [ ] Scroll down; confirm a compact sticky banner shows power, route, brightness and battery.
- [ ] Scroll back up; confirm the full header returns.
- [ ] Confirm the battery graphic and percentage follow the firmware value.
- [ ] Turn phone Wi-Fi off while this page is open and confirm the route badge updates immediately.

## Power modes

- [ ] Balanced permits 100% brightness.
- [ ] Maximum Backup caps 80% and 100% requests at 70%, and the slider returns to 70%.
- [ ] BLE Only warns first, disables Wi-Fi/cloud and keeps BLE control working.
- [ ] Touch Only warns first, disables wireless control and leaves physical touch working.
- [ ] Restart after BLE Only/Touch Only restores the saved connected mode.
- [ ] Power mode and runtime state match local firmware status.

## Navigation and reliability

- [ ] Move among Home, Devices, Lamp Control and Settings without unnecessary disconnects.
- [ ] Confirm only one initial BLE STATUS sequence occurs per connection.
- [ ] Rapid brightness changes do not create duplicate device records or freeze the route badge.
- [ ] A failed local command retries once over BLE or cloud.
- [ ] App relaunch preserves lamp identity, route preference and remote link.
