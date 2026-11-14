# Download helpers (ADR 0003).

function Test-LabMicrosoftHost {
    # True for microsoft.com, *.microsoft.com and aka.ms (redirect hops).
    param([Parameter(Mandatory)][string]$HostName)
    $h = $HostName.ToLowerInvariant().TrimEnd('.')
    return ($h -eq 'aka.ms' -or $h -eq 'microsoft.com' -or $h.EndsWith('.microsoft.com'))
}

function Resolve-LabDownloadUrl {
    <#
    Follows redirects by hand (HEAD requests) and checks every hop:
    HTTPS only, Microsoft hosts only, final host in the allow-list. Returns final URL and Content-Length.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string[]]$AllowedHosts,
        [int]$MaxRedirects = 10
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $current = [uri]$Url
    $hops = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -le $MaxRedirects; $i++) {
        if ($current.Scheme -ne 'https') { throw "Refusing non-HTTPS download hop: $current" }
        if (-not (Test-LabMicrosoftHost -HostName $current.Host)) { throw "Refusing download hop outside Microsoft domains: $($current.Host)" }
        $hops.Add($current.Host)

        $req = [System.Net.HttpWebRequest]::Create($current)
        $req.Method = 'HEAD'
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'LabBuilder/0.1 (PowerShell)'
        $req.Timeout = 60000
        $resp = $null
        try { $resp = $req.GetResponse() }
        catch [System.Net.WebException] {
            $resp = $_.Exception.Response
            if (-not $resp) { throw "Cannot reach $($current.Host): $($_.Exception.Message)" }
        }
        try {
            $code = [int]$resp.StatusCode
            if ($code -ge 300 -and $code -lt 400) {
                $location = $resp.Headers['Location']
                if (-not $location) { throw "HTTP $code from $($current.Host) without Location header." }
                $current = New-Object System.Uri($current, $location)
                continue
            }
            if ($code -ne 200) { throw "HTTP $code from $current" }

            $allowed = @($AllowedHosts | ForEach-Object { $_.ToLowerInvariant() })
            if ($allowed -notcontains $current.Host.ToLowerInvariant()) {
                throw "Final download host '$($current.Host)' is not in Iso.AllowedDownloadHosts."
            }
            return [pscustomobject]@{
                Url           = $current.AbsoluteUri
                Host          = $current.Host
                ContentLength = [int64]$resp.ContentLength
                Hops          = ($hops -join ' -> ')
            }
        }
        finally { $resp.Close() }
    }
    throw "Too many redirects (> $MaxRedirects) for $Url"
}

function Invoke-LabFileDownload {
    <#
    Downloads to <Destination>.partial (resumable with curl.exe) and renames when the size matches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [int64]$ExpectedLength = -1
    )

    $partial = "$Destination.partial"
    if ($ExpectedLength -gt 0 -and (Test-Path -LiteralPath $partial) -and (Get-Item -LiteralPath $partial).Length -gt $ExpectedLength) {
        Remove-Item -LiteralPath $partial -Force
    }

    $curl = Get-Command -Name 'curl.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($curl) {
        $errFile = "$Destination.curl.err"
        $argList = @(
            '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
            '--retry', '5', '--retry-delay', '15', '--continue-at', '-',
            '--silent', '--show-error', '--output', ('"{0}"' -f $partial), ('"{0}"' -f $Url)
        )
        $p = Start-Process -FilePath $curl.Source -ArgumentList $argList -NoNewWindow -PassThru -RedirectStandardError $errFile
        $null = $p.Handle   # keeps ExitCode readable after exit
        $lastReport = Get-Date
        while (-not $p.HasExited) {
            Start-Sleep -Seconds 5
            if (((Get-Date) - $lastReport).TotalSeconds -ge 60) {
                $lastReport = Get-Date
                if (Test-Path -LiteralPath $partial) {
                    $len = (Get-Item -LiteralPath $partial).Length
                    if ($ExpectedLength -gt 0) {
                        Write-LabLog ('  {0}: {1:N1} of {2:N1} GB ({3:P0})' -f (Split-Path $Destination -Leaf), ($len / 1GB), ($ExpectedLength / 1GB), ($len / $ExpectedLength))
                    } else {
                        Write-LabLog ('  {0}: {1:N1} GB' -f (Split-Path $Destination -Leaf), ($len / 1GB))
                    }
                }
            }
        }
        $p.WaitForExit()
        $stderr = ''
        if (Test-Path -LiteralPath $errFile) { $stderr = (Get-Content -LiteralPath $errFile -Raw); Remove-Item -LiteralPath $errFile -Force }
        if ($p.ExitCode -ne 0) { throw "curl.exe failed with exit code $($p.ExitCode): $stderr" }
    }
    else {
        Write-LabLog 'curl.exe not found - using Invoke-WebRequest (no resume).' -Level WARN
        $old = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -ErrorAction Stop }
        finally { $ProgressPreference = $old }
    }

    $actual = (Get-Item -LiteralPath $partial).Length
    if ($ExpectedLength -gt 0 -and $actual -ne $ExpectedLength) {
        throw "Downloaded size $actual does not match Content-Length $ExpectedLength; re-run to resume."
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

function Read-LabIsoManifest {
    # iso-manifest.json in a folder -> hashtable FileName -> entry
    param([Parameter(Mandatory)][string]$Folder)
    $map = @{}
    $file = Join-Path $Folder 'iso-manifest.json'
    if (Test-Path -LiteralPath $file) {
        # Assign first: in Windows PowerShell 5.1 ConvertFrom-Json emits a JSON array as one object.
        $parsed = (Get-Content -LiteralPath $file -Raw) | ConvertFrom-Json
        foreach ($e in $parsed) { if ($e.FileName) { $map[[string]$e.FileName] = $e } }
    }
    return $map
}

function Write-LabIsoManifest {
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][hashtable]$Map)
    $file = Join-Path $Folder 'iso-manifest.json'
    $entries = @($Map.Values | Sort-Object FileName)
    ConvertTo-Json -InputObject $entries -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
}

function Get-LabRequiredImageKey {
    # Image keys (Server/Client) used by at least one VM.
    param([Parameter(Mandatory)]$Config)
    return @(Get-LabVmDefinition -Config $Config | Select-Object -ExpandProperty Image -Unique)
}
