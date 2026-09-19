[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Inventory', 'Health', 'Deploy', 'Verify', 'Run', 'Profile', 'Pair')][string]$Action,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$Arm,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$OtherArm,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$RunId,
    [ValidateSet('Perf', 'Correctness', 'Debug')][string]$Kind = 'Perf',
    [ValidateRange(1, 20)][int]$Sessions = 3,
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
    if ($Id) { $args += @('-RunId', $Id) }
    if ($SelectedKind) { $args += @('-Kind', $SelectedKind) }
    & $Proxy @args '--dvc=DSTESTPC2'
    $rc = $LASTEXITCODE
    if ($Id) {
        New-Item -ItemType Directory -Force "$ArtifactRoot\results" | Out-Null
        Proxy @('pull', "$remote\results\$Id", "$ArtifactRoot\results\$Id")
    }
    if ($rc -ne 0) { throw "Remote $Operation failed ($rc); raw artifacts retained for $Id" }
}
if ($Action -eq 'Inventory') {
    Proxy @('push', "$PSScriptRoot\Remote.ps1", "$remote\tools\Remote.ps1")
    Remote 'Inventory' '' '' ''
    Proxy @('pull', "$remote\corpus.json", "$ArtifactRoot\corpus.json")
    Proxy @('pull', "$remote\inventory-health.json", "$ArtifactRoot\inventory-health.json")
} elseif ($Action -eq 'Health') { Remote 'Health' '' '' ''
} elseif ($Action -eq 'Deploy') {
    if (-not $Arm) { throw 'Arm required' }
    Proxy @('push', "$ArtifactRoot\arms\$Arm", "$remote\arms\$Arm")
    Remote 'Verify' $Arm '' ''
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
