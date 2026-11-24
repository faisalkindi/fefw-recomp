# SPDX-License-Identifier: GPL-3.0-or-later
# Windowed-mode device-loss bisect (#81). Runs the game windowed for $Seconds seconds again and again, each time with a different set of
# workaround switches (environment variables, which win over the ini), and works out which switches the game needs to survive.
#
#   1. baseline        : a cleaned copy of fefw.ini (none of the switches below set), windowed
#   2. everything on   : every switch on. If this still loses the device, none of them helps (a driver problem)
#   3. one by one      : each switch is taken out in turn; if the game still survives it was not needed and stays out
#   The switches left at the end are the smallest set that keeps the game alive.
#
# Nothing here touches fefw.ini or controls.ini: it works on copies (bisect.ini, bisect_controls.ini). Everything it finds goes into
# bisect_result.zip, to be attached to the issue.
param([int]$Seconds = 30)
$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath $PSScriptRoot

$exe = Join-Path $PSScriptRoot 'fefw.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host 'fefw.exe was not found next to this script. Put windowed_bisect.bat and windowed_bisect.ps1 in the game folder (the one with fefw.exe), then run the .bat again.' -ForegroundColor Red
    exit 1
}

$out = Join-Path $PSScriptRoot 'bisect_out'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null
$summary = Join-Path $out 'summary.txt'
function Say([string]$m, [string]$color = 'Gray') { Write-Host $m -ForegroundColor $color; Add-Content -LiteralPath $summary -Value $m }

# --- the switches: name -> environment variables ---------------------------------------------------------------------------------------
$switches = [ordered]@{
    'gpl'      = @{ NXRT_NVN_GPL = 'false' }
    'prewarm'  = @{ NXRT_NVN_PREWARM = 'false' }
    'split'    = @{ NXRT_NVN_SPLIT_SUBMIT_MS = '0' }
    'inflight' = @{ NXRT_GFX_FRAMES_IN_FLIGHT = '1' }
    'barriers' = @{ NXRT_NVN_LEAN_BARRIERS = 'false'; NXRT_NVN_PASS_BARRIERS = 'full' }
    'igpu'     = @{ NXRT_GFX_IGPU_COMPAT = '1' }
    'compute'  = @{ NXRT_NVN_COMPUTE_ASYNC = 'off'; NXRT_NVN_COMPUTE_SHADOWS = 'false' }
    'memory'   = @{ NXRT_GFX_PAGEABLE_MEMORY = 'false'; NXRT_GFX_AMD_OVERALLOCATION = 'false' }
    'submit'   = @{ NXRT_NVN_SUBMIT_BATCH = 'frame' }
    'fse'      = @{ NXRT_GFX_FSE_EXTENSION = 'false' }
    'capture'  = @{ NXRT_GFX_SWAPCHAIN_CAPTURE = 'false' }
    'images'   = @{ NXRT_GFX_SWAPCHAIN_IMAGES = '6' }
}
$allEnv = @{}
foreach ($k in $switches.Keys) { foreach ($e in $switches[$k].Keys) { $allEnv[$e] = $true } }

# --- machine facts ---------------------------------------------------------------------------------------------------------------------
Say ('Windowed bisect, ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ', ' + $Seconds + ' s per run')
try { Get-CimInstance Win32_VideoController | ForEach-Object { Say ('GPU: ' + $_.Name + ', driver ' + $_.DriverVersion + ', ' + $_.DriverDate) } } catch { Say 'GPU: could not be read' }
try {
    $h = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction Stop).HwSchMode
    Say ('Hardware-accelerated GPU scheduling (HwSchMode): ' + $h + ' (2 = on, 1 = off)')
} catch { Say 'Hardware-accelerated GPU scheduling: not readable' }
$start = Get-Date

# --- the diagnostic runtime: fefw_rt_diag.dll (if it came with this script) stands in for fefw_rt.dll while the tests run -------------------------
# The original is kept as fefw_rt.dll.orig and put back at the end (also when the run is cut short: the next start puts it back first).
$rt = Join-Path $PSScriptRoot 'fefw_rt.dll'
$rtDiag = Join-Path $PSScriptRoot 'fefw_rt_diag.dll'
$rtOrig = Join-Path $PSScriptRoot 'fefw_rt.dll.orig'
if (Test-Path -LiteralPath $rtOrig) { Copy-Item -LiteralPath $rtOrig -Destination $rt -Force; Remove-Item -LiteralPath $rtOrig -Force }
$swapped = $false
if ((Test-Path -LiteralPath $rtDiag) -and (Test-Path -LiteralPath $rt)) {
    Copy-Item -LiteralPath $rt -Destination $rtOrig -Force
    Copy-Item -LiteralPath $rtDiag -Destination $rt -Force
    $swapped = $true
    Say 'Using the diagnostic runtime (fefw_rt_diag.dll).'
} elseif (Test-Path -LiteralPath $rtDiag) {
    Say 'fefw_rt_diag.dll is here but fefw_rt.dll was not found next to fefw.exe: the normal runtime is used (the three "fse", "capture", "images" switches do nothing).'
}

try {
# --- cleaned copies of the settings ----------------------------------------------------------------------------------------------------
$strip = @('pageable_memory','amd_overallocation','submit_batch','frame_gen','present_mode','igpu_compat','gpl','prewarm','split_submit_ms',
           'frames_in_flight','lean_barriers','pass_barriers','lean_draws','residency','compute_shadows','compute_async','fse_extension',
           'swapchain_capture','swapchain_images','dispatch_barriers','game_barriers')
$srcIni = if (Test-Path -LiteralPath 'fefw.ini') { 'fefw.ini' } else { 'nxrt.ini' }
$cleanIni = Join-Path $PSScriptRoot 'bisect.ini'
if (Test-Path -LiteralPath $srcIni) {
    Get-Content -LiteralPath $srcIni | Where-Object {
        $key = ($_ -split '=', 2)[0].Trim().ToLowerInvariant()
        -not ($_ -match '=' -and ($strip -contains $key))
    } | Set-Content -LiteralPath $cleanIni
} else { Set-Content -LiteralPath $cleanIni -Value '' }

$ctl = Join-Path $PSScriptRoot 'bisect_controls.ini'
$lines = @()
if (Test-Path -LiteralPath 'controls.ini') { $lines = @(Get-Content -LiteralPath 'controls.ini') }
$hit = $false
$lines = $lines | ForEach-Object { if ($_ -match '^\s*window_mode\s*=') { $hit = $true; 'window_mode = windowed' } else { $_ } }
if (-not $hit) { $lines = @($lines) + @('', '[display]', 'window_mode = windowed') }
Set-Content -LiteralPath $ctl -Value $lines

# --- one run ---------------------------------------------------------------------------------------------------------------------------
$runNo = 0
function Run-Game([string]$label, [string[]]$on, [string]$ini) {
    $script:runNo++
    $tag = ('run{0:D2}_{1}' -f $script:runNo, ($label -replace '[^A-Za-z0-9_+-]', '_'))
    $log = Join-Path $out ($tag + '.log')
    foreach ($e in $allEnv.Keys) { Remove-Item -LiteralPath ('Env:' + $e) -ErrorAction SilentlyContinue }
    foreach ($s in $on) { foreach ($e in $switches[$s].Keys) { Set-Item -LiteralPath ('Env:' + $e) -Value $switches[$s][$e] } }
    $env:NXRT_PLAY_CONTROLS = $ctl
    $before = Get-Date
    Write-Host ('  run {0}: {1} ... ' -f $script:runNo, $label) -NoNewline
    $p = Start-Process -FilePath $exe -ArgumentList @('--ini', ('"' + $ini + '"'), '--log', ('"' + $log + '"'), '--max-seconds', $Seconds) -PassThru -WorkingDirectory $PSScriptRoot
    if (-not $p.WaitForExit(($Seconds + 90) * 1000)) { try { $p.Kill() } catch {}; $hung = $true } else { $hung = $false }
    Start-Sleep -Milliseconds 800
    Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*crash*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $before } |
        ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination (Join-Path $out ($tag + '_' + $_.Name)) -Force }
    $text = ''
    if (Test-Path -LiteralPath $log) { $text = Get-Content -LiteralPath $log -Raw }
    $lost = $text -match 'DEVICE LOST|first Vulkan failure'
    $alive = ($text -match 'max_seconds reached') -and ($text -match 'first frame presented')
    $ok = $alive -and (-not $lost) -and (-not $hung)
    $why = if ($ok) { 'survived' } elseif ($lost) { 'GPU DEVICE LOST' } elseif ($hung) { 'hung, killed' } elseif ($text -notmatch 'first frame presented') { 'no frame presented' } else { 'ended early' }
    if ($ok) { Write-Host 'survived' -ForegroundColor Green } else { Write-Host $why -ForegroundColor Yellow }
    Add-Content -LiteralPath $summary -Value ('run {0}: {1} [{2}] -> {3}' -f $script:runNo, $label, ($on -join ','), $why)
    foreach ($e in $allEnv.Keys) { Remove-Item -LiteralPath ('Env:' + $e) -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2    # let the driver settle after a reset
    return $ok
}

Write-Host ''
Write-Host 'The game window opens and closes by itself several times. Please do not touch the keyboard or mouse until this window says it is done (about 10 minutes).' -ForegroundColor Cyan
Write-Host ''

$verdict = ''
$needed = @()
$base = Run-Game 'baseline (clean config)' @() $cleanIni
if ($base) {
    $verdict = 'The game SURVIVED windowed with a clean config. The failure needs something in your own fefw.ini / controls.ini. Trying them as they are:'
    Say $verdict 'Cyan'
    $mine = Run-Game 'your own fefw.ini' @() $srcIni
    if ($mine) { $verdict = 'It also survived with your own fefw.ini: could not reproduce the device loss in this session.' } else { $verdict = 'Your own fefw.ini loses the device but the cleaned copy does not: a setting in it is the trigger (bisect.ini in the zip is the cleaned copy).' }
} else {
    $all = @($switches.Keys)
    $full = Run-Game 'everything on' $all $cleanIni
    if (-not $full) {
        $verdict = 'The device is lost even with every workaround on: none of these switches helps. This points at the graphics driver (amdkmdag).'
    } else {
        $needed = @($all)
        foreach ($s in $all) {
            $try = @($needed | Where-Object { $_ -ne $s })
            if ((Run-Game ('without ' + $s) $try $cleanIni)) { $needed = $try }
        }
        Say ('Smallest set that keeps it alive: ' + ($needed -join ', ')) 'Cyan'
        $verdict = 'Needed switches: ' + ($needed -join ', ')
        $again = Run-Game 'final set, repeat' $needed $cleanIni
        if (-not $again) { $verdict += ' (a repeat of the final set lost the device: the result is not stable)' }
    }
}

Say ''
Say ('RESULT: ' + $verdict) 'Cyan'
try {
    $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 4101; StartTime = $start } -ErrorAction Stop
    Say ('Display driver timeout events (Display 4101) during the test: ' + @($ev).Count)
} catch { Say 'Display driver timeout events (Display 4101) during the test: 0' }
try {
    $dumps = @(Get-ChildItem 'C:\Windows\LiveKernelReports\WATCHDOG' -Filter '*.dmp' -ErrorAction Stop | Where-Object { $_.LastWriteTime -ge $start })
    Say ('GPU watchdog dumps made during the test: ' + $dumps.Count)
    foreach ($d in $dumps) { Say ('   ' + $d.Name) }
} catch { Say 'GPU watchdog dumps: folder not readable (needs administrator), not counted' }

Copy-Item -LiteralPath $cleanIni -Destination (Join-Path $out 'bisect.ini') -Force
Copy-Item -LiteralPath $ctl -Destination (Join-Path $out 'bisect_controls.ini') -Force
$zip = Join-Path $PSScriptRoot 'bisect_result.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip
Write-Host ''
Write-Host ('Done. Please attach this file to the GitHub issue: ' + $zip) -ForegroundColor Green

} finally {
    if ($swapped) {
        Copy-Item -LiteralPath $rtOrig -Destination $rt -Force
        Remove-Item -LiteralPath $rtOrig -Force
        Write-Host 'The original fefw_rt.dll was put back.'
    }
}
