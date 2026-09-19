[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$Arm,
    [string]$ArtifactRoot = 'C:\code\zg_campaign\rx6900-20260919-69e45d0f',
    [string]$MSBuild = 'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$SourceRoot = (Resolve-Path $SourceRoot).Path
$dirty = & git -C $SourceRoot status --porcelain -- zstd
if ($LASTEXITCODE -ne 0 -or $dirty) { throw "Product sources must be committed before building: $dirty" }
$commit = (& git -C $SourceRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve source commit' }
$armPath = Join-Path $ArtifactRoot "arms\$Arm"
if (Test-Path $armPath) { throw "Immutable arm already exists: $armPath" }
New-Item -ItemType Directory -Force "$ArtifactRoot\builds" | Out-Null
$started = [DateTime]::UtcNow
$log = "$ArtifactRoot\builds\$Arm.log"
$arguments = @("$SourceRoot\zstd\zstd.sln", '-t:zstdgpu_demo:Rebuild;zstdgpu_ci_tests:Rebuild',
    '-p:Configuration=Release', '-p:Platform=x64', '-m', '-nr:false', '-v:quiet',
    '-fl', "-flp:logfile=$log;verbosity=normal")
& $MSBuild @arguments
$rc = $LASTEXITCODE
if ($rc -ne 0) { throw "Build failed ($rc): $log" }
$output = "$SourceRoot\zstd\x64\Release"
foreach ($exe in 'zstdgpu_demo.exe', 'zstdgpu_ci_tests.exe') {
    $file = Get-Item "$output\$exe"
    if ($file.LastWriteTimeUtc -lt $started) { throw "Stale build output: $exe" }
}
New-Item -ItemType Directory $armPath | Out-Null
Copy-Item "$output\zstdgpu_demo.exe", "$output\zstdgpu_ci_tests.exe" $armPath
Get-ChildItem $output -Filter *.dll -File | Copy-Item -Destination $armPath
$crtRoot = 'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Redist\MSVC'
$crt = Get-ChildItem $crtRoot -Directory | Where-Object Name -Match '^\d+\.' |
    Sort-Object { [Version]$_.Name } -Descending | Select-Object -First 1
if (-not $crt) { throw 'App-local Release VC runtime not found' }
Get-ChildItem "$($crt.FullName)\x64\Microsoft.VC143.CRT" -Filter *.dll -File |
    Copy-Item -Destination $armPath
$files = @(Get-ChildItem $armPath -File | Sort-Object Name | ForEach-Object {
    [ordered]@{ name = $_.Name; bytes = $_.Length; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
})
$shaders = @(Get-ChildItem "$output\Shaders" -Filter *.h | Sort-Object Name | ForEach-Object {
    [ordered]@{ name = $_.Name; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
})
[ordered]@{
    arm = $Arm; commit = $commit; sourceRoot = $SourceRoot; configuration = 'Release'; platform = 'x64'
    shaderOptions = '/nologo /WX /Ges /Zi /O3'; debugLayerForPerf = $false
    startedUtc = $started.ToString('o'); completedUtc = [DateTime]::UtcNow.ToString('o')
    buildCommand = (@($MSBuild) + $arguments); buildLog = $log
    buildLogSha256 = (Get-FileHash $log -Algorithm SHA256).Hash
    vcRuntime = $crt.Name; files = $files; shaders = $shaders
} | ConvertTo-Json -Depth 8 | Set-Content "$armPath\arm.json" -Encoding UTF8
Write-Output $armPath
