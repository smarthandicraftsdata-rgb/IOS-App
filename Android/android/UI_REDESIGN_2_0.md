# SH Lamp UI 2.0

The Android UI has been reorganised around the current smart-home navigation model:

- **Home** — landing dashboard, quick scenes, nearby-device banner, favourites and room overview.
- **Devices** — complete searchable/filterable lamp grid with room chips and quick power controls.
- **Care** — product-health summary, device status, diagnostics entry and future battery reporting area.
- **Menu** — home/account status, product management, diagnostics, add-lamp and sign-out actions.

## Device screen

The lamp detail page now uses a product-first layout with a large lamp illustration, power control, state tiles, brightness presets and a segmented **Control / Useful features** area. Existing power, brightness, timer, fade, identify and settings callbacks are preserved.

## Design system

- Bright blue-grey app background
- White rounded cards
- Teal primary actions
- Warm light accents
- Soft state colours for success, warning, error and offline
- Custom lightweight Compose-drawn icons and lamp illustrations
- Adaptive device grid for phones and larger screens

## Functional preservation

The redesign does not replace the existing connection layer. BLE, local Wi-Fi, cloud commands, realtime updates, provisioning, account management, lamp settings and diagnostics continue to use the existing managers and activities.

## Battery area

The Care tab intentionally does not invent a battery value. It is prepared to display charge level and runtime after ADC battery telemetry is added to firmware and the app data model.
