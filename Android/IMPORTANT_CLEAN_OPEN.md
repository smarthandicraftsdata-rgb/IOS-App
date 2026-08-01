# Important: open this as a clean project

This corrected project already contains the complete UI inside `CloudHomeActivity.kt`.

Do **not** extract or copy it over the earlier UI project. The earlier project contained a separate file:

`app/src/main/java/com/example/shlamp/ModernLampUi.kt`

If that old file remains, Kotlin sees two copies of `ModernLampApp`, `ModernAppTab`, `ModernGlyph`, and `ModernMenuRowData`, producing redeclaration and overload-ambiguity errors.

## Correct steps

1. Close Android Studio.
2. Delete the previously extracted SH Lamp UI project folder, or choose a completely new folder.
3. Extract this ZIP into the new folder.
4. Open the folder containing `settings.gradle.kts`.
5. Let Android Studio complete Gradle Sync.
6. Run **Build > Clean Project**, then **Build > Rebuild Project**.

The “New Minor Gradle Version Available” message is informational and can be ignored for this build.
