[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DemoPath,
    [Parameter(Mandatory)][string]$ListPath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$files = @([IO.File]::ReadAllLines($ListPath) | Where-Object { $_.Trim().Length })
if ($files.Count -ne 7) { throw 'Expected all seven decisive files' }
$cases = @()
for ($i = 0; $i -lt $files.Count; ++$i) {
    $file = $files[$i]
    $prefix = Join-Path $OutputDirectory "cpu-case-$i"
    $arguments = @('--zst', $file, '--run-cnt', '1', '--prf-lvl', '0', '--chk-cpu', '--chk-gpu', '--sim-gpu')
    $quoted = @($arguments | ForEach-Object {
        if ($_ -match '"') { throw 'Quotes in arguments unsupported' }
        '"' + $_ + '"'
    }) -join ' '
    $started = [DateTime]::UtcNow
    $process = Start-Process $DemoPath -ArgumentList $quoted -WorkingDirectory (Split-Path $DemoPath -Parent) `
        -RedirectStandardOutput "$prefix.stdout.txt" -RedirectStandardError "$prefix.stderr.txt" -PassThru
    $retainedHandle = $process.Handle
    if (-not $process.WaitForExit(300000)) {
        Stop-Process -Id $process.Id -Force
        throw "CPU case $i timed out; only its owned process was stopped"
    }
    $process.WaitForExit()
    $rc = $process.ExitCode
    if ($null -eq $rc) { throw 'CPU case lost process exit code' }
    $stdout = Get-Content "$prefix.stdout.txt" -Raw
    $stderr = if ((Get-Item "$prefix.stderr.txt").Length) { Get-Content "$prefix.stderr.txt" -Raw } else { '' }
    $passed = $rc -eq 0 -and $stdout -cmatch 'Running GPU Decompression code on CPU' -and
        $stdout -cmatch "Option '--sim-gpu' was set" -and $stdout -cmatch '\[PERF\] total batches=1 ' -and
        ($stdout + $stderr) -cnotmatch '\[FAIL\]|Error:|error: |mismatch|DEVICE_REMOVED'
    $cases += [ordered]@{ index = $i; file = $file; arguments = $arguments; processExitCode = $rc; passed = $passed
        startedUtc = $started.ToString('o'); completedUtc = [DateTime]::UtcNow.ToString('o')
        stdoutSha256 = (Get-FileHash "$prefix.stdout.txt" -Algorithm SHA256).Hash
        stderrSha256 = (Get-FileHash "$prefix.stderr.txt" -Algorithm SHA256).Hash }
    Write-Output "CPU_CASE $i FILE=$file PASSED=$passed EXIT=$rc"
    Write-Output $stdout
    if ($stderr) { Write-Output $stderr }
}
$cases | ConvertTo-Json -Depth 6 | Set-Content "$OutputDirectory\cpu-cases.json" -Encoding UTF8
$passedCount = @($cases | Where-Object passed).Count
Write-Output "CPU_CASES_PASSED=$passedCount"
if ($passedCount -ne 7) { exit 1 }
exit 0
