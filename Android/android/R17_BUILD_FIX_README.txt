SH Lamp Android App R17 Build Compatibility Fix

Changes:
- Replaced the member JSONObject extension in WifiLampController.kt with a normal helper function.
- Added safe default values to the three battery fields in WifiLampSnapshot.
- Battery behavior is unchanged: the app displays the firmware-provided percentage and voltage.
- App version updated to 1.2.1 (versionCode 4).

The Android Studio inspection messages about unused imports/functions and mutableFloatStateOf are warnings, not compile errors.

After replacing/opening the project:
1. File > Sync Project with Gradle Files
2. Build > Clean Project
3. Build > Rebuild Project
