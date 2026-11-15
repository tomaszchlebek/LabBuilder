function New-LabVM {
    <#
    .SYNOPSIS
        Creates one lab VM: dynamic copy of the library base image of its OS (ADR 0008/0013), unattend.xml injected,
        Gen 2, Secure Boot, vTPM for workstations, notes tagged LabBuilder:<LabName>, connected only to the lab switch;
        then starts it. Skips an existing VM (and tags it if it came from LabBuilder 1.0/1.1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][pscredential]$AdminCredential
    )

    $vmName = $Definition.VMName
    $phase = Get-LabPhaseOfRole -Role $Definition.Role
    $existing = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.State -ne 'Running') { Start-VM -Name $vmName | Out-Null }
        $note = Get-LabVmNote -Config $Config -Definition $Definition
        if (-not ([string]$existing.Notes).StartsWith("LabBuilder:$($Config.LabName) ")) { Set-VM -Name $vmName -Notes $note }   # tag VMs of 1.0/1.1 labs (FR-23)
        Write-LabLog "VM $vmName exists ($($existing.State))." -Level OK
        Write-LabProgress -Config $Config -Phase $phase -Item $Definition.Name -Status 'starting' -Detail 'exists'
        return
    }
    Write-LabProgress -Config $Config -Phase $phase -Item $Definition.Name -Status 'creating' -Detail "$($Definition.Image), $($Definition.IPAddress)"

    $root = [string]$Config.Paths.LabRoot
    $base = Get-LabBaseImagePath -Config $Config -Image $Definition.Image
    if (-not (Test-Path -LiteralPath $base)) { throw "Base image missing: $base - run phase BaseImages." }
    if (-not (Get-VMSwitch -Name $Config.Network.SwitchName -ErrorAction SilentlyContinue)) { throw "Switch $($Config.Network.SwitchName) missing - run phase Network." }

    Write-LabLog "Creating VM $vmName ($($Definition.Role), $($Definition.Image), $($Definition.IPAddress)) ..." -Level STEP
    $vmDir = Join-Path $root "VMs\$vmName"
    $diskPath = Join-Path $vmDir "$vmName-os.vhdx"
    if (-not (Test-Path -LiteralPath $vmDir)) { New-Item -ItemType Directory -Path $vmDir -Force | Out-Null }
    if (Test-Path -LiteralPath $diskPath) {   # leftover of a failed run, the VM never existed
        Dismount-VHD -Path $diskPath -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $diskPath -Force
    }

    if ((Get-LabDiskType -Config $Config) -eq 'Differencing') {
        # Option (ADR 0014, decision D5): differencing VHDX on the library base - seconds, a few hundred MB; the VM depends on the base.
        Write-LabLog ('  disk: differencing VHDX {0:N0} GB on {1}' -f ($Definition.DiskSizeBytes / 1GB), $base)
        New-VHD -Path $diskPath -ParentPath $base -Differencing | Out-Null
    } else {
        # Independent dynamic VHDX: copy of the base, expanded to the tester's size (ADR 0008).
        Write-LabLog ('  disk: dynamic VHDX {0:N0} GB (copy of {1})' -f ($Definition.DiskSizeBytes / 1GB), (Split-Path $base -Leaf))
        Copy-Item -LiteralPath $base -Destination $diskPath -Force
        Set-ItemProperty -LiteralPath $diskPath -Name IsReadOnly -Value $false
        try { Set-VHD -Path $diskPath -ResetDiskIdentifier -Force -ErrorAction Stop } catch { Write-LabLog "  could not reset disk identifier: $($_.Exception.Message)" -Level WARN }
    }
    if ((Get-VHD -Path $diskPath).Size -lt $Definition.DiskSizeBytes) { Resize-VHD -Path $diskPath -SizeBytes $Definition.DiskSizeBytes }

    # Locale (host settings, image language) and unattend.xml
    $imageLanguage = ''
    $sidecar = "$base.json"
    if (Test-Path -LiteralPath $sidecar) { $imageLanguage = [string]((Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json).Language) }
    $locale = Resolve-LabLocale -Config $Config -ImageLanguage $imageLanguage
    Write-LabLog "  locale: UI $($locale.UILanguage), input $($locale.InputLocale), system $($locale.SystemLocale), user $($locale.UserLocale), time zone '$($locale.TimeZone)'"
    $xml = New-LabUnattendXml -Image $Definition.Kind -ComputerName $Definition.Name -AdminCredential $AdminCredential -Locale $locale

    # One disk mounted on the host at a time (ADR 0014): copies and differencing children of one base share the GPT disk GUID,
    # and VMs are created in parallel. Host-wide lock, so two lab builds at once are safe too.
    Invoke-LabLibraryLock -Name 'VhdMount' -TimeoutMinutes 30 -Quiet -ScriptBlock {
    $disk = Mount-VHD -Path $diskPath -Passthru | Get-Disk
    try {
        $winPart = $null
        foreach ($p in @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -eq 'Basic' })) {
            if (-not $p.DriveLetter) { $p | Add-PartitionAccessPath -AssignDriveLetter; $p = Get-Partition -DiskNumber $disk.Number -PartitionNumber $p.PartitionNumber }
            if ($p.DriveLetter -and (Test-Path -LiteralPath "$($p.DriveLetter):\Windows\System32")) { $winPart = $p; break }
        }
        if (-not $winPart) { throw "No Windows partition found in $diskPath." }
        $max = (Get-PartitionSupportedSize -DiskNumber $disk.Number -PartitionNumber $winPart.PartitionNumber).SizeMax
        if ($max -gt $winPart.Size + 100MB) {
            Resize-Partition -DiskNumber $disk.Number -PartitionNumber $winPart.PartitionNumber -Size $max
        }
        $panther = "$($winPart.DriveLetter):\Windows\Panther"
        if (-not (Test-Path -LiteralPath $panther)) { New-Item -ItemType Directory -Path $panther -Force | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $panther 'unattend.xml'), $xml, (New-Object System.Text.UTF8Encoding($false)))
    }
    finally {
        Dismount-VHD -Path $diskPath -ErrorAction SilentlyContinue
    }
    }

    New-VM -Name $vmName -Generation 2 -MemoryStartupBytes $Definition.MemoryBytes -VHDPath $diskPath `
        -SwitchName $Config.Network.SwitchName -Path (Join-Path $root 'VMs') | Out-Null
    Set-VM -Name $vmName -ProcessorCount $Definition.ProcessorCount -StaticMemory -AutomaticCheckpointsEnabled $false `
        -AutomaticStartAction Nothing -AutomaticStopAction ShutDown `
        -Notes (Get-LabVmNote -Config $Config -Definition $Definition)
    Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    if ($Definition.Kind -eq 'Client') {   # vTPM for Windows 10/11
        Set-VMKeyProtector -VMName $vmName -NewLocalKeyProtector
        Enable-VMTPM -VMName $vmName
    }
    Get-VMIntegrationService -VMName $vmName | Where-Object { -not $_.Enabled } | Enable-VMIntegrationService -ErrorAction SilentlyContinue
    Start-VM -Name $vmName | Out-Null
    Write-LabLog "VM $vmName started." -Level OK
    Write-LabProgress -Config $Config -Phase $phase -Item $Definition.Name -Status 'starting'
}

function New-LabVMSet {
    <#
    .SYNOPSIS
        Creates and starts several lab VMs in parallel (FR-24, ADR 0014); existing VMs are only started.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Definitions,
        [Parameter(Mandatory)][pscredential]$AdminCredential
    )
    $defs = @($Definitions)
    if ($defs.Count -eq 0) { return }
    $null = Invoke-LabParallel -Items $defs -Label { param($d) $d.Name } -What 'VMs (create)' `
        -ThrottleLimit (Get-LabThrottleLimit -Config $Config -Count $defs.Count -Max 4) -Sequential:(-not (Test-LabParallelEnabled -Config $Config)) `
        -LogFolder (Join-Path ([string]$Config.Paths.LabRoot) 'Logs') -Arguments @{ Config = $Config; Cred = $AdminCredential } -ScriptBlock {
            param($Item, $A)
            try { New-LabVM -Config $A.Config -Definition $Item -AdminCredential $A.Cred }
            catch { Write-LabProgress -Config $A.Config -Phase (Get-LabPhaseOfRole -Role $Item.Role) -Item $Item.Name -Status 'failed' -Detail $_.Exception.Message; throw }
        }
}

function Get-LabDiskType {
    # Disks.Type: Dynamic (default, independent copies - ADR 0008) or Differencing (option, ADR 0014).
    param([Parameter(Mandatory)]$Config)
    if ($Config.Disks -and [string]$Config.Disks.Type -eq 'Differencing') { return 'Differencing' }
    return 'Dynamic'
}

function Get-LabBaseImageUser {
    <#
    .SYNOPSIS
        Names of the VMs on this host whose (differencing) disks use the given base image as parent - such a base must not be
        rebuilt or deleted (ADR 0014).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $users = New-Object System.Collections.Generic.List[string]
    if (-not (Get-Command -Name Get-VM -ErrorAction SilentlyContinue)) { return $users.ToArray() }
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue)) {
        foreach ($hdd in @(Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue)) {
            $p = [string]$hdd.Path
            for ($depth = 0; $p -and $depth -lt 8; $depth++) {
                $vhd = Get-VHD -Path $p -ErrorAction SilentlyContinue
                if (-not $vhd -or -not $vhd.ParentPath) { break }
                if ([IO.Path]::GetFullPath([string]$vhd.ParentPath) -ieq $full) { $users.Add($vm.Name); break }
                $p = [string]$vhd.ParentPath
            }
        }
    }
    return @($users | Select-Object -Unique)
}
