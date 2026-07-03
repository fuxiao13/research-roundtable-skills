[CmdletBinding()]
param(
    [string]$DataRoot = (Join-Path $HOME '.research-roundtable')
)

$ErrorActionPreference = 'Stop'
$dataRootFull = [IO.Path]::GetFullPath($DataRoot)
$kimiHome = Join-Path $dataRootFull 'kimi'

New-Item -ItemType Directory -Path $kimiHome -Force | Out-Null
$env:KIMI_CODE_HOME = $kimiHome
$env:KIMI_CLI_NO_AUTO_UPDATE = '1'

$kimi = Get-Command kimi -ErrorAction Stop
Write-Host "Kimi dedicated data directory: $kimiHome"
Write-Host 'Starting Kimi Code login. Credentials and sessions will be stored there.'
& $kimi.Source login

if ($LASTEXITCODE -ne 0) {
    throw "Kimi Code login failed with exit code $LASTEXITCODE."
}

Write-Host 'Kimi Code dedicated cache is ready.'
