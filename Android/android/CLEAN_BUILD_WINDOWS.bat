@echo off
setlocal
cd /d "%~dp0"

echo Stopping Gradle daemons...
call gradlew.bat --stop

echo Removing project build caches...
if exist .gradle rmdir /s /q .gradle
if exist build rmdir /s /q build
if exist app\build rmdir /s /q app\build

echo.
echo Clean complete. Open this folder in Android Studio and Sync Project with Gradle Files.
pause
