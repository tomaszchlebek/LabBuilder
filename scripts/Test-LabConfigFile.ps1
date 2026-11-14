#Requires -Version 5.1
<#
.SYNOPSIS
    Validates a lab config file with the same rules as the build (NFR-7) and prints the host regional settings
    the VMs will get. Used by LabBuilderSetup.exe before it starts a build; no elevation needed.

.OUTPUTS
    Lines "ERROR: <message>" for every problem, "LOCALE: <name>=<value>" for the resolved settings,
    then "OK" or "INVALID". Exit code 0 = valid, 1 = invalid.

.EXAMPLE
    .\scripts\Test-LabConfigFile.ps1 -ConfigPath .\config\lab.config.psd1
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\LabBuilder\LabBuilder.psd1') -Force

try {
    $config = Import-LabConfig -Path $ConfigPath
    $errors = @(Test-LabConfig -Config $config -Scope Full)
} catch {
    $errors = @("Config file cannot be read: $($_.Exception.Message)")
    $config = $null
}
foreach ($e in $errors) { Write-Output "ERROR: $e" }
if ($config) {
    $loc = Resolve-LabLocale -Config $config
    foreach ($p in $loc.PSObject.Properties) { Write-Output ("LOCALE: {0}={1}" -f $p.Name, $p.Value) }
}
if ($errors.Count -gt 0) { Write-Output 'INVALID'; exit 1 }
Write-Output 'OK'
exit 0
