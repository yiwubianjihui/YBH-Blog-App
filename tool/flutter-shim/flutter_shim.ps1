# YBH flutter.bat stand-in (see flutter.bat in this directory).
#
# Why this shim exists at all:
#   1. the stock flutter.bat CALLs bin\internal\shared.bat (git probing) first,
#      which dies with 0xC0000005 here;
#   2. launching dart.exe straight from cmd.exe also dies with 0xC0000005.
#      The identical command started from powershell.exe is far more reliable,
#      so flutter.bat delegates here instead.
#   Never add --packages=<...package_config.json>: the Dart VM crashes with
#   0xC0000005 whenever that flag is present (the snapshot resolves its own).
#
# WHY THE RETRY LOOP (2026-09-14):
#   Even from PowerShell, dart.exe/flutter_tools.snapshot dies intermittently
#   with 0xC0000005 (NTSTATUS -1073741819) at VM startup - roughly a coin flip
#   while free memory is tight. The crash is at *startup* and produces no
#   output, so retrying is safe and effective. Putting the loop HERE (instead of
#   in a wrapper script) means every caller benefits, in particular Gradle's
#   :app:compileFlutterBuildRelease, which shells out to flutter.bat and fails
#   the whole build if it returns non-zero.
#
#   Only NTSTATUS-style (negative) exit codes are retried - real tool errors
#   come back as small positive codes and are reported immediately.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$FlutterArgs)

$root = Split-Path -Parent $PSScriptRoot
$dart = Join-Path $root 'bin\cache\dart-sdk\bin\dart.exe'
$snap = Join-Path $root 'bin\cache\flutter_tools.snapshot'

if (-not (Test-Path $dart)) { Write-Error "dart not found: $dart"; exit 1 }
if (-not (Test-Path $snap)) { Write-Error "flutter_tools.snapshot not found: $snap"; exit 1 }

$maxTries = 60
$rc = 1
for ($i = 1; $i -le $maxTries; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $dart --disable-dart-dev $snap @FlutterArgs
    $rc = $LASTEXITCODE
    $sw.Stop()

    if ($rc -eq 0) {
        if ($i -gt 1) { Write-Host "[flutter_shim] succeeded on attempt $i" }
        exit 0
    }

    if ($rc -lt 0) {
        # NTSTATUS-style crash (0xC0000005 -> -1073741819). Retry.
        Write-Host ("[flutter_shim] attempt {0}/{1} crashed rc={2} (0x{3:X8}) after {4:N1}s - retrying" -f `
            $i, $maxTries, $rc, [uint32]($rc -band 0xFFFFFFFF), $sw.Elapsed.TotalSeconds)
        Start-Sleep -Milliseconds 300
        continue
    }

    # genuine tool failure - do not mask it
    Write-Host "[flutter_shim] attempt $i failed with rc=$rc (tool error) - not retrying"
    exit $rc
}

Write-Host "[flutter_shim] giving up after $maxTries attempts (last rc=$rc)"
exit $rc
