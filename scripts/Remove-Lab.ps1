#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes a lab from THIS Hyper-V host (FR-15, ADR 0015).

.DESCRIPTION
    -LabName (1.4.0+, recommended): deletes a lab known to this host (Labs folder, registered 1.0-1.3 labs, tagged VMs) - its
    VMs (from lab.json and every VM tagged LabBuilder:<LabName>), checkpoints and disks, the switch if no other VM uses it, the
    lab's files (VMs, Logs, Reports, output with credentials, lab.json, state.json, lab.config.psd1), the lab folder when empty, and
    its registration. Works without a config (e.g. a lab whose config was lost). Never touches the image library.

    -ConfigPath (as before): only VMs named <LabName>-<ComputerName> from that config, the lab switch and <LabRoot>\lab.json.
    -IncludeLibrary then also deletes the ISOs and base images THIS lab uses (other labs that use them download/build them again;
    base images still used by differencing disks are kept). -RemoveOutput also deletes the lab's credentials/reports folder.

    Asks for confirmation; use -WhatIf to preview.

.EXAMPLE
    .\scripts\Remove-Lab.ps1 -LabName DIFFLAB -WhatIf
.EXAMPLE
    .\scripts\Remove-Lab.ps1 -LabName DIFFLAB
.EXAMPLE
    .\scripts\Remove-Lab.ps1 -ConfigPath .\config\lab.config.psd1 -RemoveOutput
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Config')]
param(
    [Parameter(ParameterSetName = 'Lab', Mandatory)][string]$LabName,
    [Parameter(ParameterSetName = 'Lab')][switch]$Force,   # no confirmation prompt (LabBuilderSetup.exe already asked for the typed lab name)
    [Parameter(ParameterSetName = 'Config')][string]$ConfigPath,
    [Parameter(ParameterSetName = 'Config')][string]$LabRoot,
    [Parameter(ParameterSetName = 'Config')][Alias('IncludeBaseImages', 'IncludeIso')][switch]$IncludeLibrary,
    [Parameter(ParameterSetName = 'Config')][switch]$RemoveOutput
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\LabBuilder\LabBuilder.psd1') -Force

if ($PSCmdlet.ParameterSetName -eq 'Lab') {
    $settings = Get-LabHostSettings
    $lab = @(Get-LabInventory -Settings $settings -NoSize | Where-Object { $_.Name -ieq $LabName }) | Select-Object -First 1
    if (-not $lab) { throw "Lab '$LabName' is not known on this host (Labs folder, registered labs, tagged VMs)." }
    if ($lab.LabRoot -and (Test-Path -LiteralPath $lab.LabRoot)) { Set-LabLogFile -Path (Join-Path $env:TEMP ("labbuilder-delete-{0}.log" -f $lab.Name)) -Clear }
    $what = "lab $($lab.Name) ($($lab.Domain)): VMs $((@($lab.VMs) | ForEach-Object VMName) -join ', '), their disks, switch $($lab.Switch) if unused, $($lab.LabRoot) and $($lab.OutputPath) (credentials)"
    if ($WhatIfPreference) { Remove-LabFromInventory -Lab $lab -Settings $settings -WhatIf; return }
    if ($Force -or $PSCmdlet.ShouldProcess("lab '$($lab.Name)' on $env:COMPUTERNAME", "Delete $what")) {
        Remove-LabFromInventory -Lab $lab -Settings $settings -Confirm:$false
    }
    return
}

$ConfigPath = Resolve-LabConfigPath -RepoRoot $repo -ConfigPath $ConfigPath
$config = Import-LabConfig -Path $ConfigPath -Overrides @{ 'Paths.LabRoot' = $LabRoot }
$errors = @(Test-LabConfig -Config $config -Scope Host)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    throw "Configuration is not valid ($ConfigPath)."
}
$configJson = $config | ConvertTo-Json -Depth 20 -Compress
$vmList = (Get-LabVmDefinition -Config $config | ForEach-Object VMName) -join ', '
$outDir = Get-LabOutputPath -Config $config -AppFolder $repo

$what = "VMs $vmList, their disks and switch $($config.Network.SwitchName)"
if ($IncludeLibrary) { $what += ', its ISOs and base images in the shared image library (also used by other labs)' }
if ($RemoveOutput) { $what += ", $outDir (credentials)" }

if ($WhatIfPreference) {
    Remove-LabEnvironment -ConfigJson $configJson -IncludeLibrary:$IncludeLibrary -WhatIf
    return
}
if ($PSCmdlet.ShouldProcess("lab '$($config.LabName)' on $env:COMPUTERNAME", "Delete $what")) {
    Remove-LabEnvironment -ConfigJson $configJson -IncludeLibrary:$IncludeLibrary -Confirm:$false
    if ($RemoveOutput -and (Test-Path -LiteralPath $outDir)) { Remove-Item -LiteralPath $outDir -Recurse -Force; Write-LabLog "Removed $outDir" }
}
