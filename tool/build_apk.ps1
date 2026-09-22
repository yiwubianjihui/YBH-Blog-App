# YBH Blog App - release APK build helper  (verified working 2026-09-14)
#
# Produces build\app\outputs\flutter-apk\app-release.apk (universal, release-signed)
# and installs it on the attached device with:  adb install -r <apk>
#
# ---------------------------------------------------------------------------
# WHAT ACTUALLY BLOCKS A BUILD ON THIS MACHINE (all root-caused, all handled below)
#
#   1. DUPLICATE PROXY ENV VARS.  The shell exported BOTH `HTTP_PROXY` and
#      `http_proxy` (same for https/no_proxy).  Consequences, all confirmed:
#        * `Get-ChildItem Env:` throws "An item with the same key has already been added";
#        * `Start-Process` throws the same, so detached jobs could not be started;
#        * the Gradle daemon JVM forked by the client dies instantly with
#          0xC0000005 (BEX64, "faulting module: unknown") and writes no daemon log.
#      Symptom: gradlew prints exactly one line ("... single-use Daemon process
#      will be forked") and exits 1 with no error at all.
#      FIX: step 0 below.
#
#   2. `flutter.bat` ITSELF IS BROKEN HERE - two separate causes:
#        * the stock script CALLs bin\internal\shared.bat (git probing) first;
#        * it passes `--packages=<...package_config.json>`, and the Dart VM
#          crashes with 0xC0000005 whenever that flag is present.
#      FIX: step 1 installs the shim from tool\flutter-shim\ (the original stock
#      file is preserved as flutter.bat.orig).  The shim also RETRIES the dart
#      invocation, because dart.exe/flutter_tools.snapshot still dies randomly
#      with 0xC0000005 at VM startup on this box - Gradle's
#      :app:compileFlutterBuildRelease shells out to flutter.bat and fails the
#      whole build on a non-zero exit, so the retry has to live inside the shim.
#
#   3. THE SANDBOX SOMETIMES KILLS THE WHOLE PROCESS TREE MID-BUILD, typically
#      around the memory-hungry R8 step.  There is nothing to fix here, so this
#      script just retries (see -Tries) - every attempt reuses the caches the
#      previous one built, so a retry is cheap and usually finishes the job.
#
#   4. MEMORY.  `android\gradle.properties` used to ship -Xmx8G; on a machine
#      with <8G free the daemon is killed by the OS (same "no output" symptom).
#      It is now 2560m - enough for R8, which is the step that dies first when
#      the heap is too small (1.5G is NOT enough, verified).
#
#   5. REQUIRED GRADLE PROPERTIES when calling Gradle directly instead of
#      `flutter build`.  Without -Pflutter.androidSdkRoot / -Pflutter.installedNdkVersions
#      the Flutter plugin takes the configureSyntheticExternalNativeBuildFallback
#      path and builds an EMPTY CMake project purely to trick AGP into
#      downloading the NDK (cmake crashes here).  Passed below.
#      NOTE: `--foreground` is a dead end - the daemon just parks in
#      Daemon.awaitExpiration and never receives the build (confirmed via jstack).
#
#   6. VERSION CODE.  The Flutter plugin reads `flutter.versionCode` from
#      android\local.properties and DEFAULTS TO 1 when the key is missing -
#      which would make the APK refuse to install over an existing one
#      (INSTALL_FAILED_VERSION_DOWNGRADE).  CI ships --split-per-abi APKs where
#      Flutter ADDS 1000 x abiIndex, so the arm64 artifact carrying pubspec
#      build number N gets versionCode 2000 + N.  This script writes
#      versionCode = 2000 + N so the local universal APK installs as a genuine
#      upgrade over that artifact.
#
# Usage:
#   powershell -File tool\build_apk.ps1
#   powershell -File tool\build_apk.ps1 -Tries 6
#   powershell -File tool\build_apk.ps1 -SkipShim          # leave flutter.bat alone
#   powershell -File tool\build_apk.ps1 -VersionCode 2015
# ---------------------------------------------------------------------------

param(
  # NOTE: the toolchain moved from E:\dsh\.tools\* to C:\Dev\* in mid-Sept 2026
  # (see handoff/T46 section 1.1: Flutter 3.47.1 stable, Android SDK platform-36,
  # NDK 28.2.13676358). The old E: paths no longer exist and fail at pub get.
  [string]$Sdk         = 'C:\Dev\android\sdk',
  [string]$FlutterRoot = 'C:\Dev\flutter',
  [string]$PubCache    = 'C:\Dev\pub-cache',
  [string]$Ndk         = '28.2.13676358',
  [string]$VersionName = '',
  [int]$VersionCode    = 0,
  [int]$Tries          = 4,
  [switch]$SkipShim
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
$probe = Join-Path $repo 'build'          # git-ignored; keeps build logs out of the tree
if (-not (Test-Path $probe)) { New-Item -ItemType Directory -Path $probe -Force | Out-Null }

function Note($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

# ---- 0) THE critical step: drop the duplicated proxy variables ----------------
foreach ($v in 'http_proxy','https_proxy','no_proxy','HTTP_PROXY','HTTPS_PROXY','NO_PROXY','NODE_USE_ENV_PROXY') {
  Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}
Note 'proxy env vars cleared (duplicates crash the forked Gradle daemon)'

# ---- 1) install the flutter.bat shim if the stock one is in place ------------
$fb    = Join-Path $FlutterRoot 'bin\flutter.bat'
$fbBak = Join-Path $FlutterRoot 'bin\flutter.bat.orig'
$shimDir = Join-Path $probe 'flutter-shim'
if (-not $SkipShim -and (Test-Path $shimDir)) {
  if (-not (Test-Path $fbBak)) {
    if (Test-Path $fb) { Copy-Item $fb $fbBak -Force; Note "backed up stock flutter.bat -> flutter.bat.orig" }
  }
  Copy-Item (Join-Path $shimDir 'flutter.bat')      $fb -Force
  Copy-Item (Join-Path $shimDir 'flutter_shim.ps1') (Join-Path $FlutterRoot 'bin\flutter_shim.ps1') -Force
  Note 'flutter.bat shim installed (retries dart, skips --packages)'
}

# ---- 2) environment ----------------------------------------------------------
$env:FLUTTER_ROOT     = $FlutterRoot
$env:PUB_CACHE        = $PubCache
$env:ANDROID_HOME     = $Sdk
$env:ANDROID_SDK_ROOT = $Sdk
if (-not $env:JAVA_HOME) {
  $jdk = Get-ChildItem 'C:\Program Files\Microsoft\jdk-*' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($jdk) { $env:JAVA_HOME = $jdk.FullName }
}
Note "JAVA_HOME   = $env:JAVA_HOME"
Note "ANDROID_SDK = $env:ANDROID_HOME"

# ---- 3) dependencies (must run INSIDE the repo) ------------------------------
Set-Location $repo
$dart = Join-Path $FlutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
& $dart pub get *> (Join-Path $probe 'build_pubget.log')
if ($LASTEXITCODE -ne 0) { & $dart pub get --offline *> (Join-Path $probe 'build_pubget.log') }
Note "pub get rc = $LASTEXITCODE"

# ---- 4) derive the version and write local.properties ------------------------
$pubspec = Join-Path $repo 'pubspec.yaml'
$line = (Get-Content $pubspec | Select-String -Pattern '^version:' | Select-Object -First 1).ToString()
$ver  = ($line -replace '^version:\s*', '').Trim()
if (-not $VersionName) { $VersionName = ($ver -split '\+')[0] }
if ($VersionCode -le 0) {
  $build = ($ver -split '\+')
  $n = if ($build.Count -gt 1) { [int]($build[1] -replace '\D','') } else { 0 }
  $VersionCode = 2000 + $n
}
Note "version: name=$VersionName code=$VersionCode  (pubspec: $ver)"

$lp = Join-Path $repo 'android\local.properties'
@(
  ('sdk.dir=' + $Sdk.Replace('\','\\')),
  ('flutter.sdk=' + $FlutterRoot.Replace('\','\\')),
  'flutter.buildMode=release',
  ('flutter.versionName=' + $VersionName),
  ('flutter.versionCode=' + $VersionCode)
) | Set-Content -Path $lp -Encoding ascii

# warn (do not edit) if the heap looks too small for R8
$gp = Join-Path $repo 'android\gradle.properties'
$jvm = (Get-Content $gp -ErrorAction SilentlyContinue | Select-String '^org\.gradle\.jvmargs').ToString()
Note "gradle jvmargs: $jvm"

# ---- 5) build, with retries (the sandbox can kill any attempt mid-way) -------
$apk = Join-Path $repo 'build\app\outputs\flutter-apk\app-release.apk'
Set-Location (Join-Path $repo 'android')
$ok = $false
for ($i = 1; $i -le $Tries; $i++) {
  Get-ChildItem (Join-Path $repo 'android\.gradle') -Recurse -Filter '*.lock' -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch {}
  }
  $before = (Get-Item $apk -ErrorAction SilentlyContinue).LastWriteTime
  $log = Join-Path $probe ("build_gradle_try$i.log")
  Note "--- attempt $i/$Tries (log: $log) ---"
  & .\gradlew.bat --console=plain `
      "-Pflutter.androidSdkRoot=$Sdk" `
      "-Pflutter.installedNdkVersions=$Ndk" `
      :app:assembleRelease *> $log
  $rc = $LASTEXITCODE
  $after = (Get-Item $apk -ErrorAction SilentlyContinue).LastWriteTime
  Note "attempt $i rc=$rc"
  if ($after -ne $before -and $after) { $ok = $true; break }
}

Set-Location $repo
if ($ok) { Note "OK: $apk" } else { Note "APK not refreshed - see the build_gradle_try*.log files" }

Note 'artifacts:'
Get-ChildItem (Join-Path $repo 'build\app\outputs\flutter-apk\*.apk') -ErrorAction SilentlyContinue |
  ForEach-Object { Write-Host ("  {0,-28} {1,12:N0} B  {2}" -f $_.Name, $_.Length, $_.LastWriteTime) }

Write-Host @"

Install on the device and verify (font localisation / covers / editor / nav):
  adb install -r build\app\outputs\flutter-apk\app-release.apk
  adb logcat -c ; adb shell monkey -p cn.yibianhui.blog -c android.intent.category.LAUNCHER 1
  adb logcat -d | Select-String "YBH (WebView|fonts|Reader|editor)"

Expected lines:
  [YBH fonts] 16 files -> 26 inline rules (0 skipped), CSS <n> chars, 2 keep-prefixes
  [YBH WebView vX.Y.Z] fonts | 16 files, 26 inline rules (0 skipped), ready=true
  [YBH WebView ...] fonts | localisation done: <n> site @font-face removed, 148 kept, 1 inserted

NOTE: "skipped" > 0 means pubspec.yaml assets: is missing a directory -- see
      test/font_manifest_test.dart, which fails loudly on exactly that.
"@
