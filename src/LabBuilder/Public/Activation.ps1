# Windows Server activation with AVMA (release 1.4.3, ADR 0017). ASCII only.
#
# The Microsoft evaluation ISOs install "Standard Evaluation", which in an isolated lab never activates online and stops after
# 10 days (then shuts down every hour, like the expired Windows 11 LTSC evaluation). A Windows Server Datacenter Hyper-V host that is
# activated can activate Windows Server guests with AVMA (Automatic Virtual Machine Activation) - offline, over the Data Exchange
# (KVP) integration service. AVMA keys do not install on an evaluation edition, so:
#   1. Phase BaseImages converts the library base image offline: DISM /Image /Set-Edition:ServerStandard with a key DISM accepts
#      for the conversion (2025/2022: the AVMA key; 2019: the KMS client setup key - DISM rejects the 2019 AVMA key offline).
#      It must happen before any DC promotion: Microsoft does not allow converting a domain controller.
#   2. Each server VM installs the AVMA key (slmgr /ipk) and activates (slmgr /ato) right after its network setup.
# Verified on ITOMHV01 (Server 2025 Datacenter) 2026-11-17 with throwaway VMs: 2025 and 2019 activated ("Licensed", host event
# 12310 hr=0x0); 2022 converted offline. The keys below are Microsoft's public generic keys (Microsoft Learn: "Automatic
# Virtual Machine Activation", "KMS client activation keys") - not secrets.
#
# Workstations are not covered: AVMA activates Windows Server only, and a Windows client evaluation cannot be converted.

$script:LabAvmaCatalog = @{
    Server2025 = @{ Build = 26100; Edition = 'ServerStandard'; ConvertKey = 'WWVGQ-PNHV9-B89P4-8GGM9-9HPQ4'; AvmaKey = 'WWVGQ-PNHV9-B89P4-8GGM9-9HPQ4' }
    Server2022 = @{ Build = 20348; Edition = 'ServerStandard'; ConvertKey = 'YDFWN-MJ9JR-3DYRK-FXXRW-78VHK'; AvmaKey = 'YDFWN-MJ9JR-3DYRK-FXXRW-78VHK' }
    Server2019 = @{ Build = 17763; Edition = 'ServerStandard'; ConvertKey = 'N69G4-B89J2-4G8F4-WWYCC-J464C'; AvmaKey = 'TNK62-RXVTB-4P47B-2D623-4GF74' }
}

function Test-LabAvmaEnabled {
    # Build.Avma = $false switches AVMA off (servers stay evaluation editions: 10 days in an isolated lab).
    param([Parameter(Mandatory)]$Config)
    if ($Config.Build -and $Config.Build.PSObject.Properties['Avma'] -and -not [bool]$Config.Build.Avma) { return $false }
    return $true
}

function Get-LabAvmaEntry {
    # AVMA data of a catalog OS key, or $null (client OS, unknown or a role image key '<OS>-Roles' -> its OS).
    param([Parameter(Mandatory)][string]$Key)
    $k = $Key -replace '-Roles$', ''
    if ($script:LabAvmaCatalog.ContainsKey($k)) { return $script:LabAvmaCatalog[$k] }
    return $null
}

function Get-LabAvmaHostVerdict {
    # Pure: can this host activate a guest of build $GuestBuild? AVMA needs an activated Datacenter host whose version is
    # the guest's version or newer (Microsoft Learn table: a 2025 host activates 2025..2012 R2 guests).
    param([string]$Caption, [int]$LicenseStatus, [int]$HostBuild, [int]$GuestBuild)
    if ($Caption -notmatch 'Datacenter') { return [pscustomobject]@{ Supported = $false; Reason = "the host runs $Caption - AVMA needs Windows Server Datacenter" } }
    if ($LicenseStatus -ne 1) { return [pscustomobject]@{ Supported = $false; Reason = 'the host itself is not activated' } }
    if ($HostBuild -lt $GuestBuild) { return [pscustomobject]@{ Supported = $false; Reason = "the host (build $HostBuild) is older than the guest OS (build $GuestBuild)" } }
    return [pscustomobject]@{ Supported = $true; Reason = '' }
}

function Get-LabAvmaHostSupport {
    # Verdict for this host and a catalog OS key (reads the host OS and its licence once per call).
    param([Parameter(Mandatory)][string]$Key)
    $e = Get-LabAvmaEntry -Key $Key
    if (-not $e) { return [pscustomobject]@{ Supported = $false; Reason = "$Key is not a Windows Server OS with an AVMA key" } }
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $lic = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue) | Select-Object -First 1
    $status = -1; if ($lic) { $status = [int]$lic.LicenseStatus }
    return Get-LabAvmaHostVerdict -Caption ([string]$os.Caption) -LicenseStatus $status -HostBuild ([int]$os.BuildNumber) -GuestBuild ([int]$e.Build)
}

function Update-LabBaseImageEdition {
    <#
    .SYNOPSIS
        Converts the library base image of a Windows Server OS from Evaluation to Standard offline (DISM /Set-Edition) so its VMs
        can activate with AVMA. Works on a copy, then replaces the base; records Edition/Activation in the sidecar and a new
        CreatedUtc (role images are then rebuilt from it). Skipped with a warning when differencing disks use the base, the host
        cannot activate this OS, or DISM fails - the base stays an evaluation. Caller holds the base image lock.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Key)
    if (-not (Test-LabAvmaEnabled -Config $Config)) { return }
    $e = Get-LabAvmaEntry -Key $Key
    if (-not $e) { return }
    $vhd = Get-LabBaseImagePath -Config $Config -Image $Key
    if (-not (Test-Path -LiteralPath $vhd) -or -not (Test-Path -LiteralPath "$vhd.json")) { return }
    $side = (Get-Content -LiteralPath "$vhd.json" -Raw) | ConvertFrom-Json
    if ([string]$side.Edition -eq [string]$e.Edition) { return }

    $support = Get-LabAvmaHostSupport -Key $Key
    if (-not $support.Supported) { Write-LabLog "Base image $Key stays an evaluation edition (10 days in an isolated lab): $($support.Reason)." -Level WARN; return }
    $users = @(Get-LabBaseImageUser -Path $vhd)
    if ($users.Count -gt 0) {
        Write-LabLog "Base image $Key stays an evaluation edition: differencing disks of $($users -join ', ') use it. New VMs are not activated until those VMs are gone." -Level WARN
        return
    }

    Write-LabLog "Converting base image $Key from Evaluation to $($e.Edition) for AVMA (offline, about a minute) ..." -Level STEP
    $tmp = $vhd -replace '\.vhdx$', '.converting.vhdx'
    if (Test-Path -LiteralPath $tmp) { Dismount-VHD -Path $tmp -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $tmp -Force }
    try {
        Copy-Item -LiteralPath $vhd -Destination $tmp -Force
        Set-ItemProperty -LiteralPath $tmp -Name IsReadOnly -Value $false
        $edition = Invoke-LabLibraryLock -Name 'VhdMount' -TimeoutMinutes 30 -Quiet -ScriptBlock {
            $disk = Mount-VHD -Path $tmp -Passthru -ErrorAction Stop | Get-Disk -ErrorAction Stop
            try {
                $win = $null
                foreach ($p in @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -eq 'Basic' })) {
                    if (-not $p.DriveLetter) { $p | Add-PartitionAccessPath -AssignDriveLetter; $p = Get-Partition -DiskNumber $disk.Number -PartitionNumber $p.PartitionNumber }
                    if ($p.DriveLetter -and (Test-Path -LiteralPath "$($p.DriveLetter):\Windows\System32")) { $win = $p; break }
                }
                if (-not $win) { throw "No Windows partition in $tmp." }
                $root = "$($win.DriveLetter):\"
                $cur = Get-LabImageEdition -Root $root
                if ($cur -ne $e.Edition) {
                    if ($cur -notmatch 'Eval$') { throw "the image is $cur, not an evaluation edition" }
                    # The key goes on the DISM command line: a public generic key (see the file header), not a secret.
                    $out = & dism.exe /English "/Image:$root" "/Set-Edition:$($e.Edition)" "/ProductKey:$($e.ConvertKey)" /AcceptEula 2>&1
                    if ($LASTEXITCODE -ne 0) { throw ("DISM /Set-Edition failed ({0}): {1}" -f $LASTEXITCODE, ((@($out) | Where-Object { "$_".Trim() } | Select-Object -Last 2) -join ' ')) }
                    $cur = Get-LabImageEdition -Root $root
                }
                return $cur
            } finally {
                Dismount-VHD -Path $tmp -ErrorAction SilentlyContinue
            }
        }
        if ($edition -ne $e.Edition) { throw "edition after conversion is '$edition'" }
        Set-ItemProperty -LiteralPath $vhd -Name IsReadOnly -Value $false
        Move-Item -LiteralPath $tmp -Destination $vhd -Force
        $side | Add-Member -NotePropertyName EvaluationCreatedUtc -NotePropertyValue ([string]$side.CreatedUtc) -Force
        $side | Add-Member -NotePropertyName Edition -NotePropertyValue $edition -Force
        $side | Add-Member -NotePropertyName Activation -NotePropertyValue 'AVMA' -Force
        $side | Add-Member -NotePropertyName CreatedUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
        $side | ConvertTo-Json | Set-Content -LiteralPath "$vhd.json" -Encoding UTF8
        Set-ItemProperty -LiteralPath $vhd -Name IsReadOnly -Value $true
        Write-LabLog "Base image $Key is now $edition - its VMs activate with AVMA." -Level OK
    } catch {
        Write-LabLog "Base image $Key could not be converted for AVMA ($($_.Exception.Message)) - it stays an evaluation edition." -Level WARN
        if (Test-Path -LiteralPath $tmp) { Dismount-VHD -Path $tmp -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-LabImageEdition {
    # Edition ID of an offline Windows image (e.g. ServerStandardEval, ServerStandard).
    param([Parameter(Mandatory)][string]$Root)
    $out = & dism.exe /English "/Image:$Root" /Get-CurrentEdition 2>&1
    $line = @($out) | Where-Object { "$_" -match 'Current Edition\s*:\s*(\S+)' } | Select-Object -First 1
    if ($line -and ("$line" -match 'Current Edition\s*:\s*(\S+)')) { return $Matches[1] }
    throw "DISM could not read the edition of $Root ($LASTEXITCODE)."
}

function Enable-LabVMActivation {
    <#
    .SYNOPSIS
        Activates a Windows Server VM with AVMA: installs the generic AVMA key and runs slmgr /ato inside the VM. Idempotent
        (an AVMA-activated VM is left alone). Never throws - a VM that cannot be activated keeps running, with a warning.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][pscredential]$Credential)
    $d = $Definition
    if ($d.Kind -ne 'Server' -or -not (Test-LabAvmaEnabled -Config $Config)) { return }
    $e = Get-LabAvmaEntry -Key ([string]$d.Image)
    if (-not $e) { return }
    try {
        $support = Get-LabAvmaHostSupport -Key ([string]$d.Image)
        if (-not $support.Supported) { Write-LabLog "  $($d.VMName): not activated - $($support.Reason)." -Level WARN; return }
        $r = Invoke-LabVMCommand -VMName $d.VMName -Credential $Credential -RetryCount 2 -RetryDelaySeconds 15 -ArgumentList $e.AvmaKey -ScriptBlock {
            param($Key)
            $q = { @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL") | Select-Object -First 1 }
            $os = Get-CimInstance Win32_OperatingSystem
            if ($os.Caption -like '*Evaluation*') { return 'evaluation' }
            $p = & $q
            if ($p -and [int]$p.LicenseStatus -eq 1 -and [string]$p.Description -match 'VIRTUAL_MACHINE_ACTIVATION') { return 'already' }
            $slmgr = Join-Path $env:windir 'System32\slmgr.vbs'
            if (-not ($p -and [string]$p.Description -match 'VIRTUAL_MACHINE_ACTIVATION')) { $null = & cscript.exe //nologo $slmgr /ipk $Key 2>&1 }
            $last = ''
            for ($i = 0; $i -lt 4; $i++) {
                $last = (& cscript.exe //nologo $slmgr /ato 2>&1 | Out-String).Trim()
                $p = & $q
                if ($p -and [int]$p.LicenseStatus -eq 1) { return 'activated' }
                Start-Sleep -Seconds 15
            }
            return "failed: $last"
        }
        switch -Wildcard ([string]$r) {
            'activated' { Write-LabLog "  $($d.VMName): Windows activated with AVMA." -Level OK }
            'already' { Write-LabLog "  $($d.VMName): Windows already activated (AVMA)." }
            'evaluation' { Write-LabLog "  $($d.VMName): evaluation edition (built from a base image made before 1.4.3 or with AVMA off) - not activated; it stops after its evaluation period." -Level WARN }
            default { Write-LabLog "  $($d.VMName): AVMA activation did not succeed ($r) - check the Data Exchange integration service and the host's licence." -Level WARN }
        }
    } catch {
        Write-LabLog "  $($d.VMName): AVMA activation skipped ($($_.Exception.Message))." -Level WARN
    }
}
