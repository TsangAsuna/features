# External-side performance sampler for the NipaPlay pre-delivery evaluation
# rig (see tools/perf/README.md). Samples OS-level metrics for the player
# process and appends one JSON line per process per sample: CPU%, working
# set, private bytes, per-engine GPU utilization (3D / videodecode / ...) and
# per-process GPU memory (dedicated + shared), all in bytes.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/perf/capture_perf.ps1 `
#     -ProcessName nipaplay -Seconds 60 -IntervalMs 1000 -Out tools/perf/out/<run>/perf.jsonl
#
# Notes:
# - GPU counters come from Get-Counter (\GPU Engine / \GPU Process Memory).
#   The Win32_Perf* GPUPerformanceCounters WMI classes return cooked values
#   of 0 on this machine, so they are not used.
# - The three counter paths are read in ONE Get-Counter call: on this box a
#   full \GPU Engine wildcard enumeration takes seconds, so a per-path call
#   would stretch each loop to ~4.5s. If a loop still overruns IntervalMs,
#   CPU% is normalized against the measured elapsed time, not IntervalMs.
# - Engine keys are emitted lowercase (videodecode/3d/...); analyze_perf.py
#   matches case-insensitively.
param(
  [string]$ProcessName = "nipaplay",
  [int]$Seconds = 60,
  [int]$IntervalMs = 1000,
  [Parameter(Mandatory = $true)][string]$Out
)

$ErrorActionPreference = 'SilentlyContinue'

$outDir = Split-Path -Parent $Out
if ($outDir -and !(Test-Path $outDir)) {
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$cores = [Environment]::ProcessorCount
$deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
$prevCpu = @{}
$buffer = New-Object System.Text.StringBuilder
$counterPaths = @(
  '\GPU Engine(*)\Utilization Percentage',
  '\GPU Process Memory(*)\Dedicated Usage',
  '\GPU Process Memory(*)\Shared Usage'
)

while ([DateTime]::UtcNow -lt $deadline) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $ts = [DateTime]::UtcNow.ToString('o')
  $procs = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { -not $_.HasExited })
  $pidSet = @($procs | ForEach-Object { $_.Id })

  $engineUtil = @{}
  $vram = @{}
  if ($pidSet.Count -gt 0) {
    $samples = @(Get-Counter -Counter $counterPaths -ErrorAction SilentlyContinue).CounterSamples
    foreach ($s in $samples) {
      $path = $s.Path
      if ($path -like '*\gpu engine*utilization percentage*') {
        if ($s.InstanceName -match '^pid_(\d+)_.*engtype_([a-z0-9]+)$') {
          if ($pidSet -contains [int]$Matches[1]) {
            $key = "$($Matches[1])|$($Matches[2])"
            $engineUtil[$key] = $engineUtil[$key] + $s.CookedValue
          }
        }
      } elseif ($path -like '*\gpu process memory*dedicated usage*') {
        if ($s.InstanceName -match '^pid_(\d+)_' -and ($pidSet -contains [int]$Matches[1])) {
          $vram["$($Matches[1])|ded"] += $s.CookedValue
        }
      } elseif ($path -like '*\gpu process memory*shared usage*') {
        if ($s.InstanceName -match '^pid_(\d+)_' -and ($pidSet -contains [int]$Matches[1])) {
          $vram["$($Matches[1])|sh"] += $s.CookedValue
        }
      }
    }
  }

  foreach ($p in $procs) {
    $pidKey = "$($p.Id)"
    $cpuNow = $p.TotalProcessorTime.TotalSeconds
    $cpuDelta = 0.0
    if ($prevCpu.ContainsKey($pidKey)) { $cpuDelta = $cpuNow - $prevCpu[$pidKey] }
    $prevCpu[$pidKey] = $cpuNow
    # Normalize against the real elapsed time: GPU counter enumeration can
    # overrun IntervalMs substantially on this machine.
    $elapsedSec = [math]::Max($sw.Elapsed.TotalSeconds, 0.05)
    $cpuPct = [math]::Round(100.0 * $cpuDelta / ($cores * $elapsedSec), 1)

    $engines = @{}
    foreach ($k in $engineUtil.Keys) {
      if ($k.StartsWith("$pidKey|")) {
        $engines[($k.Split('|')[1])] = [math]::Round($engineUtil[$k], 1)
      }
    }

    $record = [ordered]@{
      t            = $ts
      pid          = $p.Id
      procName     = $p.Name
      cpuPct       = $cpuPct
      sampleSec    = [math]::Round($sw.Elapsed.TotalSeconds, 2)
      workingSet   = [double]$p.WorkingSet64
      privateBytes = [double]$p.PrivateMemorySize64
      gpuEngines   = $engines
      gpuDedicated = [double]$vram["$pidKey|ded"]
      gpuShared    = [double]$vram["$pidKey|sh"]
      threads      = $p.Threads.Count
    }
    [void]$buffer.AppendLine(($record | ConvertTo-Json -Compress -Depth 5))
  }

  if ($buffer.Length -gt 0) {
    [IO.File]::AppendAllText($Out, $buffer.ToString())
    [void]$buffer.Clear()
  }
  $remain = $IntervalMs - $sw.ElapsedMilliseconds
  if ($remain -gt 0) { Start-Sleep -Milliseconds $remain }
}
