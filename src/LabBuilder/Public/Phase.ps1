$script:LabPhases = @('Preflight', 'Iso', 'BaseImages', 'Network', 'DomainControllers', 'MemberServers', 'Workstations', 'Validate')

function Invoke-LabPhase {
    <#
    .SYNOPSIS
        Runs one build phase on this Hyper-V host. Called by scripts\Invoke-LabBuild.ps1 (ADR 0007).
    .PARAMETER ConfigJson
        Lab config as JSON.
    .PARAMETER AccountsJson
        Account plan as JSON (DomainControllers, Validate).
    .PARAMETER IsoSource
        Optional folder with pre-downloaded ISOs + iso-manifest.json (phase Iso).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Preflight', 'Iso', 'BaseImages', 'Network', 'DomainControllers', 'MemberServers', 'Workstations', 'Validate')][string]$Name,
        [Parameter(Mandatory)][string]$ConfigJson,
        [pscredential]$AdminCredential,
        [string]$AccountsJson = '[]',
        [string]$IsoSource,
        [pscredential]$SqlSaCredential
    )

    $ErrorActionPreference = 'Stop'
    $Config = ConvertTo-LabConfigObject -InputObject $ConfigJson
    $root = [string]$Config.Paths.LabRoot
    if (Test-Path -LiteralPath $root) {
        Set-LabLogFile -Path (Join-Path $root ("Logs\labbuilder-{0}.log" -f (Get-Date -Format 'yyyyMMdd')))
    }
    Write-LabLog "=== Phase $Name on $env:COMPUTERNAME ===" -Level STEP
    if (@('DomainControllers', 'MemberServers', 'Workstations', 'Validate') -contains $Name -and -not $AdminCredential) {
        throw "Phase $Name needs -AdminCredential."
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $output = $null
    switch ($Name) {
        'Preflight'        { $output = Test-LabHostPrerequisites -Config $Config
                             Set-LabLogFile -Path (Join-Path $root ("Logs\labbuilder-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))) }
        'Iso'              { # Everything goes into the shared image library (ADR 0013); 1.0/1.1 media is moved there first.
                             $lib = Get-LabLibraryIsoFolder -Config $Config
                             Move-LabLegacyMedia -Config $Config
                             if ($IsoSource) { Import-LabIso -Config $Config -Source $IsoSource }
                             # One worker per ISO - downloads/imports run in parallel (ADR 0014); library locks still apply.
                             $keys = @(Get-LabRequiredImageKey -Config $Config)
                             $output = Invoke-LabParallel -Items $keys -Label { param($k) "ISO $k" } -What 'ISOs' `
                                 -ThrottleLimit (Get-LabThrottleLimit -Config $Config -Count $keys.Count -Max 4) -Sequential:(-not (Test-LabParallelEnabled -Config $Config)) `
                                 -Arguments @{ Config = $Config; Lib = $lib } -ScriptBlock {
                                     param($Item, $A)
                                     Save-LabIso -Config $A.Config -Destination $A.Lib -Image $Item -ImportSupplied
                                 }
                             Confirm-LabHostIso -Config $Config
                             if (Test-LabSqlRequired -Config $Config) {
                                 Invoke-LabLibraryLock -Name 'SQL' -ScriptBlock {
                                     if ($IsoSource) { Import-LabSqlMedia -Config $Config -Source $IsoSource }
                                     $null = Save-LabSqlMedia -Config $Config -Destination $lib
                                 }
                             } }
        'BaseImages'       { New-LabBaseImage -Config $Config }
        'Network'          { New-LabNetwork -Config $Config }
        'DomainControllers' { Install-LabDomainController -Config $Config -AdminCredential $AdminCredential -AccountsJson $AccountsJson }
        'MemberServers'    { Install-LabMemberServer -Config $Config -AdminCredential $AdminCredential -SqlSaCredential $SqlSaCredential }
        'Workstations'     { Install-LabWorkstation -Config $Config -AdminCredential $AdminCredential }
        'Validate'         { $output = Test-LabEnvironment -Config $Config -AdminCredential $AdminCredential -AccountsJson $AccountsJson -SqlSaCredential $SqlSaCredential }
    }
    Set-LabPhaseState -Config $Config -Phase $Name -Status 'Completed' -Seconds ([int]$sw.Elapsed.TotalSeconds)
    Write-LabManifest -Config $Config -Phase $Name   # <LabRoot>\lab.json (FR-23)
    Write-LabLog ('=== Phase {0} completed in {1:N1} min ===' -f $Name, $sw.Elapsed.TotalMinutes) -Level OK
    return $output
}

function Set-LabPhaseState {
    # <LabRoot>\state.json - informational record of completed phases (phases themselves are idempotent).
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Phase, [string]$Status = 'Completed', [int]$Seconds = 0)
    $file = Join-Path ([string]$Config.Paths.LabRoot) 'state.json'
    $state = @{}
    if (Test-Path -LiteralPath $file) {
        $obj = (Get-Content -LiteralPath $file -Raw) | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $state[$p.Name] = $p.Value }
    }
    $state[$Phase] = [pscustomobject]@{ Status = $Status; CompletedUtc = (Get-Date).ToUniversalTime().ToString('o'); Seconds = $Seconds }
    $state['LabName'] = [string]$Config.LabName
    ConvertTo-Json -InputObject $state -Depth 4 | Set-Content -LiteralPath $file -Encoding UTF8
}

function Remove-LabEnvironment {
    <#
    .SYNOPSIS
        Tears the lab down (FR-15): only the VMs named in the config, their disks, the lab switch and lab.json.
        The shared image library is kept; -IncludeLibrary also deletes the ISOs and base images THIS lab uses from the
        library (other labs on the host that use them will download/build them again) - ADR 0013.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$ConfigJson,
        [Alias('IncludeBaseImages', 'IncludeIso')][switch]$IncludeLibrary
    )

    $Config = ConvertTo-LabConfigObject -InputObject $ConfigJson
    $root = [string]$Config.Paths.LabRoot
    if (Test-Path -LiteralPath $root) { Set-LabLogFile -Path (Join-Path $root ("Logs\labbuilder-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))) }
    Write-LabLog "=== Remove lab $($Config.LabName) on $env:COMPUTERNAME ===" -Level STEP

    foreach ($d in @(Get-LabVmDefinition -Config $Config)) {
        $vm = Get-VM -Name $d.VMName -ErrorAction SilentlyContinue
        if ($vm -and $PSCmdlet.ShouldProcess($d.VMName, 'Turn off and delete VM and its disks')) {
            if ($vm.State -ne 'Off') { Stop-VM -Name $d.VMName -TurnOff -Force }
            Remove-VM -Name $d.VMName -Force
            Write-LabLog "  removed VM $($d.VMName)"
        }
        $dir = Join-Path $root "VMs\$($d.VMName)"
        if ((Test-Path -LiteralPath $dir) -and $PSCmdlet.ShouldProcess($dir, 'Delete folder')) {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
    }

    $sw = Get-VMSwitch -Name $Config.Network.SwitchName -ErrorAction SilentlyContinue
    if ($sw) {
        $users = @(Get-VMNetworkAdapter -All | Where-Object { $_.SwitchName -eq $sw.Name })
        if ($users.Count -gt 0) {
            Write-LabLog "  switch $($sw.Name) kept - still used by: $(($users | ForEach-Object VMName | Select-Object -Unique) -join ', ')" -Level WARN
        } elseif ($PSCmdlet.ShouldProcess($sw.Name, 'Remove virtual switch')) {
            Remove-VMSwitch -Name $sw.Name -Force
            Write-LabLog "  removed switch $($sw.Name)"
        }
    }

    if ($IncludeLibrary) {
        $isoDir = Get-LabLibraryIsoFolder -Config $Config
        $cmdlet = $PSCmdlet   # inside the lock blocks $PSCmdlet would be the lock function's (WhatIf would be lost)
        foreach ($key in (Get-LabRequiredImageKey -Config $Config)) {
            Invoke-LabLibraryLock -Name "Base-$key" -ScriptBlock {
                $vhd = Get-LabBaseImagePath -Config $Config -Image $key
                $users = @(Get-LabBaseImageUser -Path $vhd)   # differencing disks of other labs (this lab's VMs are gone by now)
                if ($users.Count -gt 0) {
                    Write-LabLog "  base image $vhd kept - differencing disks of $($users -join ', ') use it (ADR 0014)." -Level WARN
                } elseif ((Test-Path -LiteralPath $vhd) -and $cmdlet.ShouldProcess($vhd, 'Delete base image from the shared library')) {
                    Set-ItemProperty -LiteralPath $vhd -Name IsReadOnly -Value $false
                    Remove-Item -LiteralPath $vhd, "$vhd.json" -Force -ErrorAction SilentlyContinue
                    Write-LabLog "  removed base image $vhd"
                }
            }
            Invoke-LabLibraryLock -Name "Iso-$key" -ScriptBlock {
                $iso = Join-Path $isoDir ([string]$Config.Iso.Images.$key.FileName)
                if ((Test-Path -LiteralPath $iso) -and $cmdlet.ShouldProcess($iso, 'Delete ISO from the shared library')) {
                    Remove-Item -LiteralPath $iso -Force
                    Invoke-LabLibraryLock -Name 'IsoManifest' -TimeoutMinutes 10 -ScriptBlock {
                        $map = Read-LabIsoManifest -Folder $isoDir
                        $map.Remove([string]$Config.Iso.Images.$key.FileName)
                        Write-LabIsoManifest -Folder $isoDir -Map $map
                    }
                    Write-LabLog "  removed ISO $iso"
                }
            }
        }
    }
    foreach ($f in 'state.json', 'lab.json') {
        $p = Join-Path $root $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    Write-LabLog "=== Lab $($Config.LabName) removed ===" -Level OK
}
