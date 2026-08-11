# SH Lamp UI V5

This update fixes two UI-only issues seen on the phone:

1. **Devices card size**
   - Device grid minimum cell width reduced from 160 dp to 145 dp.
   - The lamp card is now square and uses smaller internal controls.
   - Typical phones now show two compact lamp cards per row.

2. **Incorrect diagnostics target**
   - Care/Menu diagnostics now passes the selected/first real lamp ID and its remote cloud ID.
   - Previously the generic diagnostics button opened the activity with no lamp ID, so it tested an empty device and incorrectly reported no Bluetooth, local Wi-Fi, or remote identity.
   - A safety message is shown if diagnostics is ever opened without a lamp selection.

No BLE, local Wi-Fi, cloud command, provisioning, or device identity routing logic was changed.
