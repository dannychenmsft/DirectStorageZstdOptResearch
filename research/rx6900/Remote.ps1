[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Inventory', 'Health', 'CheckDeploy', 'Verify', 'Run', 'Profile')][string]$Action,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$Arm,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$RunId,
    [ValidateSet('Perf', 'Correctness', 'Debug')][string]$Kind = 'Perf',
    [string]$Content = 'C:\agent\data\zstd_content',
    [string]$ExpectedManifestSha256,
    [int]$ProfileRung = 256
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
if (($Action -eq 'Run' -and $Kind -eq 'Perf') -or $Action -eq 'Profile') {
    $pauseFile = Join-Path $root 'pause-before-perf.json'
    if (Test-Path -LiteralPath $pauseFile) {
        $pause = Get-Content -LiteralPath $pauseFile -Raw | ConvertFrom-Json
        throw "Coordinator paused new measurements at a completed-ladder boundary: $($pause.reason)"
    }
}
function Save-Json($Value, $Path) { $Value | ConvertTo-Json -Depth 12 | Set-Content $Path -Encoding UTF8 }
function Get-Corpus {
    $files = @(Get-ChildItem $Content -Recurse -File -Filter *.zst | Sort-Object FullName)
    if ($files.Count -ne 298) { throw "Expected 298 .zst files, found $($files.Count)" }
    $entries = @($files) + @(Get-Item "$Content\perf_manifest.json", "$Content\adversarial_manifest.json")
    return @($entries | ForEach-Object {
        [ordered]@{ name = $_.FullName.Substring($Content.TrimEnd('\').Length + 1)
            bytes = $_.Length; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
    })
}
function Get-Health {
    $before = @{}
    Get-Process | ForEach-Object { if ($null -ne $_.CPU) { $before[$_.Id] = $_.CPU } }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds 3
    $logical = [Environment]::ProcessorCount
    $active = @(Get-Process | ForEach-Object {
        if ($before.ContainsKey($_.Id) -and $null -ne $_.CPU) {
            [pscustomobject]@{ pid = $_.Id; name = $_.Name
                cpuPercent = [Math]::Max(0.0, 100.0 * ($_.CPU - $before[$_.Id]) / $clock.Elapsed.TotalSeconds / $logical) }
        }
    } | Sort-Object cpuPercent -Descending)
    $gpuCounters = @()
    $gpuCounterError = $null
    try {
        $gpuCounters = @((Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples |
            Where-Object CookedValue -GT 0.1 | Select-Object InstanceName, CookedValue)
    } catch { $gpuCounterError = $_.Exception.Message }
    $conflicts = @(Get-Process | Where-Object { $_.Name -match '^(Agent\.Worker|zstdgpu_demo|zstdgpu_ci_tests|dxc|MSBuild)$' } |
        Select-Object Id, Name)
    [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); logicalProcessors = $logical
        cpuTotalPercent = ($active | Measure-Object cpuPercent -Sum).Sum
        processes = @($active | Select-Object -First 15); conflictingProcesses = $conflicts
        gpuEngines = $gpuCounters; gpuCounterError = $gpuCounterError
        gpu = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion)
        os = Get-CimInstance Win32_OperatingSystem | Select-Object LastBootUpTime, FreePhysicalMemory
    }
}
function Assert-Arm {
    if (-not $Arm) { throw 'Arm required' }
    $path = "$root\arms\$Arm"
    if ($ExpectedManifestSha256 -and (Get-FileHash "$path\arm.json" -Algorithm SHA256).Hash -ne $ExpectedManifestSha256) {
        throw 'Deployed arm manifest differs from the local immutable arm'
    }
    $manifest = Get-Content "$path\arm.json" -Raw | ConvertFrom-Json
    if ($manifest.arm -ne $Arm -or $manifest.configuration -ne 'Release' -or $manifest.platform -ne 'x64') {
        throw 'Unexpected arm configuration'
    }
    foreach ($entry in $manifest.files) {
        $file = Get-Item "$path\$($entry.name)"
        if ($file.Length -ne $entry.bytes -or (Get-FileHash $file.FullName -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw "Deployment hash mismatch: $($entry.name)"
        }
    }
    return $manifest
}
function Assert-Corpus {
    $expected = Get-Content "$root\corpus.json" -Raw | ConvertFrom-Json
    $actual = Get-Corpus
    if ($expected.Count -ne $actual.Count) { throw 'Corpus count changed' }
    for ($i = 0; $i -lt $actual.Count; ++$i) {
        if ($expected[$i].name -cne $actual[$i].name -or $expected[$i].sha256 -ne $actual[$i].sha256) {
            throw "Corpus changed at $($actual[$i].name)"
        }
    }
}
if ($Action -eq 'Inventory') {
    if (Test-Path "$root\corpus.json") { Assert-Corpus } else { Save-Json (Get-Corpus) "$root\corpus.json" }
    $health = Get-Health
    Save-Json $health "$root\inventory-health.json"
    Write-Output "Corpus locked: 298 .zst plus both manifests. Workspace=$root"
    $health | ConvertTo-Json -Depth 8
    exit 0
}
if ($Action -eq 'Health') { Get-Health | ConvertTo-Json -Depth 8; exit 0 }
if ($Action -eq 'CheckDeploy') {
    if (-not $Arm -or (Test-Path "$root\arms\$Arm")) { throw 'Deployment requires a new, unique arm ID' }
    exit 0
}
$manifest = Assert-Arm
Assert-Corpus
if ($Action -eq 'Verify') {
    [ordered]@{ arm = $Arm; commit = $manifest.commit; configuration = $manifest.configuration
        filesVerified = $manifest.files.Count; armManifestSha256 = (Get-FileHash "$root\arms\$Arm\arm.json" -Algorithm SHA256).Hash } |
        ConvertTo-Json
    exit 0
}
if (-not $RunId) { throw 'RunId required' }
$measurementLock = [IO.File]::Open("$root\evaluator.lock", [IO.FileMode]::OpenOrCreate,
    [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
if ($Kind -eq 'Perf' -or $Action -eq 'Profile') {
    $gates = @(Get-ChildItem "$root\results" -Filter result.json -Recurse -File | ForEach-Object {
        $gate = Get-Content $_.FullName -Raw | ConvertFrom-Json
        if ($gate.arm -eq $Arm -and $gate.commit -eq $manifest.commit -and $gate.kind -eq 'Correctness' -and $gate.exitCode -eq 0) {
            $gateInvocation = Get-Content (Join-Path $_.DirectoryName invocation.json) -Raw | ConvertFrom-Json
            if ($gateInvocation.armManifestSha256 -eq (Get-FileHash "$root\arms\$Arm\arm.json" -Algorithm SHA256).Hash) { $gate }
        }
    })
    if (-not $gates.Count) { throw 'Matching successful full-corpus correctness gate required before timing/profiling' }
}
$run = "$root\results\$RunId"
if (Test-Path $run) { throw "Run IDs are immutable: $RunId" }
New-Item -ItemType Directory $run -Force | Out-Null
$health = Get-Health
Save-Json $health "$run\health-before.json"
if ($health.conflictingProcesses.Count -gt 0 -or $health.cpuTotalPercent -gt 20) {
    throw "Measurement blocked by live interference; see $run\health-before.json"
}
$armPath = "$root\arms\$Arm"
$filter = switch ($Kind) {
    Perf { 'ZstdGpuPerfTests.Throughput' }
    Correctness { '*ZstdGpuCorrectnessTests.ExternalMemory/*:*ZstdGpuCorrectnessTests.ExternalMemorySeq/*' }
    Debug { '*ZstdGpuCorrectnessTests.D3D12DebugLayerSeq/*' }
}
$exe = "$armPath\zstdgpu_ci_tests.exe"
$arguments = @('--demo-path', "$armPath\zstdgpu_demo.exe", '--content-path', $Content,
    '--log-dir', $run, '--log-file', "$run\demo.log", '--timeout', '900',
    '--gpu-name', 'AMD Radeon RX 6900 XT', "--gtest_filter=$filter", "--gtest_output=xml:$run\gtest.xml")
if ($Action -eq 'Profile') {
    $list = Get-ChildItem "$root\results" -Recurse -Filter '*perf_throughput*.txt' |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $list) { throw 'Run exact throughput once to obtain its harness-selected list' }
    Copy-Item $list.FullName "$run\profile-list.txt"
    $exe = "$armPath\zstdgpu_demo.exe"
    $arguments = @('--zst', "@$run\profile-list.txt", '--frame-batch-count', "$ProfileRung",
        '--run-cnt', '5', '--prf-lvl', '2', '--seq-cnt', '--out-csv', "$run\profile.csv")
}
$started = [DateTime]::UtcNow
Save-Json ([ordered]@{ arm = $Arm; commit = $manifest.commit; action = $Action; kind = $Kind
    startedUtc = $started.ToString('o'); executable = $exe; arguments = $arguments
    armManifestSha256 = (Get-FileHash "$armPath\arm.json" -Algorithm SHA256).Hash
    corpusLockSha256 = (Get-FileHash "$root\corpus.json" -Algorithm SHA256).Hash }) "$run\invocation.json"
$quoted = @($arguments | ForEach-Object {
    if ($_ -match '"') { throw 'Quotes in arguments are unsupported' }
    '"' + $_ + '"'
}) -join ' '
$process = Start-Process -FilePath $exe -ArgumentList $quoted -WorkingDirectory $armPath -PassThru `
    -RedirectStandardOutput "$run\stdout.txt" -RedirectStandardError "$run\stderr.txt"
# Windows PowerShell can discard the exit status unless the process handle is retained before waiting.
$retainedHandle = $process.Handle
$process.WaitForExit()
$rc = $process.ExitCode
if ($null -eq $rc) { throw 'Missing process exit code' }
$stdout = Get-Content "$run\stdout.txt" -Raw
$stderr = if ((Get-Item "$run\stderr.txt").Length) { Get-Content "$run\stderr.txt" -Raw } else { '' }
$failureLines = @([regex]::Matches($stdout + "`n" + $stderr, '(?m)^.*error: .*$') | ForEach-Object Value)
$tests = $null
if ($Action -eq 'Run') {
    $xmlFile = Get-Item "$run\gtest.xml"
    if ($xmlFile.LastWriteTimeUtc -lt $started) { throw 'Stale gtest XML' }
    [xml]$xml = Get-Content $xmlFile.FullName -Raw
    $tests = [ordered]@{ tests = [int]$xml.testsuites.tests; failures = [int]$xml.testsuites.failures
        disabled = [int]$xml.testsuites.disabled; errors = [int]$xml.testsuites.errors
        skipped = [int](($xml.testsuites.testsuite | Measure-Object skipped -Sum).Sum) }
    $expectedTests = if ($Kind -eq 'Correctness') { 2 } else { 1 }
    if ($tests.tests -ne $expectedTests -or $tests.failures -ne 0 -or $tests.errors -ne 0 -or $tests.skipped -ne 0) { $rc = 1 }
}
if ($failureLines.Count) { $rc = 1 }
$result = [ordered]@{ runId = $RunId; arm = $Arm; commit = $manifest.commit; action = $Action; kind = $Kind
    startedUtc = $started.ToString('o'); completedUtc = [DateTime]::UtcNow.ToString('o')
    exitCode = $rc; tests = $tests; failureReasons = $failureLines
    stdoutSha256 = (Get-FileHash "$run\stdout.txt" -Algorithm SHA256).Hash
    stderrSha256 = (Get-FileHash "$run\stderr.txt" -Algorithm SHA256).Hash }
Save-Json $result "$run\result.json"
Save-Json (Get-Health) "$run\health-after.json"
$result | ConvertTo-Json -Depth 8
exit $rc
