# Generates the evaluation fixtures used by run_eval.ps1. Deterministic
# testsrc2 patterns keep runs comparable; H.264 High guarantees hardware
# decode availability on any GPU from the last decade.
#
# Usage: powershell -NoProfile -File tools/perf/make_fixtures.ps1
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$fixtures = Join-Path $repoRoot "tools\perf\fixtures"
New-Item -ItemType Directory -Path $fixtures -Force | Out-Null

$ffmpeg = "ffmpeg"  # must be on PATH

$jobs = @(
  @{
    out    = "sample_1080p60_h264.mp4"
    size   = "1920x1080"
    rate   = 60
    seconds = 90
    extra  = @("-profile:v", "high", "-level", "4.2")
  },
  @{
    out    = "sample_4k30_h264.mp4"
    size   = "3840x2160"
    rate   = 30
    seconds = 60
    extra  = @("-profile:v", "high", "-level", "5.1")
  }
)

foreach ($job in $jobs) {
  $outPath = Join-Path $fixtures $job.out
  if (Test-Path $outPath) {
    Write-Host "exists, skipping: $outPath"
    continue
  }
  Write-Host "generating $($job.out) ..."
  & $ffmpeg -y `
    -f lavfi -i "testsrc2=size=$($job.size):rate=$($job.rate)" `
    -f lavfi -i "sine=frequency=440:sample_rate=48000" `
    -t $job.seconds `
    -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p @($job.extra) `
    -c:a aac -b:a 192k `
    -movflags +faststart `
    $outPath
  if ($LASTEXITCODE -ne 0) { Write-Error "ffmpeg failed for $($job.out)" }
}
Write-Host "fixtures ready in $fixtures"
