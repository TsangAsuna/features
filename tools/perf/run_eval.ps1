# Orchestrates one NipaPlay pre-delivery evaluation run (see tools/perf/README.md):
# launches the built player with a fixture, samples system-side metrics, stops
# the app, and writes run metadata. Analyze afterwards with:
#   python tools/perf/analyze_perf.py <out-dir>
#
# Usage (from repo root):
#   powershell -NoProfile -File tools/perf/run_eval.ps1 -Seconds 60 -Kernel mdk
#   powershell -NoProfile -File tools/perf/run_eval.ps1 -Fixture <abs path to a video> -Label my-change
param(
  [string]$Fixture = "",
  [int]$Seconds = 60,
  [string]$OutDir = "",
  [string]$Kernel = "",     # optional: mdk | mediaKit | videoPlayer | erika
  [string]$ExePath = "",    # default: build/windows/x64/runner/Profile/nipaplay.exe
  [string]$Label = "",
  [int]$StartupSettleSeconds = 10,
  [string]$SubtitlePath = "",       # eval hook: auto-attach an external subtitle
  [int]$SynthDanmaku = 0,           # eval hook: inject N synthetic danmaku
  [int]$DanmakuOffAt = 0,           # eval hook: toggle danmaku off at N sec
  [int]$DanmakuOnAt = 0             # eval hook: toggle danmaku back on at N sec
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

if (-not $ExePath) {
  $ExePath = Join-Path $repoRoot "build\windows\x64\runner\Profile\nipaplay.exe"
}
if (-not (Test-Path $ExePath)) {
  Write-Error "player exe not found: $ExePath — build it first: flutter build windows --profile"
  return
}
if (-not $Fixture) {
  $Fixture = Join-Path $repoRoot "tools\perf\fixtures\sample_1080p60_h264.mp4"
}
$Fixture = [IO.Path]::GetFullPath($Fixture)
if (-not (Test-Path $Fixture)) {
  Write-Error "fixture not found: $Fixture — generate with tools/perf/make_fixtures.ps1"
  return
}

if (Get-Process -Name "nipaplay" -ErrorAction SilentlyContinue) {
  Write-Error "a nipaplay instance is already running; close it first (the app forwards launches to the primary instance)."
  return
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$suffix = if ($Label) { "-$Label" } elseif ($Kernel) { "-$Kernel" } else { "" }
if (-not $OutDir) { $OutDir = Join-Path $repoRoot "tools\perf\out" }
$runDir = Join-Path $OutDir "$stamp$suffix"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $ExePath
$psi.Arguments = "`"$Fixture`""
$psi.WorkingDirectory = Split-Path -Parent $ExePath
$psi.UseShellExecute = $false
$psi.EnvironmentVariables['NIPAPLAY_PERF_LOG'] = Join-Path $runDir "playback.jsonl"
if ($Kernel) { $psi.EnvironmentVariables['NIPAPLAY_FORCE_KERNEL'] = $Kernel }
if ($SubtitlePath) { $psi.EnvironmentVariables['NIPAPLAY_EVAL_SUBTITLE'] = [IO.Path]::GetFullPath($SubtitlePath) }
if ($SynthDanmaku -gt 0) { $psi.EnvironmentVariables['NIPAPLAY_EVAL_SYNTH_DANMAKU'] = "$SynthDanmaku" }
if ($DanmakuOffAt -gt 0) { $psi.EnvironmentVariables['NIPAPLAY_EVAL_DANMAKU_OFF_AT'] = "$DanmakuOffAt" }
if ($DanmakuOnAt -gt 0) { $psi.EnvironmentVariables['NIPAPLAY_EVAL_DANMAKU_ON_AT'] = "$DanmakuOnAt" }

Write-Host "launching $ExePath"
Write-Host "  fixture: $Fixture"
Write-Host "  kernel:  $(if ($Kernel) { $Kernel } else { '<user setting>' })"
Write-Host "  output:  $runDir"
$proc = [System.Diagnostics.Process]::Start($psi)

Start-Sleep -Seconds 5
if ($proc.HasExited) {
  Write-Error "player exited during startup (exit code $($proc.ExitCode)) — is another instance running, or did startup fail?"
  return
}

Write-Host "sampling $Seconds seconds (startup settle ${StartupSettleSeconds}s)..."
Start-Sleep -Seconds $StartupSettleSeconds
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "capture_perf.ps1") `
  -ProcessName "nipaplay" -Seconds $Seconds -IntervalMs 1000 `
  -Out (Join-Path $runDir "perf.jsonl")

if (-not $proc.HasExited) {
  [void]$proc.CloseMainWindow()
  if (-not $proc.WaitForExit(5000)) {
    Stop-Process -Id $proc.Id -Force
  }
} else {
  $proc.Refresh()
}
# Dispose（大弹幕列表、字幕缓存释放）会让退出变慢；单实例守卫会拒绝下一个
# run，所以必须等进程真正消失（再给目录句柄释放留时间）。
$exitDeadline = [DateTime]::UtcNow.AddSeconds(20)
while ([DateTime]::UtcNow -lt $exitDeadline) {
  if (-not (Get-Process -Name "nipaplay" -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 500
}
$lingering = Get-Process -Name "nipaplay" -ErrorAction SilentlyContinue
if ($lingering) {
  Write-Warning "nipaplay 仍在运行，强制结束: $($lingering.Id -join ', ')"
  $lingering | Stop-Process -Force
  Start-Sleep -Seconds 2
}

$meta = [ordered]@{
  fixture        = $Fixture
  seconds        = $Seconds
  kernelOverride = $Kernel
  label          = $Label
  subtitlePath   = $SubtitlePath
  synthDanmaku   = $SynthDanmaku
  danmakuOffAt   = $DanmakuOffAt
  danmakuOnAt    = $DanmakuOnAt
  exePath        = $ExePath
  exeBuiltUtc    = (Get-Item $ExePath).LastWriteTimeUtc.ToString('o')
  gitRev         = $null
  gpus           = @()
}
try {
  $meta.gitRev = (git -C $repoRoot rev-parse HEAD)
} catch {}
try {
  $meta.gpus = @(Get-CimInstance Win32_VideoController |
    Where-Object { $_.Name -notmatch 'Virtual|IddDriver|Display Adapter$' } |
    ForEach-Object { $_.Name })
} catch {}
$meta | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $runDir "meta.json") -Encoding UTF8

Write-Host ""
Write-Host "run captured. summarize with:"
Write-Host "  python tools/perf/analyze_perf.py $runDir"
