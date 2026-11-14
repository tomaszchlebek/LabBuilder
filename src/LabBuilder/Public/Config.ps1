$script:LabRoleCatalog = @('ADCS', 'IIS', 'DHCP', 'FileServer')

function Import-LabConfig {
    <#
    .SYNOPSIS
        Loads a .psd1 lab configuration, applies dotted-key overrides and returns it as a PSCustomObject.
    .DESCRIPTION
        The config is round-tripped through JSON so it has the same shape everywhere, including inside VMs (ADR 0007).
    .EXAMPLE
        Import-LabConfig -Path .\config\lab.config.example.psd1 -Overrides @{ 'Domain.Fqdn' = 'lab.test' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Overrides = @{}
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    $data = Import-LabConfigData -Path $Path -Depth 0

    foreach ($key in $Overrides.Keys) {
        $value = $Overrides[$key]
        if ($null -eq $value -or ($value -is [string] -and $value -eq '')) { continue }
        $parts = $key -split '\.'
        $node = $data
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            if (-not $node.ContainsKey($parts[$i])) { $node[$parts[$i]] = @{} }
            $node = $node[$parts[$i]]
        }
        $node[$parts[-1]] = $value
    }

    return ConvertTo-LabConfigObject -InputObject $data
}

function Import-LabConfigData {
    # Reads a .psd1; if it has BaseConfig = '<file>' (relative to this file), that file is loaded first and this one
    # is deep-merged over it: nested hashtables merge, every other value (including arrays) replaces. Used by the
    # wizard (ADR 0011) so its config holds only the tester's choices.
    param([Parameter(Mandatory)][string]$Path, [int]$Depth)
    if ($Depth -gt 5) { throw "BaseConfig chain too deep at $Path" }
    $data = Import-PowerShellDataFile -LiteralPath $Path
    if ($data.ContainsKey('BaseConfig') -and $data['BaseConfig']) {
        $basePath = [string]$data['BaseConfig']
        if (-not [IO.Path]::IsPathRooted($basePath)) { $basePath = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Path).Path) $basePath }
        if (-not (Test-Path -LiteralPath $basePath)) { throw "BaseConfig '$basePath' (from $Path) not found." }
        $base = Import-LabConfigData -Path $basePath -Depth ($Depth + 1)
        $data.Remove('BaseConfig')
        Merge-LabHashtable -Target $base -Source $data
        return $base
    }
    $data.Remove('BaseConfig')
    return $data
}

function Merge-LabHashtable {
    param([Parameter(Mandatory)][hashtable]$Target, [Parameter(Mandatory)][hashtable]$Source)
    foreach ($k in @($Source.Keys)) {
        if ($Target.ContainsKey($k) -and $Target[$k] -is [hashtable] -and $Source[$k] -is [hashtable]) {
            Merge-LabHashtable -Target $Target[$k] -Source $Source[$k]
        } else {
            $Target[$k] = $Source[$k]
        }
    }
}

function Resolve-LabConfigPath {
    <#
    .SYNOPSIS
        Explicit path, else config\lab.config.psd1, else config\lab.config.example.psd1.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$ConfigPath)
    if ($ConfigPath) { return (Resolve-Path -LiteralPath $ConfigPath).Path }
    $own = Join-Path $RepoRoot 'config\lab.config.psd1'
    if (Test-Path -LiteralPath $own) { return $own }
    return (Join-Path $RepoRoot 'config\lab.config.example.psd1')
}

function ConvertTo-LabConfigObject {
    # Hashtable/PSCustomObject or JSON string -> PSCustomObject (same shape everywhere).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$InputObject)

    if ($InputObject -is [string]) { return ($InputObject | ConvertFrom-Json) }
    return ($InputObject | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

function Get-LabDomainDN {
    <#
    .SYNOPSIS
        lab.test -> DC=lab,DC=test
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Fqdn)
    return 'DC=' + (($Fqdn.Trim('.') -split '\.') -join ',DC=')
}

function Get-LabVmDefinition {
    <#
    .SYNOPSIS
        Flattens the topology (DomainControllers, MemberServers, Workstations) into one object per VM.
    .DESCRIPTION
        Properties: Role (DomainController | MemberServer | Workstation), Index, Name, VMName, IPAddress, HostOctet,
        Image, ProcessorCount, MemoryBytes, DiskSizeBytes, Roles, AdditionalFeatures, OuName.
        Index 0 of DomainController is the forest root DC.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [ValidateSet('All', 'Server', 'DomainController', 'MemberServer', 'Workstation')][string]$Role = 'All'
    )

    $list = New-Object System.Collections.Generic.List[object]
    $make = {
        param($Name, $Octet, $RoleName, $Index, $Image, $Cpu, $Mem, $Disk, $Roles, $Extra, $Ou)
        [pscustomobject]@{
            Role               = $RoleName
            Index              = [int]$Index
            Name               = [string]$Name
            VMName             = '{0}-{1}' -f $Config.LabName, $Name
            IPAddress          = '{0}.{1}' -f $Config.Network.Prefix, $Octet
            HostOctet          = [int]$Octet
            Image              = $Image
            ProcessorCount     = [int]$Cpu
            MemoryBytes        = [int64]$Mem
            DiskSizeBytes      = [int64]$Disk
            Roles              = [string[]]@($Roles | Where-Object { $_ })
            AdditionalFeatures = [string[]]@($Extra | Where-Object { $_ })
            OuName             = $Ou
        }
    }

    $i = 0
    foreach ($s in @($Config.DomainControllers)) {
        if ($null -eq $s) { continue }
        $list.Add((& $make $s.Name $s.HostOctet 'DomainController' $i 'Server' $s.ProcessorCount $s.MemoryBytes $s.DiskSizeBytes $s.Roles $s.AdditionalFeatures $null))
        $i++
    }
    $i = 0
    foreach ($s in @($Config.MemberServers)) {
        if ($null -eq $s) { continue }
        $list.Add((& $make $s.Name $s.HostOctet 'MemberServer' $i 'Server' $s.ProcessorCount $s.MemoryBytes $s.DiskSizeBytes $s.Roles $s.AdditionalFeatures 'Servers'))
        $i++
    }
    $ws = $Config.Workstations
    if ($ws) {
        for ($n = 1; $n -le [int]$ws.Count; $n++) {
            $name = '{0}{1:D2}' -f $ws.NamePrefix, $n
            $list.Add((& $make $name ([int]$ws.FirstHostOctet + $n - 1) 'Workstation' ($n - 1) 'Client' $ws.ProcessorCount $ws.MemoryBytes $ws.DiskSizeBytes @() @() 'Workstations'))
        }
    }

    switch ($Role) {
        'All'    { return $list.ToArray() }
        'Server' { return @($list | Where-Object { $_.Role -ne 'Workstation' }) }
        default  { return @($list | Where-Object { $_.Role -eq $Role }) }
    }
}

function Get-LabRoleServer {
    # Server definitions that carry a catalog role (e.g. ADCS, IIS).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$RoleName)
    return @(Get-LabVmDefinition -Config $Config -Role Server | Where-Object { $_.Roles -contains $RoleName })
}

function Test-LabConfig {
    <#
    .SYNOPSIS
        Validates a lab config. Returns an array of error strings (empty = valid).
    .PARAMETER Scope
        Iso  - only what is needed to download ISOs (Get-LabIso.ps1)
        Host - plus lab root, network and VM topology (Remove-Lab.ps1)
        Full - plus domain, accounts and roles (Invoke-LabBuild.ps1, LabBuilderSetup.exe)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [ValidateSet('Iso', 'Host', 'Full')][string]$Scope = 'Full'
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $nameRx = '^(?![0-9]+$)[A-Za-z0-9][A-Za-z0-9-]{0,14}$'

    # --- ISO ---
    if (@($Config.Iso.AllowedDownloadHosts).Count -lt 1) { $errors.Add('Iso.AllowedDownloadHosts must list at least one host.') }
    foreach ($key in @('Server', 'Client')) {
        $img = $Config.Iso.Images.$key
        if ($null -eq $img) { $errors.Add("Iso.Images.$key is missing."); continue }
        if ([string]$img.Url -notmatch '^https://') { $errors.Add("Iso.Images.$key.Url must be an https:// URL.") }
        if ([string]$img.FileName -notmatch '^[A-Za-z0-9._-]+\.iso$') { $errors.Add("Iso.Images.$key.FileName must be a plain *.iso file name.") }
        if ($img.ExpectedSha256 -and [string]$img.ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$') { $errors.Add("Iso.Images.$key.ExpectedSha256 must be 64 hex characters or empty.") }
        if (-not $img.ImageNamePattern) { $errors.Add("Iso.Images.$key.ImageNamePattern is required.") }
    }
    if ($Scope -eq 'Iso') { return $errors.ToArray() }

    # --- Host, network, topology ---
    if ([int]$Config.SchemaVersion -ne 2) { $errors.Add('Config SchemaVersion must be 2 (DomainControllers / MemberServers / Workstations layout). Start from config\lab.config.example.psd1.'); return $errors.ToArray() }
    if ([string]$Config.LabName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$') { $errors.Add("LabName '$($Config.LabName)' must be 1-15 letters, digits or '-'.") }
    if ([string]$Config.Paths.LabRoot -notmatch '^[A-Za-z]:\\') { $errors.Add("Paths.LabRoot '$($Config.Paths.LabRoot)' must be an absolute path on a local drive of the host, e.g. D:\HyperVLab.") }
    if (@('Private', 'Internal') -notcontains $Config.Network.SwitchType) { $errors.Add("Network.SwitchType must be 'Private' or 'Internal'.") }
    if ([string]$Config.Network.SwitchName -notmatch '^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$') { $errors.Add('Network.SwitchName must be a simple name.') }
    if ([string]$Config.Network.Prefix -notmatch '^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){2}$') { $errors.Add("Network.Prefix '$($Config.Network.Prefix)' must be three octets, e.g. 10.10.10.") }
    if ([int]$Config.Network.PrefixLength -ne 24) { $errors.Add('Network.PrefixLength must be 24 (addresses are <Prefix>.<HostOctet>).') }

    $dcCount = @($Config.DomainControllers | Where-Object { $_ }).Count
    $msCount = @($Config.MemberServers | Where-Object { $_ }).Count
    if ($dcCount -lt 1 -or $dcCount -gt 5) { $errors.Add("Number of domain controllers must be 1-5 (is $dcCount).") }
    if ($msCount -gt 10) { $errors.Add("Number of member servers must be 0-10 (is $msCount).") }
    $wsCount = [int]$Config.Workstations.Count
    if ($wsCount -lt 0 -or $wsCount -gt 20) { $errors.Add("Number of workstations must be 0-20 (is $wsCount).") }
    if ([string]$Config.Workstations.NamePrefix -notmatch '^[A-Za-z][A-Za-z0-9-]{0,12}$') { $errors.Add('Workstations.NamePrefix must be 1-13 letters/digits/-, starting with a letter.') }
    if ([int]$Config.Workstations.FirstHostOctet + $wsCount - 1 -gt 254) { $errors.Add('Workstations.FirstHostOctet + Count - 1 must be <= 254.') }
    $base = [int64]$Config.BaseDiskSizeBytes
    if ($base -lt 32GB) { $errors.Add('BaseDiskSizeBytes must be >= 32GB.') }

    $defs = @()
    try { $defs = @(Get-LabVmDefinition -Config $Config) } catch { $errors.Add("Topology is invalid: $($_.Exception.Message)") }
    $names = @{}; $octets = @{}
    foreach ($d in $defs) {
        $label = "$($d.Role) $($d.Name)"
        if ($d.Name -notmatch $nameRx) { $errors.Add("Computer name '$($d.Name)' must be 1-15 letters, digits or '-' and not all digits.") }
        if ($names.ContainsKey($d.Name.ToUpperInvariant())) { $errors.Add("Duplicate computer name '$($d.Name)'.") }
        $names[$d.Name.ToUpperInvariant()] = $true
        if ($d.HostOctet -lt 1 -or $d.HostOctet -gt 254) { $errors.Add("IP host octet $($d.HostOctet) of $($d.Name) must be 1-254.") }
        if ($octets.ContainsKey($d.HostOctet)) { $errors.Add("Duplicate IP address $($d.IPAddress) ($($d.Name) and $($octets[$d.HostOctet])).") }
        $octets[$d.HostOctet] = $d.Name
        if ($d.ProcessorCount -lt 1 -or $d.ProcessorCount -gt 64) { $errors.Add("$label vCPU must be 1-64.") }
        if ($d.MemoryBytes -lt 2GB -or $d.MemoryBytes -gt 512GB) { $errors.Add("$label RAM must be 2-512 GB.") }
        $minDisk = 40GB
        if ($d.Role -eq 'Workstation') {
            $minDisk = 64GB
            if ($d.ProcessorCount -lt 2) { $errors.Add('Workstations need at least 2 vCPU (Windows 11).') }
            if ($d.MemoryBytes -lt 4GB) { $errors.Add('Workstations need at least 4 GB RAM (Windows 11).') }
        }
        if ($d.DiskSizeBytes -lt $minDisk -or $d.DiskSizeBytes -gt 2TB) { $errors.Add(("{0} disk must be {1}-2048 GB (is {2:N0} GB)." -f $label, ($minDisk / 1GB), ($d.DiskSizeBytes / 1GB))) }
        if ($d.DiskSizeBytes -lt $base) { $errors.Add("$label disk must not be smaller than BaseDiskSizeBytes.") }
        foreach ($r in $d.Roles) { if ($script:LabRoleCatalog -notcontains $r) { $errors.Add("$label has unknown role '$r' (allowed: $($script:LabRoleCatalog -join ', ')).") } }
        if (@($d.Roles | Select-Object -Unique).Count -ne @($d.Roles).Count) { $errors.Add("$label lists a role twice.") }
        foreach ($f in $d.AdditionalFeatures) { if ($f -notmatch '^[A-Za-z0-9-]+$') { $errors.Add("$label additional feature '$f' is not a valid Windows feature name.") } }
    }
    if ($Scope -eq 'Host') { return $errors.ToArray() }

    # --- Domain ---
    $fqdn = [string]$Config.Domain.Fqdn
    $fqdnRx = '^(?=.{3,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
    if ($fqdn -notmatch $fqdnRx) { $errors.Add("Domain FQDN '$fqdn' is not valid; use at least two labels, e.g. lab.test.") }
    elseif ($fqdn -match '\.local$') { $errors.Add('Do not use a .local domain (mDNS conflicts); use e.g. lab.test.') }
    $nb = [string]$Config.Domain.NetBiosName
    if ($nb -notmatch $nameRx) { $errors.Add("NetBIOS name '$nb' must be 1-15 letters, digits or '-', not all digits, no dots.") }
    if ($nb -and $names.ContainsKey($nb.ToUpperInvariant())) { $errors.Add("NetBIOS name '$nb' must differ from every computer name.") }
    if ([string]$Config.Domain.OuRoot -notmatch '^[A-Za-z0-9][A-Za-z0-9 _-]{0,62}$') { $errors.Add('Domain.OuRoot must be a simple OU name.') }

    # --- Accounts and groups ---
    $acc = $Config.Accounts
    if ([int]$acc.DomainAdminCount -lt 0 -or [int]$acc.DomainAdminCount -gt 10) { $errors.Add('Number of domain admin accounts must be 0-10.') }
    if ([int]$acc.TestUserCount -lt 0 -or [int]$acc.TestUserCount -gt 100) { $errors.Add('Number of domain test users must be 0-100.') }
    if ([int]$acc.PasswordLength -lt 12 -or [int]$acc.PasswordLength -gt 64) { $errors.Add('Accounts.PasswordLength must be 12-64.') }
    if ($acc.UpnSuffix -and [string]$acc.UpnSuffix -notmatch $fqdnRx) { $errors.Add('Accounts.UpnSuffix must be a DNS name or empty.') }
    $groups = @($Config.Groups | Where-Object { $_ })
    if ($groups.Count -lt 1) { $errors.Add('At least one security group is required (test users join the first one).') }
    $gnames = @{}
    foreach ($g in $groups) {
        if ([string]$g.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$') { $errors.Add("Group name '$($g.Name)' is not valid.") }
        if ($gnames.ContainsKey(([string]$g.Name).ToUpperInvariant())) { $errors.Add("Duplicate group '$($g.Name)'.") }
        $gnames[([string]$g.Name).ToUpperInvariant()] = $true
    }

    # --- Roles ---
    $ca = @($defs | Where-Object { $_.Roles -contains 'ADCS' })
    if ($ca.Count -gt 1) { $errors.Add("Role ADCS (Enterprise Root CA) may be on one server only (is on $(($ca | ForEach-Object Name) -join ', ')).") }
    $dhcp = @($defs | Where-Object { $_.Roles -contains 'DHCP' })
    if ($dhcp.Count -gt 1) { $errors.Add("Role DHCP may be on one server only (is on $(($dhcp | ForEach-Object Name) -join ', ')).") }
    if ($dhcp.Count -eq 1) {
        $s = [int]$Config.Roles.DHCP.RangeStartOctet; $e = [int]$Config.Roles.DHCP.RangeEndOctet
        if ($s -lt 1 -or $e -gt 254 -or $s -gt $e) { $errors.Add('Roles.DHCP range must be within 1-254 and start <= end.') }
        foreach ($d in $defs) { if ($d.HostOctet -ge $s -and $d.HostOctet -le $e) { $errors.Add("Static IP of $($d.Name) ($($d.IPAddress)) is inside the DHCP range.") } }
    }
    $iis = @($defs | Where-Object { $_.Roles -contains 'IIS' })
    if ($iis.Count -gt 0) {
        if (@($Config.Roles.IIS.Features).Count -lt 1) { $errors.Add('Roles.IIS.Features must list at least Web-Server.') }
        if ($Config.Roles.IIS.EnableHttps -and $ca.Count -eq 0) { $errors.Add('IIS HTTPS needs a certificate authority: add role ADCS to a server or set Roles.IIS.EnableHttps = $false.') }
    }
    if (@($defs | Where-Object { $_.Roles -contains 'FileServer' }).Count -gt 0) {
        if ([string]$Config.Roles.FileServer.ShareName -notmatch '^[A-Za-z0-9_-]{1,80}$') { $errors.Add('Roles.FileServer.ShareName must be 1-80 letters, digits, _ or -.') }
        if ([string]$Config.Roles.FileServer.Path -notmatch '^[A-Za-z]:\\') { $errors.Add('Roles.FileServer.Path must be an absolute local path.') }
    }

    return $errors.ToArray()
}
