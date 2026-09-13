# YBH Blog App · Release APK 构建脚本
#
# 为什么不用 `flutter build apk`：
#   本机（开发机）上 flutter.bat / flutter_tools 的 **子进程 spawn 不稳定**，
#   `flutter build` 会以 0xC0000005 直接退出、连日志都来不及写。
#   绕过办法是「直接跑 flutter_tools.snapshot」或「直接跑 Gradle」，
#   两者都在下面给出。
#
# 用法：
#   pwsh -File tool/build_apk.ps1                 # 默认：分 ABI 构建 release
#   pwsh -File tool/build_apk.ps1 -Universal      # 构建通用包（体积大，便于分发）
#   pwsh -File tool/build_apk.ps1 -Sdk "D:\sdk"   # 指定 Android SDK
#
# 产出与命名：见脚本末尾。versionCode 规则：pubspec 里的 +N ⇒ 2000+N
# （`--split-per-abi` 时 Flutter 会再按 ABI 加 1000×序号，属正常现象）。

param(
  [switch]$Universal,
  [string]$Sdk = 'E:\dsh\.tools\android-sdk',
  [string]$FlutterRoot = 'E:\dsh\.tools\flutter',
  [string]$PubCache = 'E:\dsh\.tools\pub-cache'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

# ---- 环境 ----
$env:FLUTTER_ROOT = $FlutterRoot
$env:PUB_CACHE = $PubCache
$env:ANDROID_HOME = $Sdk
$env:ANDROID_SDK_ROOT = $Sdk
if (-not $env:JAVA_HOME) {
  $jdk = Get-ChildItem 'C:\Program Files\Microsoft\jdk-*' -Directory -ErrorAction SilentlyContinue |
         Select-Object -First 1
  if ($jdk) { $env:JAVA_HOME = $jdk.FullName }
}
Write-Host "JAVA_HOME   = $env:JAVA_HOME"
Write-Host "ANDROID_SDK = $env:ANDROID_HOME"

# local.properties 必须指向真实 SDK；flutter 工具偶尔会把它写成 sdk.dir=C:\
$lp = Join-Path $repo 'android\local.properties'
@(
  ('sdk.dir=' + $Sdk.Replace('\', '\\')),
  ('flutter.sdk=' + $FlutterRoot.Replace('\', '\\')),
  'flutter.buildMode=release'
) | Set-Content -Path $lp -Encoding ascii

$dart = Join-Path $FlutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
$snap = Join-Path $FlutterRoot 'bin\cache\flutter_tools.snapshot'

# ---- 依赖：联网用 dart pub，离线兜底 ----
Write-Host "`n=== pub get ===" -ForegroundColor Cyan
& $dart pub get
if ($LASTEXITCODE -ne 0) { & $dart pub get --offline }

# ---- 构建 ----
# 内存提示：Gradle 默认 -Xmx8G，在可用内存 < 8G 的机器上守护进程会被系统杀掉，
# 表现为「没有任何输出就 BUILD FAILED」。这里压到 2.5G 并关掉并行。
$gradleArgs = @(
  '--console=plain', '--no-daemon', '--max-workers=2',
  '-Dorg.gradle.parallel=false',
  '-Dkotlin.compiler.execution.strategy=in-process',
  '-Dorg.gradle.jvmargs=-Xmx2500m -XX:MaxMetaspaceSize=768m -XX:ReservedCodeCacheSize=128m'
)

if ($Universal) {
  Write-Host "`n=== flutter build apk --release（通用包）===" -ForegroundColor Cyan
  & $dart --disable-dart-dev $snap build apk --release
} else {
  Write-Host "`n=== gradle :app:assembleRelease（分 ABI）===" -ForegroundColor Cyan
  Push-Location (Join-Path $repo 'android')
  & .\gradlew.bat @gradleArgs :app:assembleRelease
  $rc = $LASTEXITCODE
  Pop-Location
  if ($rc -ne 0) {
    Write-Warning "Gradle 失败（rc=$rc）。若日志里是 cmake.exe 以 0xC0000005 退出，属本机 spawn 偶发问题，重跑一次通常即可。"
    exit $rc
  }
}

# ---- 汇总 ----
Write-Host "`n=== 产物 ===" -ForegroundColor Green
$dirs = @(
  (Join-Path $repo 'build\app\outputs\flutter-apk'),
  (Join-Path $repo 'build\app\outputs\apk\release')
)
Get-ChildItem -Path $dirs -Filter '*.apk' -ErrorAction SilentlyContinue |
  Sort-Object Length |
  ForEach-Object { "{0,-34} {1,12:N0} B" -f $_.Name, $_.Length }

Write-Host @"

安装到真机：
  adb install -r <apk 路径>
真机验收（字体本地化）：
  adb logcat | Select-String 'YBH WebView'   # 应看到「字体 | 打包 16 个，内联 CSS …」
  在应用内打开「整站」页，观察是否还有 woff2 请求（应为 0）
"@
