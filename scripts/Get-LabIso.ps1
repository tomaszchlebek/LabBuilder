#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-downloads and verifies the Microsoft evaluation ISOs (Windows Server 2019/2022/2025, Windows 11 Enterprise LTSC)
    - ADR 0003, 0013.

.DESCRIPTION
    Needs no Hyper-V and no elevation. Use it on the Hyper-V host before a build, or on any machine with internet
    access; then copy the whole folder (ISOs + iso-manifest.json) to the host and run
    Invoke-LabBuild.ps1 -IsoSource <folder>. Invoke-LabBuild.ps1 also downloads missing ISOs itself (phase Iso).

.PARAMETER Destination
    Download folder. Default: %USERPROFILE%\LabIsoCache.
.PARAMETER Image
    OS catalog keys to download: Server2025, Server2022, Server2019, Win11LTSC (default: the images the config uses).
    Windows 10 (Win10) is never downloaded - Microsoft offers no evaluation; the tester supplies that ISO.
.PARAMETER IncludeSql
    Also fetch the SQL Server Express offline package into <Destination>\SQL (role SQL, ADR 0012). Runs the
    Microsoft-signed web installer in download mode; no installation happens on this machine.

.EXAMPLE
    .\scripts\Get-LabIso.ps1 -Destination E:\LabIso
.EXAMPLE
    .\scripts\Get-LabIso.ps1 -Destination E:\LabIso -IncludeSql
.EXAMPLE
    .\scripts\Get-LabIso.ps1 -Destination E:\LabIso -Image Server2022, Server2019, Win11LTSC
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Destination = (Join-Path $env:USERPROFILE 'LabIsoCache'),
    [string[]]$Image,
    [switch]$IncludeSql
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

$known = @($config.Iso.Images.PSObject.Properties | ForEach-Object Name)
foreach ($k in @($Image)) { if ($k -and $known -notcontains $k) { throw "Unknown image '$k' - the OS catalog has: $($known -join ', ')." } }
$entries = Save-LabIso -Config $config -Destination $Destination -Image $Image
if ($IncludeSql) { $null = Save-LabSqlMedia -Config $config -Destination $Destination }
$entries | Select-Object Key, FileName, @{ n = 'SizeGB'; e = { [math]::Round($_.Length / 1GB, 2) } }, Sha256 | Format-Table -AutoSize
Write-LabLog "ISOs are in $Destination. Copy the folder to the Hyper-V host and pass it as -IsoSource, or run the build there directly." -Level OK
