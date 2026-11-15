function Save-LabIso {
    <#
    .SYNOPSIS
        Downloads the Microsoft evaluation ISOs the lab uses into a folder and verifies them (FR-1..FR-3, ADR 0003/0013).
    .DESCRIPTION
        Used by phase Iso on the Hyper-V host (folder <Library>\ISO, shared by all labs) and by scripts\Get-LabIso.ps1 to
        pre-download on any machine. Already verified files (same size and timestamp as in iso-manifest.json) are not
        downloaded again. Images the tester supplies (Supplied = $true, e.g. Win10) are imported from their SourcePath
        when -ImportSupplied is given (host build), otherwise skipped (pre-download). Each image is handled under a
        host-wide lock, so two lab builds never download the same ISO at the same time.
    .OUTPUTS
        Manifest entries of the ISOs in the folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$Image,
        [switch]$ImportSupplied
    )

    if (-not $Image) { $Image = Get-LabRequiredImageKey -Config $Config }
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    $result = New-Object System.Collections.Generic.List[object]

    foreach ($key in $Image) {
        $img = $Config.Iso.Images.$key
        if ($null -eq $img) { throw "Image '$key' is not in the OS catalog (Iso.Images)." }
        if ($img.Supplied) {
            if ($ImportSupplied) { $result.Add((Import-LabSuppliedIso -Config $Config -Key $key -Destination $Destination)) }
            else { Write-LabLog "ISO $key ($($img.Description)) is supplied by the tester - not downloaded." -Level WARN }
            continue
        }
        $entry = Invoke-LabLibraryLock -Name "Iso-$key" -ScriptBlock {
            $path = Join-Path $Destination $img.FileName
            $cached = (Read-LabIsoManifest -Folder $Destination)[$img.FileName]
            if ((Test-Path -LiteralPath $path) -and $cached) {
                $item = Get-Item -LiteralPath $path
                if ($item.Length -eq [int64]$cached.Length -and $item.LastWriteTimeUtc.Ticks -eq [int64]$cached.LastWriteTicks) {
                    if ($img.ExpectedSha256 -and $cached.Sha256 -ne ([string]$img.ExpectedSha256).ToUpperInvariant()) {
                        throw "$($img.FileName): cached SHA-256 $($cached.Sha256) does not match Iso.Images.$key.ExpectedSha256. Delete the file to download again."
                    }
                    Write-LabLog "ISO $key cached and verified: $path (SHA-256 $($cached.Sha256))" -Level OK
                    return $cached
                }
            }

            Write-LabLog "ISO $key ($($img.Description)): resolving $($img.Url)" -Level STEP
            $resolved = Resolve-LabDownloadUrl -Url $img.Url -AllowedHosts @($Config.Iso.AllowedDownloadHosts)
            Write-LabLog ('  via {0}; {1:N2} GB' -f $resolved.Hops, ($resolved.ContentLength / 1GB))
            Write-LabLog "  file: $(Split-Path $resolved.Url -Leaf)"

            if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -eq $resolved.ContentLength) {
                Write-LabLog '  file already complete - verifying only.'
            } else {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
                Invoke-LabFileDownload -Url $resolved.Url -Destination $path -ExpectedLength $resolved.ContentLength
            }

            Write-LabLog '  computing SHA-256 ...'
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($img.ExpectedSha256 -and $hash -ne ([string]$img.ExpectedSha256).ToUpperInvariant()) {
                Move-Item -LiteralPath $path -Destination "$path.rejected" -Force
                throw "$($img.FileName): SHA-256 $hash does not match ExpectedSha256 $($img.ExpectedSha256). File moved to $path.rejected."
            }

            $new = New-LabIsoManifestEntry -Key $key -Image $img -Path $path -Sha256 $hash -ResolvedUrl $resolved.Url
            Set-LabIsoManifestEntry -Folder $Destination -Entry $new
            Write-LabLog "ISO $key ready: $path (SHA-256 $hash)" -Level OK
            return $new
        }
        $result.Add($entry)
    }
    return $result.ToArray()
}

function Import-LabIso {
    <#
    .SYNOPSIS
        Copies pre-downloaded ISOs (scripts\Get-LabIso.ps1 on another machine, then copied to USB/share)
        into the image library <Library>\ISO, verifying each SHA-256 against the source iso-manifest.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Source
    )

    $dest = Get-LabLibraryIsoFolder -Config $Config
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    $srcManifest = Read-LabIsoManifest -Folder $Source

    foreach ($key in (Get-LabRequiredImageKey -Config $Config)) {
        $img = $Config.Iso.Images.$key
        if ($img.Supplied) { continue }
        $srcFile = Join-Path $Source $img.FileName
        $srcEntry = $srcManifest[$img.FileName]
        if (-not (Test-Path -LiteralPath $srcFile)) { Write-LabLog "ISO $key not in $Source - will be downloaded." -Level WARN; continue }
        if (-not $srcEntry) { throw "$Source has $($img.FileName) but no iso-manifest.json entry - pre-download it with scripts\Get-LabIso.ps1." }
        if ($img.ExpectedSha256 -and $srcEntry.Sha256 -ne ([string]$img.ExpectedSha256).ToUpperInvariant()) {
            throw "$($img.FileName) in $Source has SHA-256 $($srcEntry.Sha256), config expects $($img.ExpectedSha256)."
        }
        Invoke-LabLibraryLock -Name "Iso-$key" -ScriptBlock {
            $dstFile = Join-Path $dest $img.FileName
            $dstEntry = (Read-LabIsoManifest -Folder $dest)[$img.FileName]
            if ($dstEntry -and $dstEntry.Sha256 -eq $srcEntry.Sha256 -and (Test-Path -LiteralPath $dstFile) -and (Get-Item -LiteralPath $dstFile).Length -eq [int64]$srcEntry.Length) {
                Write-LabLog "ISO $key already in the library: $dstFile" -Level OK
                return
            }
            Write-LabLog ('Importing ISO {0} from {1} ({2:N1} GB) ...' -f $key, $Source, ([int64]$srcEntry.Length / 1GB)) -Level STEP
            Copy-Item -LiteralPath $srcFile -Destination "$dstFile.partial" -Force -ErrorAction Stop
            Move-Item -LiteralPath "$dstFile.partial" -Destination $dstFile -Force
            $hash = (Get-FileHash -LiteralPath $dstFile -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($hash -ne $srcEntry.Sha256) {
                Remove-Item -LiteralPath $dstFile -Force
                throw "Imported $($img.FileName) has SHA-256 $hash, source manifest says $($srcEntry.Sha256). Copy removed."
            }
            Set-LabIsoManifestEntry -Folder $dest -Entry (New-LabIsoManifestEntry -Key $key -Image $img -Path $dstFile -Sha256 $hash -ResolvedUrl ([string]$srcEntry.ResolvedUrl))
            Write-LabLog "ISO $key imported and verified (SHA-256 $hash)." -Level OK
        }
    }
}

function Confirm-LabHostIso {
    # End of phase Iso: every required ISO is in the library and matches its manifest entry.
    param([Parameter(Mandatory)]$Config)
    $dir = Get-LabLibraryIsoFolder -Config $Config
    $manifest = Read-LabIsoManifest -Folder $dir
    foreach ($key in (Get-LabRequiredImageKey -Config $Config)) {
        $img = $Config.Iso.Images.$key
        $path = Join-Path $dir $img.FileName
        $entry = $manifest[$img.FileName]
        if (-not (Test-Path -LiteralPath $path)) { throw "ISO $key missing: $path" }
        if (-not $entry) { throw "ISO $key has no entry in $dir\iso-manifest.json - run phase Iso." }
        if ((Get-Item -LiteralPath $path).Length -ne [int64]$entry.Length) { throw "ISO $key has the wrong size - run phase Iso again." }
        Write-LabLog "ISO $key in library: $path (SHA-256 $($entry.Sha256))" -Level OK
    }
}

function New-LabIsoManifestEntry {
    param($Key, $Image, $Path, $Sha256, $ResolvedUrl)
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        Key            = $Key
        FileName       = $Image.FileName
        Description    = $Image.Description
        SourcePage     = $Image.SourcePage
        ConfiguredUrl  = $Image.Url
        ResolvedUrl    = $ResolvedUrl
        Length         = $item.Length
        Sha256         = $Sha256
        RecordedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        LastWriteTicks = $item.LastWriteTimeUtc.Ticks
    }
}
