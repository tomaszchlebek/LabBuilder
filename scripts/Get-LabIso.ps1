#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-downloads and verifies the Microsoft evaluation ISOs (Windows Server 2025, Windows 11 Enterprise) - ADR 0003.

.DESCRIPTION
    Needs no Hyper-V and no elevation. Use it on the Hyper-V host before a build, or on any machine with internet
    access; then copy the whole folder (ISOs + iso-manifest.json) to the host and run
    Invoke-LabBuild.ps1 -IsoSource <folder>. Invoke-LabBuild.ps1 also downloads missing ISOs itself (phase Iso).

.PARAMETER Destination
    Download folder. Default: %USERPROFILE%\LabIsoCache.
.PARAMETER Image
    Server, Client or both (default: both).

.EXAMPLE
    .\scripts\Get-LabIso.ps1 -Destination E:\LabIso
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Destination = (Join-Path $env:USERPROFILE 'LabIsoCache'),
    [ValidateSet('Server', 'Client')][string[]]$Image = @('Server', 'Client')
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\LabBuilder\LabBuilder.psd1') -Force

$ConfigPath = Resolve-LabConfigPath -RepoRoot $repo -ConfigPath $ConfigPath
$config = Import-LabConfig -Path $ConfigPath
$errors = @(Test-LabConfig -Config $config -Scope Iso)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    throw "Configuration is not valid ($ConfigPath)."
}

if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
Set-LabLogFile -Clear -Path (Join-Path $Destination ("get-labiso-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))

$entries = Save-LabIso -Config $config -Destination $Destination -Image $Image
$entries | Select-Object Key, FileName, @{ n = 'SizeGB'; e = { [math]::Round($_.Length / 1GB, 2) } }, Sha256 | Format-Table -AutoSize
Write-LabLog "ISOs are in $Destination. Copy the folder to the Hyper-V host and pass it as -IsoSource, or run the build there directly." -Level OK
