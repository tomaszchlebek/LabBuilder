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

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LabLogFile) {
        foreach ($f in $script:LabLogFile) {
            try { Add-Content -LiteralPath $f -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
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
