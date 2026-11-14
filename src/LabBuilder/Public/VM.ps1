function New-LabVM {
    <#
    .SYNOPSIS
        Creates one lab VM: differencing disk on the base image, unattend.xml injected, Gen 2, Secure Boot,
        vTPM for Windows 11, connected only to the lab switch; then starts it. Skips an existing VM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][pscredential]$AdminCredential
    )

    $vmName = $Definition.VMName
    $existing = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.State -ne 'Running') { Start-VM -Name $vmName | Out-Null }
        Write-LabLog "VM $vmName exists ($($existing.State))." -Level OK
        return
    }

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

    # Independent dynamic VHDX: copy of the base, expanded to the tester's size (ADR 0008).
    Write-LabLog ('  disk: dynamic VHDX {0:N0} GB (copy of {1})' -f ($Definition.DiskSizeBytes / 1GB), (Split-Path $base -Leaf))
    Copy-Item -LiteralPath $base -Destination $diskPath -Force
    Set-ItemProperty -LiteralPath $diskPath -Name IsReadOnly -Value $false
    try { Set-VHD -Path $diskPath -ResetDiskIdentifier -Force -ErrorAction Stop } catch { Write-LabLog "  could not reset disk identifier: $($_.Exception.Message)" -Level WARN }
    if ((Get-VHD -Path $diskPath).Size -lt $Definition.DiskSizeBytes) { Resize-VHD -Path $diskPath -SizeBytes $Definition.DiskSizeBytes }

    # Locale (host settings, image language) and unattend.xml
    $imageLanguage = ''
    $sidecar = "$base.json"
    if (Test-Path -LiteralPath $sidecar) { $imageLanguage = [string]((Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json).Language) }
    $locale = Resolve-LabLocale -Config $Config -ImageLanguage $imageLanguage
    Write-LabLog "  locale: UI $($locale.UILanguage), input $($locale.InputLocale), system $($locale.SystemLocale), user $($locale.UserLocale), time zone '$($locale.TimeZone)'"
    $xml = New-LabUnattendXml -Image $Definition.Image -ComputerName $Definition.Name -AdminCredential $AdminCredential -Locale $locale

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

    New-VM -Name $vmName -Generation 2 -MemoryStartupBytes $Definition.MemoryBytes -VHDPath $diskPath `
        -SwitchName $Config.Network.SwitchName -Path (Join-Path $root 'VMs') | Out-Null
    Set-VM -Name $vmName -ProcessorCount $Definition.ProcessorCount -StaticMemory -AutomaticCheckpointsEnabled $false `
        -AutomaticStartAction Nothing -AutomaticStopAction ShutDown `
        -Notes "LabBuilder lab '$($Config.LabName)': $($Definition.Role) $($Definition.Name) $($Definition.IPAddress)"
    Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    if ($Definition.Image -eq 'Client') {
        Set-VMKeyProtector -VMName $vmName -NewLocalKeyProtector
        Enable-VMTPM -VMName $vmName
    }
    Get-VMIntegrationService -VMName $vmName | Where-Object { -not $_.Enabled } | Enable-VMIntegrationService -ErrorAction SilentlyContinue
    Start-VM -Name $vmName | Out-Null
    Write-LabLog "VM $vmName started." -Level OK
}
