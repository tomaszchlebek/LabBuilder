# Shared image library and lab manifest (FR-21, FR-23, ADR 0013). ASCII only.

function Get-LabLibraryRoot {
    <#
    .SYNOPSIS
        Image library folder shared by all labs on the host: Paths.LibraryRoot, else <LabRoot drive>:\LabBuilder-Library.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $lib = [string]$Config.Paths.LibraryRoot
    if ($lib) { return $lib.TrimEnd('\') }
    return ('{0}:\LabBuilder-Library' -f ([string]$Config.Paths.LabRoot).Substring(0, 1))
}

function Get-LabLibraryIsoFolder {
    # <Library>\ISO - ISOs, iso-manifest.json and the SQL\ media folder.
    param([Parameter(Mandatory)]$Config)
    return (Join-Path (Get-LabLibraryRoot -Config $Config) 'ISO')
}

function Invoke-LabLibraryLock {
    <#
    .SYNOPSIS
        Runs a script block while holding the host-wide named mutex Global\LabBuilder-Library-<Name>, so two lab builds
        never download, import or build the same library item at the same time (ADR 0013). A crashed holder releases
        the mutex automatically (abandoned mutex = acquired).
    .NOTES
        Inside the script block use 'return', not 'continue' (the block runs in its own scope).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$TimeoutMinutes = 240,
        [switch]$Quiet   # short internal locks (VHD mount, certificate template): waiting is normal in a parallel build
    )
    $mutex = New-Object System.Threading.Mutex($false, "Global\LabBuilder-Library-$Name")
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) {
            if (-not $Quiet) { Write-LabLog "  another LabBuilder build is preparing library item '$Name' - waiting for it ..." -Level WARN }
            try { $owned = $mutex.WaitOne([TimeSpan]::FromMinutes($TimeoutMinutes)) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
            if (-not $owned) { throw "Timed out after $TimeoutMinutes min waiting for library item '$Name' (held by another build)." }
        }
        & $ScriptBlock
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Set-LabIsoManifestEntry {
    # Read-modify-write of one iso-manifest.json entry under the manifest lock (several labs may update it).
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)]$Entry)
    Invoke-LabLibraryLock -Name 'IsoManifest' -TimeoutMinutes 10 -ScriptBlock {
        $map = Read-LabIsoManifest -Folder $Folder
        $map[[string]$Entry.FileName] = $Entry
        Write-LabIsoManifest -Folder $Folder -Map $map
    }
}

function Move-LabLegacyMedia {
    <#
    .SYNOPSIS
        One-time migration (ADR 0013): ISOs and SQL media that LabBuilder 1.0/1.1 kept in <LabRoot>\ISO are moved into the
        image library, so nothing is downloaded again. Same volume = instant move; another volume = move + SHA-256 check.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $legacy = Join-Path ([string]$Config.Paths.LabRoot) 'ISO'
    $dest = Get-LabLibraryIsoFolder -Config $Config
    if (-not (Test-Path -LiteralPath $legacy) -or $legacy -eq $dest) { return }
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    $sameVolume = [IO.Path]::GetPathRoot($legacy) -eq [IO.Path]::GetPathRoot($dest)
    $legacyManifest = Read-LabIsoManifest -Folder $legacy

    foreach ($p in @($Config.Iso.Images.PSObject.Properties)) {
        $key = $p.Name; $img = $p.Value
        $fileName = [string]$img.FileName
        $from = Join-Path $legacy $fileName
        $old = $legacyManifest[$fileName]
        if (-not $old -or -not (Test-Path -LiteralPath $from)) { continue }
        Invoke-LabLibraryLock -Name "Iso-$key" -ScriptBlock {
            $to = Join-Path $dest $fileName
            if ((Test-Path -LiteralPath $to) -and (Read-LabIsoManifest -Folder $dest)[$fileName]) {
                Write-LabLog "ISO $key is already in the library; the old copy $from is left in place (delete it to free space)." -Level WARN
                return
            }
            Write-LabLog "Moving ISO $key from the lab folder into the image library: $to" -Level STEP
            Move-Item -LiteralPath $from -Destination $to -Force
            $item = Get-Item -LiteralPath $to
            if ($item.Length -ne [int64]$old.Length) { throw "Moved $fileName has $($item.Length) bytes, manifest says $($old.Length)." }
            if (-not $sameVolume) {
                $hash = (Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash.ToUpperInvariant()
                if ($hash -ne [string]$old.Sha256) { throw "Moved $fileName has SHA-256 $hash, manifest says $($old.Sha256)." }
            }
            $entry = New-LabIsoManifestEntry -Key $key -Image $img -Path $to -Sha256 ([string]$old.Sha256) -ResolvedUrl ([string]$old.ResolvedUrl)
            Set-LabIsoManifestEntry -Folder $dest -Entry $entry
            $legacyManifest.Remove($fileName)
            Write-LabIsoManifest -Folder $legacy -Map $legacyManifest
            Write-LabLog "ISO $key moved into the library (SHA-256 $($old.Sha256))." -Level OK
        }
    }

    $legacySql = Join-Path $legacy 'SQL'
    $destSql = Join-Path $dest 'SQL'
    if ((Test-Path -LiteralPath (Join-Path $legacySql 'sql-media.json')) -and -not (Test-Path -LiteralPath (Join-Path $destSql 'sql-media.json'))) {
        Invoke-LabLibraryLock -Name 'SQL' -ScriptBlock {
            Write-LabLog "Moving SQL Server media from the lab folder into the image library: $destSql" -Level STEP
            if (-not (Test-Path -LiteralPath $destSql)) { New-Item -ItemType Directory -Path $destSql -Force | Out-Null }
            Get-ChildItem -LiteralPath $legacySql -File | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination (Join-Path $destSql $_.Name) -Force }
            Write-LabLog 'SQL Server media moved into the library.' -Level OK
        }
    }
}

function Import-LabSuppliedIso {
    <#
    .SYNOPSIS
        Copies an ISO the tester supplies (Iso.Images.<Key>.SourcePath, e.g. Windows 10 - no Microsoft evaluation exists)
        into the library as <FileName>, records SHA-256 and the source file; a different source replaces it (ADR 0013).
    .OUTPUTS
        The manifest entry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Destination)
    $img = $Config.Iso.Images.$Key
    $path = Join-Path $Destination ([string]$img.FileName)
    $source = [string]$img.SourcePath
    Invoke-LabLibraryLock -Name "Iso-$Key" -ScriptBlock {
        $entry = (Read-LabIsoManifest -Folder $Destination)[[string]$img.FileName]
        if (-not $source) {
            if ($entry -and (Test-Path -LiteralPath $path)) { Write-LabLog "ISO $Key (supplied) in library: $path" -Level OK; return $entry }
            throw "$($img.Description): no ISO file chosen (Iso.Images.$Key.SourcePath)."
        }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "$($img.Description): ISO file not found on this host: $source" }
        $si = Get-Item -LiteralPath $source
        if ($entry -and (Test-Path -LiteralPath $path) -and [string]$entry.SourcePath -eq $si.FullName -and
            [int64]$entry.SourceLength -eq $si.Length -and [int64]$entry.SourceLastWriteTicks -eq $si.LastWriteTimeUtc.Ticks -and
            (Get-Item -LiteralPath $path).Length -eq [int64]$entry.Length) {
            Write-LabLog "ISO $Key (supplied) already imported from $source (SHA-256 $($entry.Sha256))" -Level OK
            return $entry
        }
        Write-LabLog ('Importing the supplied ISO {0} from {1} ({2:N1} GB) ...' -f $Key, $source, ($si.Length / 1GB)) -Level STEP
        Copy-Item -LiteralPath $source -Destination "$path.partial" -Force -ErrorAction Stop
        Move-Item -LiteralPath "$path.partial" -Destination $path -Force
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($img.ExpectedSha256 -and $hash -ne ([string]$img.ExpectedSha256).ToUpperInvariant()) {
            Remove-Item -LiteralPath $path -Force
            throw "$source has SHA-256 $hash, Iso.Images.$Key.ExpectedSha256 is $($img.ExpectedSha256)."
        }
        $new = New-LabIsoManifestEntry -Key $Key -Image $img -Path $path -Sha256 $hash -ResolvedUrl ''
        $new | Add-Member -NotePropertyName SourcePath -NotePropertyValue $si.FullName
        $new | Add-Member -NotePropertyName SourceLength -NotePropertyValue $si.Length
        $new | Add-Member -NotePropertyName SourceLastWriteTicks -NotePropertyValue $si.LastWriteTimeUtc.Ticks
        Set-LabIsoManifestEntry -Folder $Destination -Entry $new
        Write-LabLog "ISO $Key imported into the library (SHA-256 $hash)." -Level OK
        return $new
    }
}

function Write-LabManifest {
    <#
    .SYNOPSIS
        <LabRoot>\lab.json (FR-23, ADR 0013): what this lab is - name, LabBuilder version, folders, switch, domain, VMs.
        No secrets. Basis for lab discovery (release 1.4.0).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [string]$Phase)
    $root = [string]$Config.Paths.LabRoot
    if (-not (Test-Path -LiteralPath $root)) { return }
    $file = Join-Path $root 'lab.json'
    $created = (Get-Date).ToUniversalTime().ToString('o')
    if (Test-Path -LiteralPath $file) {
        try { $old = (Get-Content -LiteralPath $file -Raw) | ConvertFrom-Json; if ($old.CreatedUtc) { $created = [string]$old.CreatedUtc } } catch { }
    }
    $version = ''
    $mod = Get-Module -Name LabBuilder | Select-Object -First 1
    if ($mod) { $version = $mod.Version.ToString() }
    $manifest = [ordered]@{
        Format      = 'LabBuilder.Lab/1'
        LabName     = [string]$Config.LabName
        Version     = $version
        LabRoot     = $root
        LibraryRoot = (Get-LabLibraryRoot -Config $Config)
        Domain      = [string]$Config.Domain.Fqdn
        Switch      = [ordered]@{ Name = [string]$Config.Network.SwitchName; Type = [string]$Config.Network.SwitchType; Prefix = [string]$Config.Network.Prefix }
        DiskType    = (Get-LabDiskType -Config $Config)   # Differencing = VMs depend on the library base images (ADR 0014)
        CreatedUtc  = $created
        UpdatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        LastPhase   = $Phase
        Host        = $env:COMPUTERNAME
        VMs         = @(Get-LabVmDefinition -Config $Config | ForEach-Object {
            [ordered]@{ Name = $_.Name; VMName = $_.VMName; Role = $_.Role; Image = $_.Image; IPAddress = $_.IPAddress }
        })
    }
    ConvertTo-Json -InputObject $manifest -Depth 6 | Set-Content -LiteralPath $file -Encoding UTF8
}

function Test-LabHostConflict {
    <#
    .SYNOPSIS
        Checks this host for another lab that would collide with the configured one (same lab name with another domain,
        same lab folder, or VMs of another lab on the same switch). Returns error strings (empty = no conflict).
        Used by Test-LabConfigFile.ps1 (wizard Summary page) and Invoke-LabBuild.ps1 before any work starts.
    .PARAMETER OutputRoot
        <install>\output - where each lab keeps its credentials (output\<LabName>\lab-accounts.csv).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [string]$OutputRoot)
    $errors = New-Object System.Collections.Generic.List[string]
    $lab = [string]$Config.LabName
    $fqdn = [string]$Config.Domain.Fqdn
    $upn = [string]$Config.Accounts.UpnSuffix
    if (-not $upn) { $upn = $fqdn }
    $fix = "Choose another lab name, lab folder and switch name/subnet for the new lab (it reuses the image library, so no new downloads), " +
           "or remove the old lab first: scripts\Remove-Lab.ps1 -ConfigPath <old lab config> -RemoveOutput."

    # 1. Same lab name, other domain: output\<LabName> holds the old lab's accounts (and VM names would collide).
    if ($OutputRoot) {
        $acc = Join-Path $OutputRoot "$lab\lab-accounts.csv"
        if (Test-Path -LiteralPath $acc) {
            $first = @(Import-Csv -LiteralPath $acc | Select-Object -First 1)
            if ($first.Count -gt 0 -and [string]$first[0].UserPrincipalName -notlike "*@$upn") {
                $old = ([string]$first[0].UserPrincipalName -split '@', 2)[-1]
                $errors.Add("Lab name '$lab' is already used on this host by a lab of domain '$old' (credentials in $(Join-Path $OutputRoot $lab)). $fix")
            }
        }
    }

    # 2. Lab folder already belongs to another lab (state.json / lab.json are per lab folder).
    $root = [string]$Config.Paths.LabRoot
    foreach ($f in 'lab.json', 'state.json') {
        $p = Join-Path $root $f
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try { $m = (Get-Content -LiteralPath $p -Raw) | ConvertFrom-Json } catch { continue }
        $otherName = [string]$m.LabName
        $otherDomain = [string]$m.Domain
        if (($otherName -and $otherName -ne $lab) -or ($otherDomain -and $fqdn -and $otherDomain -ne $fqdn)) {
            $who = "lab '$otherName'"; if ($otherDomain) { $who += " (domain $otherDomain)" }
            $errors.Add("Lab folder $root already belongs to $who. $fix")
        }
        break
    }

    # 3. The switch already connects VMs of another lab (same isolated network, same addresses).
    if (Get-Command -Name Get-VMNetworkAdapter -ErrorAction SilentlyContinue) {
        try {
            $sw = [string]$Config.Network.SwitchName
            $foreign = @(Get-VMNetworkAdapter -All -ErrorAction Stop | Where-Object { $_.SwitchName -eq $sw -and $_.VMName -and -not ([string]$_.VMName).StartsWith("$lab-") } |
                ForEach-Object VMName | Select-Object -Unique)
            if ($foreign.Count -gt 0) {
                $errors.Add("Switch '$sw' already connects VMs of another lab ($(($foreign | Select-Object -First 5) -join ', ')) - the labs would share one network and IP addresses. $fix")
            }
        } catch { }   # not elevated / no Hyper-V: the build's own preflight reports that
    }
    return $errors.ToArray()
}

function Get-LabVmNote {
    # Notes on every lab VM; the first token identifies the lab for discovery (FR-23).
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Definition)
    return ('LabBuilder:{0} | {1} {2} {3} | {4}' -f $Config.LabName, $Definition.Role, $Definition.Name, $Definition.IPAddress, $Definition.Image)
}
