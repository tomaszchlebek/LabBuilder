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
        'Iso'              { if ($IsoSource) { Import-LabIso -Config $Config -Source $IsoSource }
                             $output = Save-LabIso -Config $Config -Destination (Join-Path $root 'ISO')
                             Confirm-LabHostIso -Config $Config
                             if (Test-LabSqlRequired -Config $Config) {
                                 if ($IsoSource) { Import-LabSqlMedia -Config $Config -Source $IsoSource }
                                 $null = Save-LabSqlMedia -Config $Config -Destination (Join-Path $root 'ISO')
                             } }
        'BaseImages'       { New-LabBaseImage -Config $Config }
        'Network'          { New-LabNetwork -Config $Config }
        'DomainControllers' { Install-LabDomainController -Config $Config -AdminCredential $AdminCredential -AccountsJson $AccountsJson }
        'MemberServers'    { Install-LabMemberServer -Config $Config -AdminCredential $AdminCredential -SqlSaCredential $SqlSaCredential }
        'Workstations'     { Install-LabWorkstation -Config $Config -AdminCredential $AdminCredential }
        'Validate'         { $output = Test-LabEnvironment -Config $Config -AdminCredential $AdminCredential -AccountsJson $AccountsJson -SqlSaCredential $SqlSaCredential }
    }
    Set-LabPhaseState -Config $Config -Phase $Name -Status 'Completed' -Seconds ([int]$sw.Elapsed.TotalSeconds)
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
        Tears the lab down (FR-15): only the VMs named in the config, their disks and the lab switch.
        ISOs and base images are kept unless requested.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$ConfigJson,
        [switch]$IncludeBaseImages,
        [switch]$IncludeIso
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

    if ($IncludeBaseImages) {
        foreach ($key in @('Server', 'Client')) {
            $vhd = Get-LabBaseImagePath -Config $Config -Image $key
            if ((Test-Path -LiteralPath $vhd) -and $PSCmdlet.ShouldProcess($vhd, 'Delete base image')) {
                Set-ItemProperty -LiteralPath $vhd -Name IsReadOnly -Value $false
                Remove-Item -LiteralPath $vhd, "$vhd.json" -Force -ErrorAction SilentlyContinue
                Write-LabLog "  removed base image $vhd"
            }
        }
    }
    if ($IncludeIso) {
        $isoDir = Join-Path $root 'ISO'
        if ((Test-Path -LiteralPath $isoDir) -and $PSCmdlet.ShouldProcess($isoDir, 'Delete ISO folder on host')) {
            Remove-Item -LiteralPath $isoDir -Recurse -Force
            Write-LabLog "  removed $isoDir"
        }
    }
    $state = Join-Path $root 'state.json'
    if (Test-Path -LiteralPath $state) { Remove-Item -LiteralPath $state -Force }
    Write-LabLog "=== Lab $($Config.LabName) removed ===" -Level OK
}
