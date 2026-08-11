SH Lamp Android App R18 - Phone-Style Battery UI
Version: 1.3.0 (versionCode 5)

UI changes
- Replaced technical battery text with a compact phone/iPhone-style battery icon.
- Battery icon fill reflects the percentage received from the lamp firmware.
- Battery becomes red at 20% or below.
- When charging is reported, the battery becomes green and a white lightning bolt pulses inside it.
- Removed the large "Live battery level from the lamp" / percentage-calculation information panel.
- Removed battery voltage from user-facing screens.
- Battery icon is shown on the lamp list, device tiles, lamp control screen and Care battery list.

Charging-state input supported by the app
The local/cloud lamp state may provide any one of these Boolean fields:
  "batteryCharging": true
  "isCharging": true
  "charging": true

Use false when charging stops.

Important
The current R15 ESP32 firmware reports battery percentage and voltage, but it does not report a real charging-state flag. Therefore, the app will show the normal/red battery icon now, but the green animated charging state will activate only after the firmware receives a reliable charging signal and publishes one of the fields above. The app intentionally does not guess charging from voltage changes because lamp load and voltage recovery can cause false charging indications.

Build note
A full Gradle compile could not be run in this environment because Gradle 9.4.1 was not cached and internet access is disabled. The changed Kotlin files were syntax-inspected and the previous project structure was preserved.
