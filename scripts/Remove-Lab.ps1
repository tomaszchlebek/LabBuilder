#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the lab from THIS Hyper-V host (FR-15): the VMs named in the config, their disks and the lab switch.

.DESCRIPTION
    Only VMs named <LabName>-<ComputerName> from the config are touched, plus the lab switch and <LabRoot>\lab.json.
    The shared image library (ISOs, base images; ADR 0013) is kept unless -IncludeLibrary is given: it then deletes
    the ISOs and base images THIS lab uses - other labs on the host that use them will download/build them again
    (-IncludeIso / -IncludeBaseImages are accepted as aliases). -RemoveOutput also deletes output\<LabName>.
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
    [Alias('IncludeBaseImages', 'IncludeIso')][switch]$IncludeLibrary,
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
if ($IncludeLibrary) { $what += ', its ISOs and base images in the shared image library (also used by other labs)' }
if ($RemoveOutput) { $what += ', output\' + $config.LabName + ' (credentials)' }

if ($WhatIfPreference) {
    Remove-LabEnvironment -ConfigJson $configJson -IncludeLibrary:$IncludeLibrary -WhatIf
    return
}
if ($PSCmdlet.ShouldProcess("lab '$($config.LabName)' on $env:COMPUTERNAME", "Delete $what")) {
    Remove-LabEnvironment -ConfigJson $configJson -IncludeLibrary:$IncludeLibrary -Confirm:$false
    if ($RemoveOutput) {
        $outDir = Join-Path $repo "output\$($config.LabName)"
        if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force; Write-LabLog "Removed $outDir" }
    }
}
