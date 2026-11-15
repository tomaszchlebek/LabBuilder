#Requires -Version 5.1
<#
.SYNOPSIS
    Lab manager back end (ADR 0015): host settings, labs on this host and the image library, as JSON (LabBuilderSetup.exe uses it).

.DESCRIPTION
    Default: prints one line 'JSON: {...}' with Settings, Labs (incl. VMs and their state) and Library (per OS: ISO, base image,
    used by). Also usable from a console (-AsObject returns objects).
    -SaveSettings          writes %ProgramData%\LabBuilder\settings.json from -AppFolder/-LabsFolder/-LibraryFolder (creates the folders).
    -RegisterDiscovered    registers labs found only through tagged VMs (1.0-1.3 layout) in place (decision D7).
    -ReconstructConfig     writes a reconstructed lab.config.psd1 for -LabName into its lab folder when its config is missing.
    Needs elevation for Hyper-V details (VM state, differencing users); without it the folders are still listed.

.EXAMPLE
    .\scripts\Get-LabInventory.ps1 -AsObject | Select-Object -ExpandProperty Labs | Format-Table Name, Domain, LabRoot, Source
#>
[CmdletBinding()]
param(
    [switch]$AsObject,
    [switch]$SaveSettings,
    [string]$AppFolder,
    [string]$LabsFolder,
    [string]$LibraryFolder,
    [switch]$RegisterDiscovered,
    [switch]$ReconstructConfig,
    [string]$LabName,
    [string]$SettingsPath
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\LabBuilder\LabBuilder.psd1') -Force
if (-not $SettingsPath) { $SettingsPath = Get-LabSettingsPath }

try {
    $settings = Get-LabHostSettings -Path $SettingsPath
    if ($SaveSettings) {
        foreach ($p in @(@('AppFolder', $AppFolder), @('LabsFolder', $LabsFolder), @('LibraryFolder', $LibraryFolder))) {
            if (-not $p[1] -or $p[1] -notmatch '^[A-Za-z]:\\') { throw "$($p[0]) must be an absolute local path." }
            $settings.($p[0]) = $p[1].TrimEnd('\')
        }
        foreach ($f in $settings.LabsFolder, $settings.LibraryFolder) { if (-not (Test-Path -LiteralPath $f)) { New-Item -ItemType Directory -Path $f -Force | Out-Null } }
        Set-LabHostSettings -Settings $settings -Path $SettingsPath
        $settings = Get-LabHostSettings -Path $SettingsPath
    }

    $labs = @(Get-LabInventory -Settings $settings)
    if ($RegisterDiscovered -and $settings.Exists) {
        if (@($labs | Where-Object Source -eq 'Discovered').Count) {
            $settings = Register-LabExternal -Settings $settings -Labs $labs
            Set-LabHostSettings -Settings $settings -Path $SettingsPath
            $settings = Get-LabHostSettings -Path $SettingsPath
        }
        # Labs before 1.4.0 shared <App>\config\lab.config.psd1: restore each lab's own config from it or its backups.
        foreach ($l in @($labs | Where-Object { -not $_.HasConfig })) { $null = Restore-LabLegacyConfig -Lab $l -AppFolder $settings.AppFolder }
        $labs = @(Get-LabInventory -Settings $settings)
    }

    $reconstructed = ''
    if ($ReconstructConfig) {
        $lab = @($labs | Where-Object { $_.Name -ieq $LabName }) | Select-Object -First 1
        if (-not $lab) { throw "Lab '$LabName' not found." }
        if (-not $lab.HasConfig) {
            $base = Join-Path $settings.AppFolder 'config\lab.config.example.psd1'
            $text = New-LabConfigFromInventory -Lab $lab -BaseConfig $base -LibraryRoot $settings.LibraryFolder
            [IO.File]::WriteAllText($lab.ConfigPath, $text, [Text.Encoding]::ASCII)
        }
        $reconstructed = $lab.ConfigPath
        $labs = @(Get-LabInventory -Settings $settings)
    }

    $catalog = (Import-LabConfig -Path (Join-Path $repo 'config\lab.config.example.psd1')).Iso.Images
    $library = Get-LabLibraryInventory -LibraryRoot $settings.LibraryFolder -Catalog $catalog
    $result = [pscustomobject]@{ Ok = $true; Error = ''; Settings = $settings; SettingsPath = $SettingsPath; Labs = $labs; Library = $library; Reconstructed = $reconstructed }
} catch {
    $result = [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message; Settings = $null; SettingsPath = $SettingsPath; Labs = @(); Library = $null; Reconstructed = '' }
}
if ($AsObject) { return $result }
'JSON: ' + (ConvertTo-Json -InputObject $result -Depth 8 -Compress)
if (-not $result.Ok) { exit 1 }
