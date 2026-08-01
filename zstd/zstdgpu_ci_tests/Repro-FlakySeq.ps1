<#
.SYNOPSIS
  Repro harness for the flaky GPU sequence-decode validation failures observed on
  the GTX 1060 (Pascal) lab machine.

.DESCRIPTION
  Replays the exact zstdgpu_demo.exe invocations that failed in the back-to-back
  CI runs (logs 109.txt / 109_1.txt) and loops the whole group N times to surface
  the NON-DETERMINISTIC failure. A single run frequently passes, so looping is
  required to get a "consistent" repro for iterating on a fix.

  Root cause under investigation (#1): a cross-thread-group race in the decoupled-
  lookback sequence-offset prefix scan (ZstdGpuPrefixSequenceOffsets.hlsl). It is
  Pascal-sensitive and flips between content/scenarios from run to run. The stable
  GBV TDR on robotbug_eyeBlinn_normal (root cause #2) is intentionally EXCLUDED.

  A run counts as FAILED when the demo exits non-zero (a validation assert exits
  with code 1) or times out (possible TDR / device hang).

.PARAMETER DemoPath
  Full path to zstdgpu_demo.exe. Default matches the lab agent layout.

.PARAMETER ContentRoot
  Root folder containing the .zst content tree. Default matches the lab.

.PARAMETER Iterations
  Number of times to run the whole group. Default 10.

.PARAMETER Scenario
  Optional. When set (e.g. '--chk-gpu --seq-cnt'), OVERRIDES the per-content
  scenario flags and runs EVERY listed content under this one scenario. Handy to
  force all content through a single code path for wider exposure.

.PARAMETER TimeoutSec
  Per-run timeout in seconds. Default 180. A timeout is treated as a failure.

.PARAMETER OutDir
  Folder for per-failure stdout logs. Default: <script dir>\repro_out.

.EXAMPLE
  .\Repro-FlakySeq.ps1
  .\Repro-FlakySeq.ps1 -Iterations 20
  .\Repro-FlakySeq.ps1 -DemoPath C:\path\zstdgpu_demo.exe -ContentRoot C:\path\zstd_content
  .\Repro-FlakySeq.ps1 -Scenario '--chk-gpu --seq-cnt'
#>
[CmdletBinding()]
param(
    [string]$DemoPath    = 'C:\agent\_work\2\artifacts\zstdgpu_demo.exe',
    [string]$ContentRoot = 'C:/agent/data/zstd_content',
    [int]   $Iterations  = 10,
    [string]$Scenario    = '',
    [int]   $TimeoutSec  = 180,
    [string]$OutDir      = ''
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# The group of failing content (root cause #1: flaky sequence validation).
# Observed across CI logs 109.txt (5 fails) and 109_1.txt (7 fails); the two
# runs failed on DISJOINT content, so the union is listed here. Each entry
# replays the exact scenario that failed for that content. Add rows or pass
# -Scenario to broaden coverage.
# ---------------------------------------------------------------------------
$Group = @(
    [pscustomobject]@{ Label='GpuCheck';           RelPath='internal\insects\BC5mip0\yellow_ladybug_outShell_normal.DDS.zst'; Flags='--chk-gpu' }
    [pscustomobject]@{ Label='D3D12DebugLayer';    RelPath='internal\insects\BC5mip0\redLadybug_outShell_normal.DDS.zst';     Flags='--chk-gpu --d3d-dbg' }
    [pscustomobject]@{ Label='D3D12DebugLayer';    RelPath='internal\insects\BC7mip0\BC7mip0_part14.DDS.zst';                 Flags='--chk-gpu --d3d-dbg' }
    [pscustomobject]@{ Label='GpuCheck';           RelPath='internal\insects\BC7mip0\BC7mip0_part02.DDS.zst';                 Flags='--chk-gpu' }
    [pscustomobject]@{ Label='GpuCheck';           RelPath='internal\insects\BC7mip0\BC7mip0_part03.DDS.zst';                 Flags='--chk-gpu' }
    [pscustomobject]@{ Label='GpuCheck';           RelPath='internal\insects\BC7mip0\BC7mip0_part17.DDS.zst';                 Flags='--chk-gpu' }
    [pscustomobject]@{ Label='GpuCheckSeq';        RelPath='internal\insects\BC7\Assets_4c\LargeRocks_albedo.DDS.zst';        Flags='--chk-gpu --seq-cnt' }
    [pscustomobject]@{ Label='ExternalMemory';     RelPath='public\silesia\samba.zst';                                       Flags='--chk-gpu --ext-mem' }
    [pscustomobject]@{ Label='SimulationCheckSeq'; RelPath='internal\insects\BC1mip0\BC1mip0_part02.DDS.zst';                Flags='--chk-gpu --chk-cpu --sim-gpu --seq-cnt' }
)

# Global flags the CI harness prepends to every correctness invocation.
$GlobalFlags = '--run-cnt 1 --idx-max 200'

# ---------------------------------------------------------------------------
function Invoke-Demo
{
    param([string]$Exe, [string]$ArgLine, [int]$Timeout)

    # NOTE: use System.Diagnostics.Process directly rather than Start-Process.
    # Start-Process -PassThru does NOT reliably populate .ExitCode on all
    # machines/PowerShell versions (it needs the process Handle cached first),
    # which shows up as an empty "exit=" and every run being miscounted as a
    # failure. The raw Process object reports ExitCode reliably after WaitForExit.
    $timedOut = $false
    $exit = $null
    $out = ''
    try
    {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $Exe
        $psi.Arguments              = $ArgLine
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true

        $p = [System.Diagnostics.Process]::Start($psi)

        # Drain both streams concurrently so a full pipe buffer can't deadlock
        # the child while we wait for it to exit.
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        if (-not $p.WaitForExit($Timeout * 1000))
        {
            $timedOut = $true
            try { $p.Kill() } catch { }
            $p.WaitForExit()
        }

        $exit = $p.ExitCode
        $out  = $outTask.Result + $errTask.Result
        $p.Dispose()
    }
    catch
    {
        $exit = -998
        $out  = $_.Exception.Message
    }

    return [pscustomobject]@{ ExitCode = $exit; TimedOut = $timedOut; Output = $out }
}

# ---------------------------------------------------------------------------
if ($OutDir -eq '')
{
    $base = $PSScriptRoot
    if (-not $base) { $base = (Get-Location).Path }
    $OutDir = Join-Path $base 'repro_out'
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

if (-not (Test-Path -LiteralPath $DemoPath))
{
    Write-Host ("ERROR: demo not found: {0}" -f $DemoPath) -ForegroundColor Red
    Write-Host "Pass -DemoPath <full path to zstdgpu_demo.exe>."
    exit 2
}

$root = $ContentRoot.TrimEnd('/', '\')

Write-Host "zstdgpu flaky-sequence repro harness" -ForegroundColor Cyan
Write-Host ("  Demo        : {0}" -f $DemoPath)
Write-Host ("  ContentRoot : {0}" -f $root)
Write-Host ("  Iterations  : {0}" -f $Iterations)
Write-Host ("  Timeout/run : {0}s" -f $TimeoutSec)
if ($Scenario -ne '') { Write-Host ("  Scenario    : (override) {0}" -f $Scenario) -ForegroundColor Yellow }
Write-Host ("  Fail logs   : {0}" -f $OutDir)

# Per-content stats keyed by RelPath (each file is unique).
$stats = [ordered]@{}
foreach ($e in $Group) { $stats[$e.RelPath] = [pscustomobject]@{ Label = $e.Label; RelPath = $e.RelPath; Runs = 0; Fails = 0; Missing = $false } }

$startTime = Get-Date

for ($i = 1; $i -le $Iterations; $i++)
{
    Write-Host ""
    Write-Host ("===== Pass {0}/{1} =====" -f $i, $Iterations) -ForegroundColor Cyan
    foreach ($e in $Group)
    {
        $s = $stats[$e.RelPath]
        $zst = $root + '\' + $e.RelPath
        if (-not (Test-Path -LiteralPath $zst))
        {
            if (-not $s.Missing) { Write-Host ("  [MISSING] {0}" -f $zst) -ForegroundColor Yellow }
            $s.Missing = $true
            continue
        }

        $flags = $e.Flags
        if ($Scenario -ne '') { $flags = $Scenario }
        $argLine = ('--zst "{0}" {1} {2}' -f $zst, $GlobalFlags, $flags)

        $r = Invoke-Demo -Exe $DemoPath -ArgLine $argLine -Timeout $TimeoutSec
        $s.Runs++

        $tag = "exit=$($r.ExitCode)"
        $failed = $true
        if ($r.TimedOut) { $tag = 'TIMEOUT' }
        elseif ($null -eq $r.ExitCode) { $tag = 'NO-EXIT-CODE' }
        elseif ($r.ExitCode -eq 0) { $failed = $false }

        if ($failed)
        {
            $s.Fails++
            Write-Host ("  [FAIL {0}] {1,-18} {2}" -f $tag, $e.Label, $e.RelPath) -ForegroundColor Red
            $safe = ($e.RelPath -replace '[\\/:]', '_')
            $logPath = Join-Path $OutDir ('fail_{0}_{1}_pass{2}.log' -f $e.Label, $safe, $i)
            Set-Content -LiteralPath $logPath -Value ("CMD: `"{0}`" {1}`r`n`r`n{2}" -f $DemoPath, $argLine, $r.Output)
        }
        else
        {
            Write-Host ("  [ ok ]      {0,-18} {1}" -f $e.Label, $e.RelPath) -ForegroundColor DarkGray
        }
    }
}

$elapsed = (Get-Date) - $startTime

Write-Host ""
Write-Host "================ SUMMARY ================" -ForegroundColor Cyan
$totRuns = 0
$totFails = 0
foreach ($k in $stats.Keys)
{
    $s = $stats[$k]
    if ($s.Missing)
    {
        Write-Host ("  MISSING  {0,-18} {1}" -f $s.Label, $s.RelPath) -ForegroundColor Yellow
        continue
    }
    $totRuns += $s.Runs
    $totFails += $s.Fails
    $col = 'Green'
    if ($s.Fails -gt 0) { $col = 'Red' }
    Write-Host ("  {0,3}/{1,-3} fails  {2,-18} {3}" -f $s.Fails, $s.Runs, $s.Label, $s.RelPath) -ForegroundColor $col
}
Write-Host "  ----------------------------------------"
$col = 'Green'
if ($totFails -gt 0) { $col = 'Red' }
Write-Host ("  TOTAL: {0}/{1} runs failed   (elapsed {2:mm\:ss})" -f $totFails, $totRuns, $elapsed) -ForegroundColor $col
if ($totFails -gt 0) { Write-Host ("  Failure logs saved to: {0}" -f $OutDir) }

if ($totFails -gt 0) { exit 1 } else { exit 0 }
