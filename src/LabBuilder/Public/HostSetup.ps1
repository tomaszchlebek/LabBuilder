function Test-LabHostPrerequisites {
    <#
    .SYNOPSIS
        Phase Preflight on the Hyper-V host: elevation, Hyper-V, disk space, memory, tools; creates the LabRoot layout.
    .OUTPUTS
        Check objects (Check, Passed, Fatal, Detail). Throws if a fatal check fails.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $results = New-Object System.Collections.Generic.List[object]
    $add = { param($Check, $Passed, $Fatal, $Detail) $results.Add([pscustomobject]@{ Check = $Check; Passed = [bool]$Passed; Fatal = [bool]$Fatal; Detail = $Detail }) }

    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    & $add 'Running elevated (Administrators)' $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) $true ([Security.Principal.WindowsIdentity]::GetCurrent().Name)

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    & $add 'Host OS build >= 17763 (Server 2019 / Windows 10 1809)' ([int]$os.BuildNumber -ge 17763) $true ('{0} build {1}' -f $os.Caption, $os.BuildNumber)

    $hv = [bool](Get-Command -Name New-VM -ErrorAction SilentlyContinue)
    & $add 'Hyper-V PowerShell module' $hv $true ''
    $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
    & $add 'Hyper-V service (vmms) running' ($vmms -and $vmms.Status -eq 'Running') $true $(if ($vmms) { [string]$vmms.Status } else { 'not installed' })

    foreach ($cmd in @('Mount-DiskImage', 'Expand-WindowsImage', 'Get-WindowsImage', 'Mount-VHD', 'Initialize-Disk')) {
        & $add "Command $cmd" ([bool](Get-Command -Name $cmd -ErrorAction SilentlyContinue)) $true ''
    }
    & $add 'bcdboot.exe' ([bool](Get-Command -Name bcdboot.exe -ErrorAction SilentlyContinue)) $true ''

    $tpm = [bool](Get-Command -Name Set-VMKeyProtector -ErrorAction SilentlyContinue)
    & $add 'vTPM support for Windows 11 (Set-VMKeyProtector)' $tpm $true ''

    $root = [string]$Config.Paths.LabRoot
    $drive = $root.Substring(0, 1)
    $vol = Get-Volume -DriveLetter $drive -ErrorAction SilentlyContinue
    if ($vol) {
        $freeGb = [math]::Round($vol.SizeRemaining / 1GB, 1)
        & $add "Free space on ${drive}: >= $($Config.Paths.MinFreeGB) GB" ($freeGb -ge [double]$Config.Paths.MinFreeGB) $true "$freeGb GB free"
    } else {
        & $add "Drive ${drive}: exists" $false $true 'drive not found'
    }

    $needMem = [int64](Get-LabVmDefinition -Config $Config | Measure-Object -Property MemoryBytes -Sum).Sum
    $freeMem = [int64]$os.FreePhysicalMemory * 1KB
    & $add ('Free memory for all VMs ({0:N0} GB)' -f ($needMem / 1GB)) ($freeMem -ge $needMem) $false ('{0:N1} GB free' -f ($freeMem / 1GB))

    $curl = [bool](Get-Command -Name curl.exe -ErrorAction SilentlyContinue)
    & $add 'curl.exe for resumable ISO downloads' $curl $false 'falls back to Invoke-WebRequest'

    foreach ($r in $results) {
        $lvl = 'OK'
        if (-not $r.Passed) { if ($r.Fatal) { $lvl = 'ERROR' } else { $lvl = 'WARN' } }
        Write-LabLog ('{0,-55} {1}' -f $r.Check, $r.Detail) -Level $lvl
    }
    $fatal = @($results | Where-Object { -not $_.Passed -and $_.Fatal })
    if ($fatal.Count -gt 0) { throw "Host preflight failed: $(($fatal | ForEach-Object Check) -join '; ')" }

    if ($vol) {
        foreach ($sub in @('', 'ISO', 'BaseImages', 'VMs', 'Logs', 'Reports')) {
            $p = Join-Path $root $sub
            if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
        }
    }
    return $results.ToArray()
}

function New-LabBaseImage {
    <#
    .SYNOPSIS
        Phase BaseImages: applies install.wim from each ISO to a read-only GPT base VHDX (ADR 0004);
        records image version and language in <base>.vhdx.json (ADR 0010).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $root = [string]$Config.Paths.LabRoot
    foreach ($key in (Get-LabRequiredImageKey -Config $Config)) {
        $img = $Config.Iso.Images.$key
        $iso = Join-Path $root "ISO\$($img.FileName)"
        $vhd = Get-LabBaseImagePath -Config $Config -Image $key
        if (Test-Path -LiteralPath $vhd) {
            Write-LabLog "Base image $key exists: $vhd (delete it with Remove-Lab.ps1 -IncludeBaseImages to rebuild)" -Level OK
            continue
        }
        if (-not (Test-Path -LiteralPath $iso)) { throw "ISO for $key not found on host: $iso - run phase Iso." }

        Write-LabLog "Building base image $key from $($img.FileName) ..." -Level STEP
        $tmp = $vhd -replace '\.vhdx$', '.building.vhdx'   # New-VHD needs the .vhdx extension
        if (Test-Path -LiteralPath $tmp) {
            Dismount-VHD -Path $tmp -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tmp -Force
        }

        $mounted = Mount-DiskImage -ImagePath $iso -StorageType ISO -PassThru
        try {
            $letter = $null
            for ($i = 0; $i -lt 20 -and -not $letter; $i++) {
                $letter = ($mounted | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
                if (-not $letter) { Start-Sleep -Seconds 1 }
            }
            if (-not $letter) { throw "Mounted $iso but it got no drive letter." }

            $wim = "$($letter):\sources\install.wim"
            if (-not (Test-Path -LiteralPath $wim)) { $wim = "$($letter):\sources\install.esd" }
            if (-not (Test-Path -LiteralPath $wim)) { throw "$($img.FileName) has no sources\install.wim or install.esd - not a Windows installation ISO." }

            $images = @(Get-WindowsImage -ImagePath $wim)
            $sel = $images | Where-Object { $_.ImageName -like $img.ImageNamePattern } | Select-Object -First 1
            if (-not $sel) {
                throw "No image matching '$($img.ImageNamePattern)' in $($img.FileName). Available: $(($images | ForEach-Object ImageName) -join ', ')"
            }
            $detail = Get-WindowsImage -ImagePath $wim -Index $sel.ImageIndex
            $language = 'en-US'
            if (@($detail.Languages).Count -gt 0) {
                $li = 0; if ($detail.DefaultLanguageIndex -ge 0) { $li = [int]$detail.DefaultLanguageIndex }
                $language = [string]@($detail.Languages)[$li]
            }
            Write-LabLog "  image index $($sel.ImageIndex): $($sel.ImageName) ($($detail.Version), $language)"

            New-VHD -Path $tmp -SizeBytes ([int64]$Config.BaseDiskSizeBytes) -Dynamic | Out-Null
            $disk = Mount-VHD -Path $tmp -Passthru | Get-Disk
            try {
                $basic = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
                $msr   = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
                $esp   = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'

                Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction Stop
                # ESP is created as basic data so it can be formatted and get a letter; type is set after bcdboot.
                $sys = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType $basic -AssignDriveLetter
                Format-Volume -Partition $sys -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false -Force | Out-Null
                New-Partition -DiskNumber $disk.Number -Size 16MB -GptType $msr | Out-Null
                $win = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType $basic -AssignDriveLetter
                Format-Volume -Partition $win -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false -Force | Out-Null

                $sys = Get-Partition -DiskNumber $disk.Number -PartitionNumber $sys.PartitionNumber
                $win = Get-Partition -DiskNumber $disk.Number -PartitionNumber $win.PartitionNumber
                if (-not $sys.DriveLetter -or -not $win.DriveLetter) { throw 'New partitions did not get drive letters (automount disabled?).' }

                Write-LabLog '  applying image (several minutes) ...'
                Expand-WindowsImage -ImagePath $wim -Index $sel.ImageIndex -ApplyPath "$($win.DriveLetter):\" -ErrorAction Stop | Out-Null

                $out = & bcdboot.exe "$($win.DriveLetter):\Windows" /s "$($sys.DriveLetter):" /f UEFI 2>&1
                if ($LASTEXITCODE -ne 0) { throw "bcdboot failed ($LASTEXITCODE): $out" }

                Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $sys.PartitionNumber -AccessPath "$($sys.DriveLetter):\"
                try {
                    Set-Partition -DiskNumber $disk.Number -PartitionNumber $sys.PartitionNumber -GptType $esp -ErrorAction Stop
                } catch {
                    $script = "select disk $($disk.Number)`r`nselect partition $($sys.PartitionNumber)`r`nset id=c12a7328-f81f-11d2-ba4b-00a0c93ec93b override`r`n"
                    $sf = Join-Path $env:TEMP 'labbuilder-esp.txt'
                    Set-Content -LiteralPath $sf -Value $script -Encoding ASCII
                    $dp = & diskpart.exe /s $sf 2>&1
                    Remove-Item -LiteralPath $sf -Force
                    if ($LASTEXITCODE -ne 0) { throw "Could not set EFI partition type: $dp" }
                }
            }
            finally {
                Dismount-VHD -Path $tmp -ErrorAction SilentlyContinue
            }
        }
        finally {
            Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null
        }

        Move-Item -LiteralPath $tmp -Destination $vhd -Force
        $info = [pscustomobject]@{
            Image = $key; IsoFile = $img.FileName; ImageName = $sel.ImageName; ImageIndex = $sel.ImageIndex
            Version = [string]$detail.Version; Language = $language
            CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        $info | ConvertTo-Json | Set-Content -LiteralPath "$vhd.json" -Encoding UTF8
        Set-ItemProperty -LiteralPath $vhd -Name IsReadOnly -Value $true
        Write-LabLog "Base image $key ready: $vhd" -Level OK
    }
}

function Get-LabBaseImagePath {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Image)
    return (Join-Path ([string]$Config.Paths.LabRoot) ("BaseImages\{0}-{1}-base.vhdx" -f $Config.LabName, $Image))
}

function New-LabNetwork {
    <#
    .SYNOPSIS
        Phase Network: creates the isolated Hyper-V switch (ADR 0005).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $name = [string]$Config.Network.SwitchName
    $type = [string]$Config.Network.SwitchType
    $sw = Get-VMSwitch -Name $name -ErrorAction SilentlyContinue
    if ($sw) {
        if ([string]$sw.SwitchType -ne $type) { throw "Switch '$name' exists with type $($sw.SwitchType), expected $type. Rename Network.SwitchName or remove the switch." }
        Write-LabLog "Switch '$name' ($type) exists." -Level OK
        return
    }
    New-VMSwitch -Name $name -SwitchType $type -Notes "LabBuilder isolated lab network ($($Config.LabName))" | Out-Null
    if ($type -eq 'Internal') { Write-LabLog "Switch '$name' is Internal: the host can reach the lab (isolation reduced)." -Level WARN }
    Write-LabLog "Switch '$name' ($type) created." -Level OK
}
