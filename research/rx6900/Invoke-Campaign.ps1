[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Inventory', 'Health', 'Deploy', 'Verify', 'Run', 'Profile', 'ValidateCpu', 'Pair', 'Screen', 'Confirm')][string]$Action,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$Arm,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$OtherArm,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$ReferenceArm = 'reference',
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$RunId,
    [ValidateSet('Perf', 'Correctness', 'Debug')][string]$Kind = 'Perf',
    [ValidateRange(1, 20)][int]$Sessions = 3,
    [string[]]$ScreenArms,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$LeadingRunId,
    [ValidateSet(64, 128, 192, 256, 384, 512, 768, 1024)][int]$ProfileRung = 256,
    [string]$ArtifactRoot = 'C:\code\zg_campaign\rx6900-20260919-69e45d0f',
    [string]$Proxy = 'C:\tools\rdp_proxy\RdpProxy.Cli.exe'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$remote = 'rx6900-20260919-69e45d0f'
function Proxy([string[]]$Arguments) {
    & $Proxy @Arguments '--dvc=DSTESTPC2'
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { throw "RdpProxy failed ($rc): $($Arguments -join ' ')" }
}
function Remote([string]$Operation, [string]$SelectedArm, [string]$Id, [string]$SelectedKind) {
    $args = @('exec', '--cwd', $remote, '--timeout', '14400', 'powershell.exe', '-NoProfile',
        '-ExecutionPolicy', 'Bypass', '-File', ".\tools\Remote.ps1", '-Action', $Operation)
    if ($SelectedArm) { $args += @('-Arm', $SelectedArm) }
    if ($SelectedArm -and $Operation -ne 'CheckDeploy') {
        $args += @('-ExpectedManifestSha256', (Get-FileHash "$ArtifactRoot\arms\$SelectedArm\arm.json" -Algorithm SHA256).Hash)
    }
    if ($Id) { $args += @('-RunId', $Id) }
    if ($SelectedKind) { $args += @('-Kind', $SelectedKind) }
    if ($Operation -eq 'Profile') { $args += @('-ProfileRung', "$ProfileRung") }
    & $Proxy @args '--dvc=DSTESTPC2'
    $rc = $LASTEXITCODE
    if ($Id) {
        New-Item -ItemType Directory -Force "$ArtifactRoot\results" | Out-Null
        & $Proxy 'pull' "$remote\results\$Id" "$ArtifactRoot\results\$Id" '--dvc=DSTESTPC2'
        $pullRc = $LASTEXITCODE
        if ($pullRc -ne 0 -and $rc -eq 0) { throw "Run succeeded but artifact pull failed ($pullRc): $Id" }
        if ($pullRc -ne 0) { Write-Warning "No run artifacts available ($pullRc); preserving original remote error $rc." }
    }
    if ($rc -ne 0) { throw "Remote $Operation failed ($rc); raw artifacts retained for $Id" }
}
if ($Action -eq 'Inventory') {
    Proxy @('push', "$PSScriptRoot\Remote.ps1", "$remote\tools\Remote.ps1")
    Proxy @('push', "$PSScriptRoot\Validate-CpuFiles.ps1", "$remote\tools\Validate-CpuFiles.ps1")
    Remote 'Inventory' '' '' ''
    Proxy @('pull', "$remote\corpus.json", "$ArtifactRoot\corpus.json")
    Proxy @('pull', "$remote\inventory-health.json", "$ArtifactRoot\inventory-health.json")
} elseif ($Action -eq 'Health') { Remote 'Health' '' '' ''
} elseif ($Action -eq 'Deploy') {
    if (-not $Arm) { throw 'Arm required' }
    Remote 'CheckDeploy' $Arm '' ''
    Proxy @('push', "$ArtifactRoot\arms\$Arm", "$remote\arms\$Arm")
    Remote 'Verify' $Arm '' ''
} elseif ($Action -eq 'Screen') {
    if (-not $Arm -or -not $RunId -or -not $ScreenArms.Count) { throw 'Arm, RunId, and ScreenArms required' }
    foreach ($item in $ScreenArms) {
        if ($item -notmatch '^[a-zA-Z0-9_-]+$' -or $item -eq $Arm) { throw "Invalid screening candidate $item" }
    }
    if (@($ScreenArms | Select-Object -Unique).Count -ne $ScreenArms.Count) { throw 'Duplicate screening arms' }
    if (-not $LeadingRunId) {
        $LeadingRunId = "$RunId-p0-$Arm"
        Remote 'Run' $Arm $LeadingRunId 'Perf'
    }
    $schedule = @([ordered]@{ position = 0; arm = $Arm; runId = $LeadingRunId })
    $position = 0
    foreach ($item in @($ScreenArms) + @($Arm)) {
        ++$position
        $id = "$RunId-p$position-$item"
        Remote 'Run' $item $id 'Perf'
        $schedule += [ordered]@{ position = $position; arm = $item; runId = $id }
        $schedule | ConvertTo-Json -Depth 5 | Set-Content "$ArtifactRoot\results\$RunId-screen-schedule.json" -Encoding UTF8
    }
    & python "$PSScriptRoot\analyze.py" --root "$ArtifactRoot\results" `
        --schedule "$ArtifactRoot\results\$RunId-screen-schedule.json" --baseline $Arm --screen `
        --output "$ArtifactRoot\results\$RunId-screen-summary.json"
    if ($LASTEXITCODE -ne 0) { throw 'Screen validation failed' }
} elseif ($Action -eq 'Confirm') {
    if (-not $Arm -or -not $OtherArm -or -not $RunId -or $Sessions -ne 3 -or
        @($Arm, $OtherArm, $ReferenceArm | Select-Object -Unique).Count -ne 3) {
        throw 'Confirm requires three distinct arms, RunId, and exactly three sessions'
    }
    $candidateManifest = (Get-FileHash "$ArtifactRoot\arms\$OtherArm\arm.json" -Algorithm SHA256).Hash
    $gates = @(Get-ChildItem "$ArtifactRoot\results" -Recurse -Filter result.json -File | ForEach-Object {
        $result = Get-Content $_.FullName -Raw | ConvertFrom-Json
        if ($result.arm -eq $OtherArm -and $result.exitCode -eq 0) {
            $invocation = Get-Content (Join-Path $_.DirectoryName invocation.json) -Raw | ConvertFrom-Json
            if ($invocation.armManifestSha256 -eq $candidateManifest) { $result }
        }
    })
    if (-not @($gates | Where-Object { $_.kind -eq 'Debug' }).Count -or
        -not @($gates | Where-Object { $_.action -eq 'ValidateCpu' }).Count) {
        throw 'Final confirmation requires matching candidate debug and both-CPU-path gates'
    }
    $schedule = @()
    for ($session = 1; $session -le 3; ++$session) {
        $order = @($ReferenceArm, $OtherArm, $Arm, $OtherArm, $ReferenceArm)
        for ($position = 0; $position -lt 5; ++$position) {
            $id = "$RunId-s$session-p$($position + 1)-$($order[$position])"
            Remote 'Run' $order[$position] $id 'Perf'
            $schedule += [ordered]@{ session = $session; position = $position + 1; arm = $order[$position]; runId = $id }
            $schedule | ConvertTo-Json -Depth 5 | Set-Content "$ArtifactRoot\results\$RunId-joint-schedule.json" -Encoding UTF8
        }
    }
    & python "$PSScriptRoot\analyze.py" --root "$ArtifactRoot\results" `
        --schedule "$ArtifactRoot\results\$RunId-joint-schedule.json" --baseline $Arm --candidate $OtherArm `
        --reference $ReferenceArm --joint --output "$ArtifactRoot\results\$RunId-joint-summary.json"
    if ($LASTEXITCODE -ne 0) { throw 'Shared-control confirmation validation failed' }
} elseif ($Action -eq 'Pair') {
    if (-not $Arm -or -not $OtherArm -or -not $RunId -or $Arm -eq $OtherArm) { throw 'Distinct arms and RunId required' }
    $schedule = @()
    for ($session = 1; $session -le $Sessions; ++$session) {
        $order = @($Arm, $OtherArm, $OtherArm, $Arm)
        for ($position = 0; $position -lt 4; ++$position) {
            $id = "$RunId-s$session-p$($position + 1)-$($order[$position])"
            Remote 'Run' $order[$position] $id 'Perf'
            $schedule += [ordered]@{ session = $session; position = $position + 1; arm = $order[$position]; runId = $id }
            $schedule | ConvertTo-Json -Depth 5 | Set-Content "$ArtifactRoot\results\$RunId-schedule.json" -Encoding UTF8
        }
    }
    & python "$PSScriptRoot\analyze.py" --root "$ArtifactRoot\results" --schedule "$ArtifactRoot\results\$RunId-schedule.json" `
        --baseline $Arm --candidate $OtherArm --output "$ArtifactRoot\results\$RunId-summary.json"
    if ($LASTEXITCODE -ne 0) { throw 'Statistics validation failed' }
} else { Remote $Action $Arm $RunId $Kind }
