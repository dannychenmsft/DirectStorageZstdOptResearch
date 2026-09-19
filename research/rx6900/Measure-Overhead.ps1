[CmdletBinding()]
param(
    [string]$Content = 'C:\agent\data\zstd_content',
    [ValidateRange(1, 5)][int]$Repetitions = 3
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$expected = Get-Content "$root\corpus.json" -Raw | ConvertFrom-Json
$measurements = @()
for ($iteration = 1; $iteration -le $Repetitions; ++$iteration) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $files = @(Get-ChildItem $Content -Recurse -File -Filter *.zst | Sort-Object FullName)
    $entries = @($files) + @(Get-Item "$Content\perf_manifest.json", "$Content\adversarial_manifest.json")
    if ($files.Count -ne 298 -or $entries.Count -ne $expected.Count) { throw 'Corpus enumeration changed' }
    $enumerationMs = $clock.Elapsed.TotalMilliseconds
    $clock.Restart()
    for ($i = 0; $i -lt $entries.Count; ++$i) {
        $entry = $entries[$i]
        $relative = $entry.FullName.Substring($Content.TrimEnd('\').Length + 1)
        if ($relative -cne $expected[$i].name -or $entry.Length -ne $expected[$i].bytes) {
            throw "Corpus metadata changed: $relative"
        }
        if ((Get-FileHash $entry.FullName -Algorithm SHA256).Hash -ne $expected[$i].sha256) {
            throw "Corpus content changed: $relative"
        }
    }
    $measurements += [ordered]@{ iteration = $iteration; fileCount = $entries.Count
        totalBytes = ($entries | Measure-Object Length -Sum).Sum
        enumerationMs = $enumerationMs; sha256AndComparisonMs = $clock.Elapsed.TotalMilliseconds }
}
[ordered]@{
    utc = [DateTime]::UtcNow.ToString('o'); action = 'verification-overhead-diagnostic'
    acceptanceData = $false; measurements = $measurements
} | ConvertTo-Json -Depth 5
