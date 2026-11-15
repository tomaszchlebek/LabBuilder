function Set-LabLogFile {
    <#
    .SYNOPSIS
        Adds a file that Write-LabLog appends to (creates the folder). Several files can be active,
        e.g. output\<Lab>\build-*.log and <LabRoot>\Logs\labbuilder-<date>.log. -Clear removes all first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$Clear)

    if ($Clear -or $null -eq $script:LabLogFile) { $script:LabLogFile = New-Object System.Collections.Generic.List[string] }
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not $script:LabLogFile.Contains($Path)) { $script:LabLogFile.Add($Path) }
}

function Get-LabLogFile {
    # The log files Write-LabLog appends to (handed to parallel workers, ADR 0014).
    if ($script:LabLogFile) { return [string[]]$script:LabLogFile.ToArray() }
    return [string[]]@()
}

function Get-LabPhaseOfRole {
    # Build phase that creates/configures a VM of this role (progress events).
    param([string]$Role)
    switch ($Role) { 'DomainController' { 'DomainControllers' } 'MemberServer' { 'MemberServers' } 'Workstation' { 'Workstations' } default { 'Build' } }
}

function Write-LabProgress {
    <#
    .SYNOPSIS
        Progress event (FR-26, ADR 0014): one JSON object per line in <LabRoot>\Logs\progress.jsonl and a console line
        '##LBP {json}' that the wizard turns into its VM status list. No secrets.
    .PARAMETER Status
        creating | starting | configuring | joining | roles | promoting | ready | failed | skipped
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][ValidateSet('creating', 'starting', 'configuring', 'joining', 'roles', 'promoting', 'ready', 'failed', 'skipped')][string]$Status,
        [string]$Detail = ''
    )
    $evt = [ordered]@{ Time = (Get-Date).ToUniversalTime().ToString('o'); Lab = [string]$Config.LabName; Phase = $Phase; Item = $Item; Status = $Status; Detail = $Detail }
    $json = ConvertTo-Json -InputObject $evt -Compress
    $root = [string]$Config.Paths.LabRoot
    if ($root -and (Test-Path -LiteralPath $root)) {
        $file = Join-Path $root 'Logs\progress.jsonl'
        $mutex = New-Object System.Threading.Mutex($false, 'Local\LabBuilder-LogWrite')
        $owned = $false
        try {
            try { $owned = $mutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
            $dir = Split-Path -Parent $file
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            try { [System.IO.File]::AppendAllText($file, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) } catch { }
        } finally {
            if ($owned) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
    Write-Host ('##LBP ' + $json)
}

function Write-LabLog {
    <#
    .SYNOPSIS
        Writes a timestamped line to the console and to the lab log files. Never pass secrets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')][string]$Level = 'INFO'
    )

    # Parallel workers (ADR 0014) set $script:LabLogPrefix = '[<item>] '; log files are shared, so writes are serialised.
    if ($script:LabLogPrefix) { $Message = $script:LabLogPrefix + $Message }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LabLogFile) {
        $mutex = New-Object System.Threading.Mutex($false, 'Local\LabBuilder-LogWrite')
        $owned = $false
        try {
            try { $owned = $mutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
            foreach ($f in $script:LabLogFile) {
                try { [System.IO.File]::AppendAllText($f, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8) } catch { }
            }
        } finally {
            if ($owned) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'STEP'  { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}
