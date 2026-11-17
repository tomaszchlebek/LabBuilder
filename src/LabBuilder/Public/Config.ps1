$script:LabRoleCatalog = @('ADCS', 'IIS', 'DHCP', 'FileServer', 'SQL')

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
        Image (OS catalog key, e.g. Server2022), Kind (Server | Client), ProcessorCount, MemoryBytes, DiskSizeBytes, Roles, AdditionalFeatures, OuName.
        Index 0 of DomainController is the forest root DC.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [ValidateSet('All', 'Server', 'DomainController', 'MemberServer', 'Workstation')][string]$Role = 'All'
    )

    $list = New-Object System.Collections.Generic.List[object]
    # OS per VM (ADR 0013): Image = catalog key in Iso.Images; Kind (Server/Client) comes from the catalog entry.
    $defaultServer = [string]$Config.Iso.DefaultServerImage
    if (-not $defaultServer) { $defaultServer = 'Server2025' }
    $make = {
        param($Name, $Octet, $RoleName, $Index, $Image, $Cpu, $Mem, $Disk, $Roles, $Extra, $Ou)
        $kind = $null
        $entry = $null
        if ($Image -and $Config.Iso.Images) { $entry = $Config.Iso.Images.PSObject.Properties[[string]$Image] }
        if ($entry) { $kind = [string]$entry.Value.Kind }
        [pscustomobject]@{
            Role               = $RoleName
            Index              = [int]$Index
            Name               = [string]$Name
            VMName             = '{0}-{1}' -f $Config.LabName, $Name
            IPAddress          = '{0}.{1}' -f $Config.Network.Prefix, $Octet
            HostOctet          = [int]$Octet
            Image              = [string]$Image
            Kind               = $kind
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
        $img = $defaultServer; if ($s.Image) { $img = [string]$s.Image }
        $list.Add((& $make $s.Name $s.HostOctet 'DomainController' $i $img $s.ProcessorCount $s.MemoryBytes $s.DiskSizeBytes $s.Roles $s.AdditionalFeatures $null))
        $i++
    }
    $i = 0
    foreach ($s in @($Config.MemberServers)) {
        if ($null -eq $s) { continue }
        $img = $defaultServer; if ($s.Image) { $img = [string]$s.Image }
        $list.Add((& $make $s.Name $s.HostOctet 'MemberServer' $i $img $s.ProcessorCount $s.MemoryBytes $s.DiskSizeBytes $s.Roles $s.AdditionalFeatures 'Servers'))
        $i++
    }
    $ws = $Config.Workstations
    if ($ws) {
        $wsImage = 'Win11LTSC'; if ($ws.Image) { $wsImage = [string]$ws.Image }
        for ($n = 1; $n -le [int]$ws.Count; $n++) {
            $name = '{0}{1:D2}' -f $ws.NamePrefix, $n
            $list.Add((& $make $name ([int]$ws.FirstHostOctet + $n - 1) 'Workstation' ($n - 1) $wsImage $ws.ProcessorCount $ws.MemoryBytes $ws.DiskSizeBytes @() @() 'Workstations'))
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

function Test-LabSqlConfig {
    # Rules for role SQL (ADR 0012). Returns error strings.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [object[]]$Definitions = @(), [string[]]$GroupNames = @())
    $errors = New-Object System.Collections.Generic.List[string]
    $sqlServers = @($Definitions | Where-Object { $_.Roles -contains 'SQL' })
    if ($sqlServers.Count -eq 0) { return $errors.ToArray() }
    foreach ($d in @($sqlServers | Where-Object Role -eq 'DomainController')) {
        $errors.Add("Role SQL is not supported on domain controller $($d.Name); put SQL Server on a member server.")
    }
    $sql = $Config.Roles.SQL
    if (-not $sql) { $errors.Add('Roles.SQL settings are missing (see config\lab.config.example.psd1).'); return $errors.ToArray() }
    if ([string]$sql.BootstrapperUrl -notmatch '^https://') { $errors.Add('Roles.SQL.BootstrapperUrl must be an https:// URL.') }
    if ([string]$sql.PackagePattern -notmatch '^[A-Za-z0-9_*?.-]+\.exe$') { $errors.Add('Roles.SQL.PackagePattern must be a file pattern ending in .exe.') }
    if ([string]$sql.MediaType -notmatch '^[A-Za-z]{1,20}$') { $errors.Add('Roles.SQL.MediaType must be a single word, e.g. Core.') }
    $inst = [string]$sql.InstanceName
    if ($inst -notmatch '^[A-Za-z_][A-Za-z0-9_$]{0,15}$' -or $inst.ToUpperInvariant() -eq 'DEFAULT') {
        $errors.Add("Roles.SQL.InstanceName '$inst' must be 1-16 letters, digits or _ starting with a letter (MSSQLSERVER = default instance).")
    }
    $port = [int]$sql.TcpPort
    if ($port -ne 1433 -and ($port -lt 1024 -or $port -gt 65535)) { $errors.Add('Roles.SQL.TcpPort must be 1433 or 1024-65535.') }
    if (@('Windows', 'Mixed') -notcontains [string]$sql.AuthenticationMode) { $errors.Add("Roles.SQL.AuthenticationMode must be Windows or Mixed.") }
    $known = @{}; foreach ($g in $GroupNames) { $known[$g.ToUpperInvariant()] = $true }
    foreach ($key in 'SysadminGroups', 'DbOwnerGroups') {
        foreach ($g in @($sql.$key | Where-Object { $_ })) {
            if (-not $known.ContainsKey(([string]$g).ToUpperInvariant())) { $errors.Add("Roles.SQL.$key lists '$g', which is not one of the lab groups.") }
        }
    }
    $db = [string]$sql.DatabaseName
    if ($db -and $db -notmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$') { $errors.Add("Roles.SQL.DatabaseName '$db' must be 1-64 letters, digits or _ starting with a letter (or empty).") }
    if ($db -and @('MASTER', 'MODEL', 'MSDB', 'TEMPDB') -contains $db.ToUpperInvariant()) { $errors.Add("Roles.SQL.DatabaseName '$db' is a system database name.") }
    if ([string]$sql.Collation -and [string]$sql.Collation -notmatch '^[A-Za-z0-9_]{3,128}$') { $errors.Add('Roles.SQL.Collation must be a collation name such as Latin1_General_CI_AS (or empty).') }
    $t = [int]$sql.SetupTimeoutMinutes
    if ($t -lt 10 -or $t -gt 240) { $errors.Add('Roles.SQL.SetupTimeoutMinutes must be 10-240.') }
    return $errors.ToArray()
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
    # OS catalog (ADR 0013)
    $catalog = @()
    if ($Config.Iso.Images) { $catalog = @($Config.Iso.Images.PSObject.Properties) }
    $catalogKeys = @($catalog | ForEach-Object Name)
    if (($catalogKeys -contains 'Server' -or $catalogKeys -contains 'Client') -and $catalogKeys -notcontains 'Server2025') {
        $errors.Add('Iso.Images uses the LabBuilder 1.0/1.1 keys Server/Client. Copy the Iso section from config\lab.config.example.psd1 (OS catalog Server2025, Server2022, Server2019, Win11LTSC, Win10).')
        return $errors.ToArray()
    }
    if ($catalog.Count -lt 1) { $errors.Add('Iso.Images (OS catalog) is empty.') }
    foreach ($p in $catalog) {
        $key = $p.Name; $img = $p.Value
        if ($key -notmatch '^[A-Za-z][A-Za-z0-9]{1,30}$') { $errors.Add("Iso.Images key '$key' must be letters and digits."); continue }
        if (@('Server', 'Client') -notcontains [string]$img.Kind) { $errors.Add("Iso.Images.$key.Kind must be Server or Client.") }
        if ($img.Supplied) {
            if ($img.SourcePath -and [string]$img.SourcePath -notmatch '^([A-Za-z]:\\|\\\\).+\.iso$') { $errors.Add("Iso.Images.$key.SourcePath must be the full path of an .iso file (or empty).") }
        } elseif ([string]$img.Url -notmatch '^https://') { $errors.Add("Iso.Images.$key.Url must be an https:// URL.") }
        if ([string]$img.FileName -notmatch '^[A-Za-z0-9._-]+\.iso$') { $errors.Add("Iso.Images.$key.FileName must be a plain *.iso file name.") }
        if ($img.ExpectedSha256 -and [string]$img.ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$') { $errors.Add("Iso.Images.$key.ExpectedSha256 must be 64 hex characters or empty.") }
        if (-not $img.ImageNamePattern) { $errors.Add("Iso.Images.$key.ImageNamePattern is required.") }
        if (-not $img.CaptionPattern) { $errors.Add("Iso.Images.$key.CaptionPattern is required (used by the validation).") }
    }
    $fileNames = @($catalog | ForEach-Object { ([string]$_.Value.FileName).ToUpperInvariant() })
    if (@($fileNames | Select-Object -Unique).Count -ne $fileNames.Count) { $errors.Add('Iso.Images: every image needs its own FileName.') }
    $defServer = [string]$Config.Iso.DefaultServerImage
    if ($defServer -and ($catalogKeys -notcontains $defServer -or [string]$Config.Iso.Images.$defServer.Kind -ne 'Server')) {
        $errors.Add("Iso.DefaultServerImage '$defServer' must be a Server image of the catalog ($(@($catalog | Where-Object { $_.Value.Kind -eq 'Server' } | ForEach-Object Name) -join ', ')).")
    }
    if ($Scope -eq 'Iso') { return $errors.ToArray() }

    # --- Host, network, topology ---
    if ([int]$Config.SchemaVersion -ne 2) { $errors.Add('Config SchemaVersion must be 2 (DomainControllers / MemberServers / Workstations layout). Start from config\lab.config.example.psd1.'); return $errors.ToArray() }
    if ([string]$Config.LabName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$') { $errors.Add("LabName '$($Config.LabName)' must be 1-15 letters, digits or '-'.") }
    if ([string]$Config.Paths.LabRoot -notmatch '^[A-Za-z]:\\') { $errors.Add("Paths.LabRoot '$($Config.Paths.LabRoot)' must be an absolute path on a local drive of the host, e.g. D:\HyperVLab.") }
    $outPath = [string]$Config.Paths.OutputPath
    if ($outPath -and $outPath -notmatch '^[A-Za-z]:\\') { $errors.Add("Paths.OutputPath '$outPath' must be an absolute local path (or empty for <App>\output\<LabName>).") }
    $lib = [string]$Config.Paths.LibraryRoot
    if ($lib -and $lib -notmatch '^[A-Za-z]:\\') { $errors.Add("Paths.LibraryRoot '$lib' must be an absolute path on a local drive of the host (or empty for <LabRoot drive>:\LabBuilder-Library).") }
    elseif ($lib -and [string]$Config.Paths.LabRoot -and ($lib.TrimEnd('\') + '\').StartsWith(([string]$Config.Paths.LabRoot).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $errors.Add('Paths.LibraryRoot must not be inside Paths.LabRoot (the library is shared by all labs).')
    }
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
    if ($Config.Disks -and @('Dynamic', 'Differencing') -notcontains [string]$Config.Disks.Type) { $errors.Add("Disks.Type must be Dynamic or Differencing.") }
    if ($Config.Build -and $Config.Build.PSObject.Properties['ThrottleLimit']) {
        $tl = [int]$Config.Build.ThrottleLimit
        if ($tl -lt 0 -or $tl -gt 32) { $errors.Add('Build.ThrottleLimit must be 0 (auto) to 32.') }
    }

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
        $wantKind = 'Server'; if ($d.Role -eq 'Workstation') { $wantKind = 'Client' }
        if ($catalogKeys -notcontains $d.Image) {
            $errors.Add("$label uses OS '$($d.Image)', which is not in the OS catalog ($(@($catalog | Where-Object { $_.Value.Kind -eq $wantKind } | ForEach-Object Name) -join ', ')).")
        } elseif ($d.Kind -ne $wantKind) {
            $errors.Add("$label uses OS '$($d.Image)', a $($d.Kind) image; $($d.Role) needs a $wantKind image.")
        }
        $minDisk = 40GB
        if ($d.Role -eq 'Workstation') {
            $minDisk = 64GB
            if ($d.ProcessorCount -lt 2) { $errors.Add('Workstations need at least 2 vCPU.') }
            if ($d.MemoryBytes -lt 4GB) { $errors.Add('Workstations need at least 4 GB RAM.') }
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

    # --- Domain controller OS order ---
    # A DC newer than the forest root DC makes dcpromo run adprep against the root, which fails
    # in the lab ("Adprep was unable to bind to any Domain Controller over RPC", host run six).
    $dcs = @($defs | Where-Object { $_.Role -eq 'DomainController' })
    if ($dcs.Count -gt 1) {
        $rootYear = 0
        if ([string]$dcs[0].Image -match '(\d{4})') { $rootYear = [int]$Matches[1] }
        foreach ($dc in ($dcs | Select-Object -Skip 1)) {
            $y = 0
            if ([string]$dc.Image -match '(\d{4})') { $y = [int]$Matches[1] }
            if ($rootYear -gt 0 -and $y -gt $rootYear) {
                $errors.Add("Domain controller $($dc.Name) runs $($dc.Image), newer than the first DC $($dcs[0].Name) ($($dcs[0].Image)). Put the newest Windows Server on DC 1 (the forest root) or use the same OS on all DCs.")
            }
        }
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
    foreach ($e in (Test-LabSqlConfig -Config $Config -Definitions $defs -GroupNames ([string[]]@($groups | ForEach-Object { [string]$_.Name })))) { $errors.Add($e) }

    # --- Tester-supplied ISOs (Windows 10, ADR 0013) ---
    foreach ($key in @($defs | ForEach-Object Image | Select-Object -Unique)) {
        $img = $Config.Iso.Images.$key
        if ($img -and $img.Supplied -and -not [string]$img.SourcePath) {
            $errors.Add("$($img.Description): choose the ISO file (Iso.Images.$key.SourcePath) - Microsoft offers no evaluation download for it.")
        }
    }

    return $errors.ToArray()
}
