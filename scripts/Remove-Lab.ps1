#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the lab from THIS Hyper-V host (FR-15): the VMs named in the config, their disks and the lab switch.

.DESCRIPTION
    Only VMs named <LabName>-<ComputerName> from the config are touched. ISOs and base images are kept unless
    -IncludeIso / -IncludeBaseImages are given. -RemoveOutput also deletes output\<LabName> (credentials, reports).
    Asks for confirmation; use -WhatIf to preview.

.EXAMPLE
    .\scripts\Remove-Lab.ps1 -WhatIf
.EXAMPLE
    .\scripts\Remove-Lab.ps1 -RemoveOutput
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$ConfigPath,
    [string]$LabRoot,
    [switch]$IncludeBaseImages,
    [switch]$IncludeIso,
    [switch]$RemoveOutput
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\LabBuilder\LabBuilder.psd1') -Force

$ConfigPath = Resolve-LabConfigPath -RepoRoot $repo -ConfigPath $ConfigPath
$config = Import-LabConfig -Path $ConfigPath -Overrides @{ 'Paths.LabRoot' = $LabRoot }
$errors = @(Test-LabConfig -Config $config -Scope Host)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    throw "Configuration is not valid ($ConfigPath)."
}
$configJson = $config | ConvertTo-Json -Depth 20 -Compress
$vmList = (Get-LabVmDefinition -Config $config | ForEach-Object VMName) -join ', '

$what = "VMs $vmList, their disks and switch $($config.Network.SwitchName)"
if ($IncludeBaseImages) { $what += ', base images' }
if ($IncludeIso) { $what += ', ISOs' }
if ($RemoveOutput) { $what += ', output\' + $config.LabName + ' (credentials)' }

if ($WhatIfPreference) {
    Remove-LabEnvironment -ConfigJson $configJson -IncludeBaseImages:$IncludeBaseImages -IncludeIso:$IncludeIso -WhatIf
    return
}
if ($PSCmdlet.ShouldProcess("lab '$($config.LabName)' on $env:COMPUTERNAME", "Delete $what")) {
    Remove-LabEnvironment -ConfigJson $configJson -IncludeBaseImages:$IncludeBaseImages -IncludeIso:$IncludeIso -Confirm:$false
    if ($RemoveOutput) {
        $outDir = Join-Path $repo "output\$($config.LabName)"
        if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force; Write-LabLog "Removed $outDir" }
    }
}
