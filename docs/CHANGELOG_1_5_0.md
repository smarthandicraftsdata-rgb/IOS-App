# SH Lamp 1.5.0 change log

## Connection and identity

- Added a canonical device model so BLE, local Wi-Fi and cloud represent routes to one physical lamp.
- Added FFE3 identity resolution for local ID and cloud ID association.
- Added background probing of nearby known lamps when Bluetooth becomes available.
- Added duplicate migration and merge rules preserving name, room, BLE address, local address and verified cloud ownership.
- Kept firmware-reported cloud IDs separate from account-verified remote access.
- Added route preference: Automatic, Local Wi-Fi, Bluetooth and Remote.
- Added immediate Wi-Fi/Bluetooth state invalidation and route re-evaluation.
- Added one retry through the next available route after local-route failure.

## Add Lamp and remote access

- Selecting a scan result now verifies the lamp without immediately saving it.
- Added explicit Bluetooth-only setup.
- Added explicit local Wi-Fi setup without requiring a claim code.
- Separated cloud claiming from Wi-Fi provisioning.
- Added optional Enable Remote Access step after local setup.
- Added Add Remote Access to Lamp Settings.
- Claiming updates the existing physical lamp instead of creating a second device.

## Lamp control UI

- Replaced the oversized fixed control area with an expanded scrollable hero and compact sticky header.
- Added iPhone-style battery level presentation.
- Added live route, power mode and runtime state.
- Added firmware R19B modes: Balanced, Maximum Backup, BLE Only and Touch Only.
- Added warnings before disabling Wi-Fi/cloud or all wireless control.
- Maximum Backup requests are capped and displayed at 70%.

## Reliability

- Debounced duplicate BLE STATUS commands.
- Guarded BLE service setup so connection callbacks and initial-state requests run once.
- Moved route monitoring and connection ownership to app-level managers.
- Added backward-compatible decoding for persisted iOS lamp records.
- Updated Android to 1.5.0 (7) and iOS to 1.5.0 (10).
