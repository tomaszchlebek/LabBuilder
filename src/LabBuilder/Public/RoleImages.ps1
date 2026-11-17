# Role-ready base images (release 1.4.1, ADR 0016): AD DS and DNS enabled OFFLINE (DISM) in a copy of the plain base image - no
# sysprep (Microsoft does not support sysprep with AD DS / AD CS installed). Used by domain controllers only. ASCII only.
#
# NOT AD CS: host test 2026-11-17 - Install-ADDSForest refuses a server with the AD CS binaries ("Verification of prerequisites for
# Domain Controller promotion failed. Certificate Server is installed."), and a CA server must not change domain membership after
# AD CS is installed. AD CS stays an online install after promotion / domain join.

# Optional-feature names (DISM) enabled in the role image; names a Windows build does not have are skipped. The online
# Install-WindowsFeature step still runs on every DC and adds whatever is missing (management tools etc.).
$script:LabRoleImageFeaturePatterns = @(
    '^DirectoryServices-DomainController$'
    '^DirectoryServices-DomainController-Tools$'
    '^DirectoryServices-AdministrativeCenter$'
    '^ActiveDirectory-PowerShell$'
    '^DNS-Server-Full-Role$'
    '^DNS-Server-Tools$'
)
# Recorded in the sidecar; an image with another (older) feature set is outdated - rebuilt, and never used for new VMs.
$script:LabRoleImageFeatureSet = 'ADDS-DNS/2'

function Test-LabRoleImageCurrent {
    # True when <OS>-Roles.vhdx exists and was made with the current feature set (1.4.1 test images with AD CS are not).
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path) -or -not (Test-Path -LiteralPath "$Path.json")) { return $false }
    try { $side = (Get-Content -LiteralPath "$Path.json" -Raw) | ConvertFrom-Json } catch { return $false }
    return ([string]$side.FeatureSet -eq $script:LabRoleImageFeatureSet)
}

function Test-LabRoleImagesEnabled {
    # Build.RoleImages = $false switches role-ready base images off (DCs / CA servers then use the plain base image).
    param([Parameter(Mandatory)]$Config)
    if ($Config.Build -and $Config.Build.PSObject.Properties['RoleImages'] -and -not [bool]$Config.Build.RoleImages) { return $false }
    return $true
}

function Get-LabRoleImageKey {
    # Server OS keys whose role image the lab needs: the OS of every domain controller.
    param([Parameter(Mandatory)]$Config)
    if (-not (Test-LabRoleImagesEnabled -Config $Config)) { return @() }
    return @(Get-LabVmDefinition -Config $Config | Where-Object { $_.Kind -eq 'Server' -and $_.Role -eq 'DomainController' } |
        Select-Object -ExpandProperty Image -Unique)
}

function Get-LabVmBaseImageKey {
    <#
    .SYNOPSIS
        Base image a VM is created from: '<OS>-Roles' for domain controllers when a current role image exists (and the option is
        on), otherwise the plain '<OS>' base image (all other servers, CA member servers and workstations).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Definition)
    $d = $Definition
    if ((Test-LabRoleImagesEnabled -Config $Config) -and $d.Kind -eq 'Server' -and $d.Role -eq 'DomainController') {
        $k = "$($d.Image)-Roles"
        if (Test-LabRoleImageCurrent -Path (Get-LabBaseImagePath -Config $Config -Image $k)) { return $k }
    }
    return [string]$d.Image
}

function New-LabRoleBaseImageItem {
    <#
    .SYNOPSIS
        Builds <Library>\BaseImages\<OS>-Roles.vhdx from the plain <OS>.vhdx: copy, mount, enable AD DS / DNS offline with
        DISM, dismount, read-only + sidecar. Never booted, never sysprepped (ADR 0016). Rebuilt when the plain base changes, unless
        differencing disks use it. On any error: warning, nothing left behind, DCs use the plain base. Caller holds the lock.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Key)
    $plain = Get-LabBaseImagePath -Config $Config -Image $Key
    $role = Get-LabBaseImagePath -Config $Config -Image "$Key-Roles"
    if (-not (Test-Path -LiteralPath $plain) -or -not (Test-Path -LiteralPath "$plain.json")) { Write-LabLog "Role image $Key-Roles skipped - plain base image $plain missing." -Level WARN; return }
    $pside = (Get-Content -LiteralPath "$plain.json" -Raw) | ConvertFrom-Json

    if (Test-Path -LiteralPath $role) {
        $side = $null
        if (Test-Path -LiteralPath "$role.json") { try { $side = (Get-Content -LiteralPath "$role.json" -Raw) | ConvertFrom-Json } catch { } }
        $sameSet = $side -and [string]$side.FeatureSet -eq $script:LabRoleImageFeatureSet
        if ($sameSet -and [string]$side.ParentCreatedUtc -eq [string]$pside.CreatedUtc) { Write-LabLog "Role image $Key-Roles in library: $role" -Level OK; return }
        $why = 'was made from an older ' + $Key + ' base'
        if (-not $sameSet) { $why = 'has an older feature set (with AD CS)' }
        $users = @(Get-LabBaseImageUser -Path $role)
        if ($users.Count -gt 0) {
            Write-LabLog "Role image $Key-Roles $why, but differencing disks of $($users -join ', ') use it - kept; new DCs use the plain $Key base until those VMs are gone." -Level WARN
            return
        }
        Write-LabLog "Role image $Key-Roles $why - rebuilding." -Level WARN
        Set-ItemProperty -LiteralPath $role -Name IsReadOnly -Value $false
        Remove-Item -LiteralPath $role, "$role.json" -Force -ErrorAction SilentlyContinue
    }

    Write-LabLog "Building role-ready base image $Key-Roles for domain controllers (AD DS, DNS enabled offline - once per OS, a few minutes) ..." -Level STEP
    $tmp = $role -replace '\.vhdx$', '.building.vhdx'
    if (Test-Path -LiteralPath $tmp) { Dismount-VHD -Path $tmp -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $tmp -Force }
    $enabled = @()
    try {
        Copy-Item -LiteralPath $plain -Destination $tmp -Force
        Set-ItemProperty -LiteralPath $tmp -Name IsReadOnly -Value $false
        $enabled = Invoke-LabLibraryLock -Name 'VhdMount' -TimeoutMinutes 30 -Quiet -ScriptBlock {
            $disk = Mount-VHD -Path $tmp -Passthru -ErrorAction Stop | Get-Disk -ErrorAction Stop
            try {
                $win = $null
                foreach ($p in @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -eq 'Basic' })) {
                    if (-not $p.DriveLetter) { $p | Add-PartitionAccessPath -AssignDriveLetter; $p = Get-Partition -DiskNumber $disk.Number -PartitionNumber $p.PartitionNumber }
                    if ($p.DriveLetter -and (Test-Path -LiteralPath "$($p.DriveLetter):\Windows\System32")) { $win = $p; break }
                }
                if (-not $win) { throw "No Windows partition in $tmp." }
                $root = "$($win.DriveLetter):\"
                $available = @(Get-WindowsOptionalFeature -Path $root -ErrorAction Stop | ForEach-Object FeatureName)
                $want = @($available | Where-Object { $n = $_; @($script:LabRoleImageFeaturePatterns | Where-Object { $n -match $_ }).Count -gt 0 })
                if (-not ($want -contains 'DirectoryServices-DomainController')) { throw 'the image has no DirectoryServices-DomainController feature' }
                Write-LabLog "  enabling offline: $($want -join ', ')"
                Enable-WindowsOptionalFeature -Path $root -FeatureName $want -All -LimitAccess -NoRestart -ErrorAction Stop | Out-Null
                return $want
            } finally {
                Dismount-VHD -Path $tmp -ErrorAction SilentlyContinue
            }
        }
        Move-Item -LiteralPath $tmp -Destination $role -Force
        [pscustomobject]@{
            Image = "$Key-Roles"; Parent = $Key; ParentCreatedUtc = [string]$pside.CreatedUtc; IsoSha256 = [string]$pside.IsoSha256
            Version = [string]$pside.Version; Language = [string]$pside.Language; Features = @($enabled); FeatureSet = $script:LabRoleImageFeatureSet
            Method = 'DISM offline (Enable-WindowsOptionalFeature), not booted, no sysprep'; CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath "$role.json" -Encoding UTF8
        Set-ItemProperty -LiteralPath $role -Name IsReadOnly -Value $true
        Write-LabLog "Role image $Key-Roles ready: $role" -Level OK
    } catch {
        Write-LabLog "Role image $Key-Roles could not be built ($($_.Exception.Message)) - domain controllers use the plain $Key base image (AD DS installed online as before)." -Level WARN
        if (Test-Path -LiteralPath $tmp) { Dismount-VHD -Path $tmp -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-LabUnconfiguredCa {
    <#
    .SYNOPSIS
        Before a DC promotion: if the VM has AD CS binaries installed but no configured CA (a VM made from a 1.4.1 test role image
        with AD CS), uninstall them and restart - Install-ADDSForest / Install-ADDSDomainController refuse with "Certificate Server
        is installed". A configured CA is never touched. Returns $true when something was removed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][pscredential]$Credential, [int]$TimeoutMinutes = 30)
    $r = Invoke-LabVMCommand -VMName $VMName -Credential $Credential -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $active = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -ErrorAction SilentlyContinue).Active
        if ($active) { return 'configured' }
        $names = @(Get-WindowsFeature -Name 'ADCS-Cert-Authority', 'AD-Certificate' -ErrorAction SilentlyContinue | Where-Object Installed | ForEach-Object Name)
        if ($names.Count -eq 0) { return 'none' }
        $u = Uninstall-WindowsFeature -Name $names
        if (-not $u.Success) { throw "Uninstall-WindowsFeature $($names -join ', ') failed: $($u.ExitCode)" }
        return ('removed:' + [string]$u.RestartNeeded)
    }
    if ([string]$r -like 'removed:*') {
        Write-LabLog "  ${VMName}: unconfigured AD CS binaries removed before the promotion (from an older role image)." -Level WARN
        Restart-LabVM -VMName $VMName -Credential $Credential -TimeoutMinutes $TimeoutMinutes
        return $true
    }
    return $false
}
