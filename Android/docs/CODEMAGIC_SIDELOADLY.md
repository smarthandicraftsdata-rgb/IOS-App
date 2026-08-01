# Build with Codemagic and install with Sideloadly

## A. Upload to GitHub

Upload the full `SHLAMP-iOS-Converted` folder contents to a private GitHub repository. The following must be visible at the root:

```text
codemagic.yaml
android/
iosApp/
docs/
```

Do not upload only the `iosApp` folder because Codemagic looks for `codemagic.yaml` at the repository root.

## B. Build the unsigned IPA

1. Sign in to Codemagic and add the GitHub repository.
2. Choose configuration from `codemagic.yaml`.
3. Select the workflow **SH Lamp iOS - unsigned IPA for Sideloadly**.
4. Start the build.
5. Open the completed build and download:
   - `SHLAMP-unsigned.ipa`
   - optionally, `SHLAMP-unsigned.ipa.sha256`

The workflow builds for `iphoneos`, disables Xcode code signing, and packages the produced `.app` into an IPA. It does not require an Apple certificate inside Codemagic because Sideloadly performs the signing step on Windows.

## C. Install on the iPhone 15 Pro

1. Install and open Sideloadly on the Windows computer.
2. Connect the iPhone by USB and unlock it.
3. Confirm **Trust This Computer** when iOS asks.
4. Drag `SHLAMP-unsigned.ipa` into Sideloadly.
5. Select the connected iPhone.
6. Enter the Apple Account used for personal signing and press **Start**.
7. Complete any Apple verification request.
8. On the iPhone, approve the developer profile if iOS asks, and enable Developer Mode if required.
9. Open **SH Lamp** and allow Bluetooth, Camera and Local Network permissions.

Free personal signing is intended for testing and normally requires periodic re-signing. TestFlight or App Store distribution later requires Apple Developer Program membership.

## D. First hardware test order

1. Sign in to the same SH Lamp cloud account used by Android.
2. Verify cloud lamps appear.
3. Stand near the lamp and open **Devices**.
4. Allow Bluetooth and connect to the nearby lamp.
5. Test power and brightness.
6. Check battery percentage.
7. Test Wi-Fi provisioning from **Add lamp**.
8. Turn Bluetooth off and verify local/cloud control separately.

## E. Logs to capture when something fails

Take screenshots of:

- The Codemagic compiler error, including the first red error line
- The iPhone permission prompt or error message
- The app Diagnostics page
- ESP32 Serial Monitor output during connection/provisioning

Do not change the BLE UUIDs or cloud URL before comparing the failure against `PROTOCOL_PARITY.md`.
