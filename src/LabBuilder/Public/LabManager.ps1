# Lab manager (release 1.4.0, ADR 0015): host settings, lab and library inventory, per-lab folders, delete, config
# reconstruction. ASCII only.

function Get-LabSettingsPath {
    # %ProgramData%\LabBuilder\settings.json - one file per host, no secrets (ADR 0015).
    return (Join-Path $env:ProgramData 'LabBuilder\settings.json')
}

function Get-LabDefaultDataDrive {
    # D: if it exists, else C: (decision D8).
    if (Test-Path -LiteralPath 'D:\') { return 'D' }
    return 'C'
}

function Get-LabHostSettings {
    <#
    .SYNOPSIS
        Host settings (App, Labs and Library folder, registered external labs). Returns defaults with Exists = $false when the
        file does not exist yet (first run).
    #>
    [CmdletBinding()]
    param([string]$Path = (Get-LabSettingsPath))
    $drive = Get-LabDefaultDataDrive
    $s = [ordered]@{
        Format        = 'LabBuilder.Settings/1'
        Exists        = $false
        AppFolder     = 'C:\LabBuilder'
        LabsFolder    = "${drive}:\LabBuilder-Labs"
        LibraryFolder = "${drive}:\LabBuilder-Library"
        ExternalLabs  = @()
        UpdatedUtc    = ''
    }
    if (Test-Path -LiteralPath $Path) {
        $j = (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json
        foreach ($k in 'AppFolder', 'LabsFolder', 'LibraryFolder', 'UpdatedUtc') { if ($j.$k) { $s[$k] = [string]$j.$k } }
        $s.ExternalLabs = @($j.ExternalLabs | Where-Object { $_ -and $_.Name -and $_.LabRoot })
        $s.Exists = $true
    }
    return [pscustomobject]$s
}

function Set-LabHostSettings {
    # Writes the host settings (creates the folder). ExternalLabs: objects with Name, LabRoot, ConfigPath, OutputPath.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [string]$Path = (Get-LabSettingsPath))
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $out = [ordered]@{
        Format        = 'LabBuilder.Settings/1'
        AppFolder     = [string]$Settings.AppFolder
        LabsFolder    = [string]$Settings.LabsFolder
        LibraryFolder = [string]$Settings.LibraryFolder
        ExternalLabs  = @($Settings.ExternalLabs | Where-Object { $_ } | ForEach-Object {
            [ordered]@{ Name = [string]$_.Name; LabRoot = [string]$_.LabRoot; ConfigPath = [string]$_.ConfigPath; OutputPath = [string]$_.OutputPath } })
        UpdatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
    }
    ConvertTo-Json -InputObject $out -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-LabOutputPath {
    <#
    .SYNOPSIS
        Where a lab keeps its credentials, summary and reports: Paths.OutputPath (labs created with 1.4.0+: <LabRoot>\output),
        else the 1.0-1.3 location <App>\output\<LabName>.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$AppFolder)
    $p = [string]$Config.Paths.OutputPath
    if ($p) { return $p.TrimEnd('\') }
    return (Join-Path $AppFolder ("output\{0}" -f $Config.LabName))
}

function Get-LabFolderSize {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { return 0 }
    return [int64]$sum
}

function Get-LabInventory {
    <#
    .SYNOPSIS
        All labs on this host (ADR 0015): subfolders of the Labs folder with lab.json, registered external labs (1.0-1.3 layout),
        and labs found only through tagged VMs (notes 'LabBuilder:<Lab> | ...', lab folder = parent of the VMs folder).
    .OUTPUTS
        Objects: Name, Domain, LabRoot, ConfigPath, HasConfig, OutputPath, Source (Labs|External|Discovered), Version, DiskType,
        LastPhase, CreatedUtc, UpdatedUtc, Switch, VMs (Name, VMName, Role, Image, IPAddress, State), SizeBytes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [switch]$NoSize)
    $labs = @{}
    $vmIndex = @{}
    $hyperV = [bool](Get-Command -Name Get-VM -ErrorAction SilentlyContinue)
    if ($hyperV) {
        foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue)) { $vmIndex[$vm.Name] = $vm }
    }
    $add = {
        param($Root, $Source, $ConfigPath, $OutputPath)
        $manifest = $null
        $mf = Join-Path $Root 'lab.json'
        if (Test-Path -LiteralPath $mf) { try { $manifest = (Get-Content -LiteralPath $mf -Raw) | ConvertFrom-Json } catch { } }
        $name = ''
        if ($manifest) { $name = [string]$manifest.LabName }
        if (-not $name) {
            $st = Join-Path $Root 'state.json'
            if (Test-Path -LiteralPath $st) { try { $name = [string]((Get-Content -LiteralPath $st -Raw | ConvertFrom-Json).LabName) } catch { } }
        }
        if (-not $name) { return }
        $key = $name.ToUpperInvariant()
        if ($labs.ContainsKey($key)) { return }
        if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'lab.config.psd1' }
        if (-not $OutputPath) {
            $own = Join-Path $Root 'output'
            if (Test-Path -LiteralPath $own) { $OutputPath = $own } else { $OutputPath = Join-Path ([string]$Settings.AppFolder) "output\$name" }
        }
        $vms = @()
        if ($manifest) {
            $vms = @($manifest.VMs | Where-Object { $_ } | ForEach-Object {
                $state = 'missing'
                if ($vmIndex.ContainsKey([string]$_.VMName)) { $state = [string]$vmIndex[[string]$_.VMName].State }
                [pscustomobject]@{ Name = [string]$_.Name; VMName = [string]$_.VMName; Role = [string]$_.Role; Image = [string]$_.Image; IPAddress = [string]$_.IPAddress; State = $state }
            })
        }
        $size = 0
        if (-not $NoSize) { $size = Get-LabFolderSize -Path $Root }
        $labs[$key] = [pscustomobject]@{
            Name       = $name
            Domain     = $(if ($manifest) { [string]$manifest.Domain } else { '' })
            LabRoot    = $Root
            ConfigPath = $ConfigPath
            HasConfig  = (Test-Path -LiteralPath $ConfigPath)
            OutputPath = $OutputPath
            Source     = $Source
            Version    = $(if ($manifest) { [string]$manifest.Version } else { '' })
            DiskType   = $(if ($manifest -and $manifest.DiskType) { [string]$manifest.DiskType } else { 'Dynamic' })
            LastPhase  = $(if ($manifest) { [string]$manifest.LastPhase } else { '' })
            CreatedUtc = $(if ($manifest) { [string]$manifest.CreatedUtc } else { '' })
            UpdatedUtc = $(if ($manifest) { [string]$manifest.UpdatedUtc } else { '' })
            Switch     = $(if ($manifest -and $manifest.Switch) { [string]$manifest.Switch.Name } else { '' })
            VMs        = $vms
            SizeBytes  = $size
        }
    }

    # 1. Labs folder
    $labsFolder = [string]$Settings.LabsFolder
    if ($labsFolder -and (Test-Path -LiteralPath $labsFolder)) {
        foreach ($d in @(Get-ChildItem -LiteralPath $labsFolder -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'lab.json')) { & $add $d.FullName 'Labs' $null $null }
        }
    }
    # 2. Registered external labs
    foreach ($e in @($Settings.ExternalLabs)) {
        if ($e -and (Test-Path -LiteralPath ([string]$e.LabRoot))) { & $add ([string]$e.LabRoot) 'External' ([string]$e.ConfigPath) ([string]$e.OutputPath) }
    }
    # 3. Tagged VMs whose lab folder is not known yet (<LabRoot>\VMs\<VMName>)
    foreach ($vm in $vmIndex.Values) {
        if ([string]$vm.Notes -notmatch '^LabBuilder:([A-Za-z0-9-]+) ') { continue }
        if ($labs.ContainsKey($Matches[1].ToUpperInvariant())) { continue }
        $vmsDir = Split-Path -Parent ([string]$vm.Path)
        if ((Split-Path -Leaf $vmsDir) -ne 'VMs') { $vmsDir = Split-Path -Parent $vmsDir }
        $root = Split-Path -Parent $vmsDir
        if ($root -and (Test-Path -LiteralPath $root)) { & $add $root 'Discovered' $null $null }
    }
    return @($labs.Values | Sort-Object Name)
}

function Register-LabExternal {
    <#
    .SYNOPSIS
        Registers labs found outside the Labs folder (1.0-1.3 layout) in the host settings, in place (decision D7). Returns the
        settings object.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][object[]]$Labs)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($Settings.ExternalLabs)) { if ($e) { $list.Add($e) } }
    foreach ($l in $Labs) {
        if ($l.Source -ne 'Discovered') { continue }
        if (@($list | Where-Object { [string]$_.Name -ieq $l.Name }).Count) { continue }
        $list.Add([pscustomobject]@{ Name = $l.Name; LabRoot = $l.LabRoot; ConfigPath = $l.ConfigPath; OutputPath = $l.OutputPath })
    }
    $Settings.ExternalLabs = $list.ToArray()
    return $Settings
}

function Get-LabLibraryInventory {
    <#
    .SYNOPSIS
        What the image library holds (ADR 0015): per OS of the catalog the ISO (size, SHA-256, recorded) and the base image
        (Windows version, language, created, ISO match, VMs whose differencing disks use it), plus ISO files the manifest does not know.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LibraryRoot, [Parameter(Mandatory)]$Catalog, [switch]$NoUsers)
    $isoDir = Join-Path $LibraryRoot 'ISO'
    $baseDir = Join-Path $LibraryRoot 'BaseImages'
    $manifest = @{}
    if (Test-Path -LiteralPath $isoDir) { $manifest = Read-LabIsoManifest -Folder $isoDir }
    $items = New-Object System.Collections.Generic.List[object]
    # Servers first, newest first (Server2025, 2022, 2019), then workstations (Win11LTSC, Win10).
    $ordered = @($Catalog.PSObject.Properties | Sort-Object @{ Expression = { if ([string]$_.Value.Kind -eq 'Server') { 0 } else { 1 } } }, @{ Expression = { $_.Name }; Descending = $true })
    foreach ($p in $ordered) {
        $key = $p.Name; $img = $p.Value
        $isoPath = Join-Path $isoDir ([string]$img.FileName)
        $entry = $manifest[[string]$img.FileName]
        $isoOk = (Test-Path -LiteralPath $isoPath) -and $entry -and (Get-Item -LiteralPath $isoPath).Length -eq [int64]$entry.Length
        $vhd = Join-Path $baseDir "$key.vhdx"
        $side = $null
        if (Test-Path -LiteralPath "$vhd.json") { try { $side = (Get-Content -LiteralPath "$vhd.json" -Raw) | ConvertFrom-Json } catch { } }
        $users = @()
        if (-not $NoUsers -and (Test-Path -LiteralPath $vhd)) { $users = @(Get-LabBaseImageUser -Path $vhd) }
        $items.Add([pscustomobject]@{
            Key          = $key
            Description  = [string]$img.Description
            Supplied     = [bool]$img.Supplied
            IsoPresent   = [bool]$isoOk
            IsoFile      = [string]$img.FileName
            IsoBytes     = $(if ($entry) { [int64]$entry.Length } else { 0 })
            IsoSha256    = $(if ($entry) { [string]$entry.Sha256 } else { '' })
            IsoRecorded  = $(if ($entry) { [string]$entry.RecordedUtc } else { '' })
            BasePresent  = (Test-Path -LiteralPath $vhd)
            BaseVersion  = $(if ($side) { [string]$side.Version } else { '' })
            BaseLanguage = $(if ($side) { [string]$side.Language } else { '' })
            BaseCreated  = $(if ($side) { [string]$side.CreatedUtc } else { '' })
            BaseCurrent  = $(if ($side -and $entry -and $side.IsoSha256) { [string]$side.IsoSha256 -eq [string]$entry.Sha256 } else { [bool]$side })
            UsedBy       = $users
        })
    }
    # Role-ready images (ADR 0016): <OS>-Roles.vhdx next to the plain bases.
    foreach ($p in $ordered) {
        $vhd = Join-Path $baseDir ("{0}-Roles.vhdx" -f $p.Name)
        if (-not (Test-Path -LiteralPath $vhd)) { continue }
        $side = $null
        if (Test-Path -LiteralPath "$vhd.json") { try { $side = (Get-Content -LiteralPath "$vhd.json" -Raw) | ConvertFrom-Json } catch { } }
        $plainSide = $null
        $plainJson = Join-Path $baseDir ("{0}.vhdx.json" -f $p.Name)
        if (Test-Path -LiteralPath $plainJson) { try { $plainSide = (Get-Content -LiteralPath $plainJson -Raw) | ConvertFrom-Json } catch { } }
        $users = @()
        if (-not $NoUsers) { $users = @(Get-LabBaseImageUser -Path $vhd) }
        $items.Add([pscustomobject]@{
            Key = "$($p.Name)-Roles"; Description = "$($p.Value.Description) - role-ready for DCs (AD DS, DNS)"; Supplied = $false
            IsoPresent = $false; IsoFile = ''; IsoBytes = 0; IsoSha256 = ''; IsoRecorded = ''
            BasePresent = $true; BaseVersion = $(if ($side) { [string]$side.Version } else { '' }); BaseLanguage = $(if ($side) { [string]$side.Language } else { '' })
            BaseCreated = $(if ($side) { [string]$side.CreatedUtc } else { '' })
            BaseCurrent = [bool]($side -and $plainSide -and [string]$side.ParentCreatedUtc -eq [string]$plainSide.CreatedUtc -and (Test-LabRoleImageCurrent -Path $vhd))
            UsedBy = $users
        })
    }
    $known = @($Catalog.PSObject.Properties | ForEach-Object { ([string]$_.Value.FileName).ToUpperInvariant() })
    $unknown = @()
    if (Test-Path -LiteralPath $isoDir) {
        $unknown = @(Get-ChildItem -LiteralPath $isoDir -Filter *.iso -File -ErrorAction SilentlyContinue | Where-Object { $known -notcontains $_.Name.ToUpperInvariant() } |
            ForEach-Object { [pscustomobject]@{ FileName = $_.Name; Bytes = $_.Length; Modified = $_.LastWriteTime.ToString('yyyy-MM-dd') } })
    }
    return [pscustomobject]@{ LibraryRoot = $LibraryRoot; Images = $items.ToArray(); UnknownIsos = $unknown }
}

function Restore-LabLegacyConfig {
    <#
    .SYNOPSIS
        Labs built before 1.4.0 shared <App>\config\lab.config.psd1; the wizard kept a backup (lab.config.psd1.bak-<time>) before
        each build. For a lab without its own config this finds the newest of those files with the same LabName and LabRoot and
        copies it into the lab folder as lab.config.psd1 (BaseConfig made absolute). Returns the new path, or '' if none matches.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lab, [Parameter(Mandatory)][string]$AppFolder)
    $cfgDir = Join-Path $AppFolder 'config'
    if (-not (Test-Path -LiteralPath $cfgDir)) { return '' }
    $candidates = @(Get-ChildItem -LiteralPath $cfgDir -File -Filter 'lab.config.psd1*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    foreach ($f in $candidates) {
        try { $d = Import-PowerShellDataFile -LiteralPath $f.FullName } catch { continue }
        $root = ''; if ($d.Paths) { $root = [string]$d.Paths.LabRoot }
        if ([string]$d.LabName -ine [string]$Lab.Name) { continue }
        if ($root -and $Lab.LabRoot -and ($root.TrimEnd('\') -ine ([string]$Lab.LabRoot).TrimEnd('\'))) { continue }
        $text = [IO.File]::ReadAllText($f.FullName)
        $base = (Join-Path $cfgDir 'lab.config.example.psd1').Replace("'", "''")
        $text = [regex]::Replace($text, "(?m)^(\s*BaseConfig\s*=\s*)'[^']*'", ('$1' + "'" + $base.Replace('$', '$$') + "'"))
        $text = "# Restored by LabBuilder $((Get-Date).ToString('yyyy-MM-dd HH:mm')) from $($f.Name) (labs before 1.4.0 shared one config file).`r`n" + $text
        [IO.File]::WriteAllText([string]$Lab.ConfigPath, $text, [Text.Encoding]::ASCII)
        return [string]$Lab.ConfigPath
    }
    return ''
}

function New-LabConfigFromInventory {
    <#
    .SYNOPSIS
        Reconstructs a lab config (.psd1 text) from lab.json + Hyper-V when the lab's own config is lost (ADR 0015 point 6): names,
        OS, IPs, vCPU, RAM, disk size. Catalog roles are not recorded and are left for the tester to confirm in the wizard; the
        NetBIOS name is guessed from the domain (first label) and must be confirmed too.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lab, [Parameter(Mandatory)][string]$BaseConfig, [string]$LibraryRoot)
    $q = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
    $gb = { param($b) [int][math]::Round([double]$b / 1GB) }
    $line = {
        param($v)
        $cpu = 2; $mem = 4; $disk = 80
        $vm = Get-VM -Name $v.VMName -ErrorAction SilentlyContinue
        if ($vm) {
            $cpu = [int]$vm.ProcessorCount; $mem = & $gb $vm.MemoryStartup
            $hdd = Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hdd) { $vhd = Get-VHD -Path $hdd.Path -ErrorAction SilentlyContinue; if ($vhd) { $disk = & $gb $vhd.Size } }
        }
        $octet = ([string]$v.IPAddress -split '\.')[-1]
        '        @{{ Name = {0}; Image = {1}; HostOctet = {2}; ProcessorCount = {3}; MemoryBytes = {4}GB; DiskSizeBytes = {5}GB; Roles = @(); AdditionalFeatures = @() }}' -f (& $q $v.Name), (& $q $v.Image), $octet, $cpu, $mem, $disk
    }
    $vms = @($Lab.VMs)
    $dcs = @($vms | Where-Object Role -eq 'DomainController')
    $ms = @($vms | Where-Object Role -eq 'MemberServer')
    $ws = @($vms | Where-Object Role -eq 'Workstation' | Sort-Object Name)
    $prefix = ''
    if ($vms.Count) { $prefix = ((([string]$vms[0].IPAddress) -split '\.')[0..2]) -join '.' }
    $nb = (([string]$Lab.Domain) -split '\.')[0].ToUpperInvariant()
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# Reconstructed by LabBuilder $((Get-Date).ToString('yyyy-MM-dd HH:mm')) from lab.json and Hyper-V - the original config was not found.")
    [void]$sb.AppendLine('# Confirm the NetBIOS name and tick the roles of each server in the wizard before building again. ASCII only.')
    [void]$sb.AppendLine('@{')
    [void]$sb.AppendLine("    BaseConfig    = $(& $q $BaseConfig)")
    [void]$sb.AppendLine('    SchemaVersion = 2')
    [void]$sb.AppendLine("    LabName       = $(& $q $Lab.Name)")
    $lib = ''; if ($LibraryRoot) { $lib = $LibraryRoot }
    [void]$sb.AppendLine("    Paths   = @{ LabRoot = $(& $q $Lab.LabRoot); LibraryRoot = $(& $q $lib); OutputPath = $(& $q $Lab.OutputPath) }")
    [void]$sb.AppendLine("    Domain  = @{ Fqdn = $(& $q $Lab.Domain); NetBiosName = $(& $q $nb) }")
    if ($Lab.Switch) { [void]$sb.AppendLine("    Network = @{ SwitchName = $(& $q $Lab.Switch); Prefix = $(& $q $prefix) }") }
    [void]$sb.AppendLine("    Disks   = @{ Type = $(& $q $Lab.DiskType) }")
    [void]$sb.AppendLine('    DomainControllers = @(')
    foreach ($v in $dcs) { [void]$sb.AppendLine((& $line $v)) }
    [void]$sb.AppendLine('    )')
    if ($ms.Count -eq 0) { [void]$sb.AppendLine('    MemberServers = @()') }
    else { [void]$sb.AppendLine('    MemberServers = @('); foreach ($v in $ms) { [void]$sb.AppendLine((& $line $v)) }; [void]$sb.AppendLine('    )') }
    if ($ws.Count -gt 0) {
        $first = $ws[0]
        $wsPrefix = ([string]$first.Name) -replace '\d+$', ''
        $wsOctet = ([string]$first.IPAddress -split '\.')[-1]
        $wl = (& $line $first)
        $cpu = [regex]::Match($wl, 'ProcessorCount = (\d+)').Groups[1].Value
        $mem = [regex]::Match($wl, 'MemoryBytes = (\d+)GB').Groups[1].Value
        $disk = [regex]::Match($wl, 'DiskSizeBytes = (\d+)GB').Groups[1].Value
        [void]$sb.AppendLine(("    Workstations = @{{ Image = {0}; Count = {1}; NamePrefix = {2}; FirstHostOctet = {3}; ProcessorCount = {4}; MemoryBytes = {5}GB; DiskSizeBytes = {6}GB }}" -f (& $q $first.Image), $ws.Count, (& $q $wsPrefix), $wsOctet, $cpu, $mem, $disk))
    } else {
        [void]$sb.AppendLine('    Workstations = @{ Count = 0 }')
    }
    [void]$sb.AppendLine('}')
    return $sb.ToString()
}

function Remove-LabFromInventory {
    <#
    .SYNOPSIS
        Deletes a lab found by Get-LabInventory (ADR 0015): its VMs (from lab.json and every VM tagged LabBuilder:<Lab>), their
        checkpoints and disks, the lab's switch if no other VM uses it, the lab's own files (VMs, Logs, Reports, output with
        credentials, lab.json, state.json, lab.config.psd1) and the lab folder if it is then empty, and its registration.
        Never touches the image library.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)]$Lab, [Parameter(Mandatory)]$Settings)
    $name = [string]$Lab.Name
    Write-LabLog "=== Delete lab $name ($($Lab.LabRoot)) on $env:COMPUTERNAME ===" -Level STEP
    $vmNames = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($Lab.VMs)) { if ($v.VMName) { $vmNames.Add([string]$v.VMName) } }
    if (Get-Command -Name Get-VM -ErrorAction SilentlyContinue) {
        foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue | Where-Object { ([string]$_.Notes).StartsWith("LabBuilder:$name ") })) {
            if (-not $vmNames.Contains($vm.Name)) { $vmNames.Add($vm.Name) }
        }
        foreach ($n in $vmNames) {
            $vm = Get-VM -Name $n -ErrorAction SilentlyContinue
            if (-not $vm) { continue }
            if (-not $PSCmdlet.ShouldProcess($n, 'Turn off and delete VM, checkpoints and disks')) { continue }
            if ($vm.State -ne 'Off') { Stop-VM -Name $n -TurnOff -Force -ErrorAction SilentlyContinue }
            Get-VMSnapshot -VMName $n -ErrorAction SilentlyContinue | Remove-VMSnapshot -IncludeAllChildSnapshots -ErrorAction SilentlyContinue
            $disks = @(Get-VMHardDiskDrive -VMName $n -ErrorAction SilentlyContinue | ForEach-Object Path)
            Remove-VM -Name $n -Force
            foreach ($d in $disks) {
                $lib = [string]$Settings.LibraryFolder
                if ($lib -and $d.StartsWith($lib, [StringComparison]::OrdinalIgnoreCase)) { continue }   # never a library file
                Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
            }
            Write-LabLog "  removed VM $n"
        }
        $sw = [string]$Lab.Switch
        if ($sw -and (Get-VMSwitch -Name $sw -ErrorAction SilentlyContinue)) {
            $users = @(Get-VMNetworkAdapter -All -ErrorAction SilentlyContinue | Where-Object { $_.SwitchName -eq $sw -and $_.VMName })
            if ($users.Count) { Write-LabLog "  switch $sw kept - used by $(($users | ForEach-Object VMName | Select-Object -Unique) -join ', ')" -Level WARN }
            elseif ($PSCmdlet.ShouldProcess($sw, 'Remove virtual switch')) { Remove-VMSwitch -Name $sw -Force; Write-LabLog "  removed switch $sw" }
        }
    }
    $root = [string]$Lab.LabRoot
    if ($root -and (Test-Path -LiteralPath $root)) {
        foreach ($n in $vmNames) {
            $d = Join-Path $root "VMs\$n"
            if ((Test-Path -LiteralPath $d) -and $PSCmdlet.ShouldProcess($d, 'Delete folder')) { Remove-Item -LiteralPath $d -Recurse -Force }
        }
        foreach ($sub in 'Logs', 'Reports', 'output') {
            $d = Join-Path $root $sub
            if ((Test-Path -LiteralPath $d) -and $PSCmdlet.ShouldProcess($d, 'Delete folder')) { Remove-Item -LiteralPath $d -Recurse -Force }
        }
        foreach ($f in 'lab.json', 'state.json', 'lab.config.psd1') {
            $p = Join-Path $root $f
            if ((Test-Path -LiteralPath $p) -and $PSCmdlet.ShouldProcess($p, 'Delete file')) { Remove-Item -LiteralPath $p -Force }
        }
        $vmsDir = Join-Path $root 'VMs'
        if ((Test-Path -LiteralPath $vmsDir) -and -not (Get-ChildItem -LiteralPath $vmsDir -Force)) { Remove-Item -LiteralPath $vmsDir -Force }
        if (-not (Get-ChildItem -LiteralPath $root -Force)) {
            if ($PSCmdlet.ShouldProcess($root, 'Delete empty lab folder')) { Remove-Item -LiteralPath $root -Force; Write-LabLog "  removed $root" }
        } else {
            Write-LabLog "  $root kept - it still contains other files" -Level WARN
        }
    }
    $out = [string]$Lab.OutputPath
    if ($out -and (Test-Path -LiteralPath $out) -and $PSCmdlet.ShouldProcess($out, 'Delete credentials and reports')) { Remove-Item -LiteralPath $out -Recurse -Force; Write-LabLog "  removed $out" }
    if (-not $WhatIfPreference) {
        $Settings.ExternalLabs = @($Settings.ExternalLabs | Where-Object { $_ -and [string]$_.Name -ine $name })
        if ($Settings.Exists) { Set-LabHostSettings -Settings $Settings }
    }
    Write-LabLog "=== Lab $name deleted (image library kept) ===" -Level OK
}
