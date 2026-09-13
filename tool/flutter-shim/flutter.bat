@echo off
REM ---------------------------------------------------------------------------
REM YBH shim for flutter.bat  (stock file preserved as flutter.bat.orig)
REM
REM WHY THIS IS NEEDED (root-caused 2026-09-14):
REM   1. the stock script CALLs bin\internal\shared.bat (git probing) first,
REM      which crashes with 0xC0000005 on this machine;
REM   2. launching dart.exe straight from cmd.exe also crashes with 0xC0000005,
REM      while the identical command started from powershell.exe survives.
REM   Never add --packages=<...package_config.json>: the Dart VM crashes with
REM   0xC0000005 whenever that flag is present (the snapshot resolves its own).
REM
REM Install with: powershell -File tool\build_apk.ps1   (it copies this pair
REM into <flutter>\bin, backing up the original).
REM ---------------------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0flutter_shim.ps1" %*
exit /b %ERRORLEVEL%
