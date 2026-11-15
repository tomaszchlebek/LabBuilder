# Parallel build engine (FR-24, ADR 0014). Windows PowerShell 5.1: runspace pool, no ForEach-Object -Parallel. ASCII only.

function Test-LabParallelEnabled {
    # Build.Parallel = $false switches the parallel engine off (items run one at a time in the build process).
    param([Parameter(Mandatory)]$Config)
    if ($Config.Build -and $Config.Build.PSObject.Properties['Parallel'] -and -not [bool]$Config.Build.Parallel) { return $false }
    return $true
}

function Get-LabThrottleLimit {
    # Build.ThrottleLimit, or auto: half the logical processors, at least 2, at most $Max; never more than the number of items.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][int]$Count, [int]$Max = 8)
    $t = 0
    if ($Config.Build -and $Config.Build.PSObject.Properties['ThrottleLimit']) { $t = [int]$Config.Build.ThrottleLimit }
    if ($t -le 0) { $t = [math]::Max(2, [math]::Min($Max, [int][math]::Floor([Environment]::ProcessorCount / 2))) }
    return [int][math]::Max(1, [math]::Min($t, [math]::Max(1, $Count)))
}

function Invoke-LabParallel {
    <#
    .SYNOPSIS
        Runs a script block for every item, in parallel runspaces (or one at a time with -Sequential).
    .DESCRIPTION
        The script block gets param($Item, $Arguments) and runs bound to the LabBuilder module (private helpers available).
        Each worker imports the module, writes to the same log files plus <LogFolder>\vm-<label>.log, and prefixes its log lines
        with [<label>]. Host output and warnings of the workers are relayed live to this host (console, transcript, wizard).
        All items run to completion; failures are collected and thrown together at the end.
    .OUTPUTS
        Everything the script blocks output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][scriptblock]$Label,
        [hashtable]$Arguments = @{},
        [int]$ThrottleLimit = 4,
        [switch]$Sequential,
        [string]$LogFolder,
        [string]$What = 'items'
    )
    $list = @($Items | Where-Object { $null -ne $_ })
    $results = New-Object System.Collections.Generic.List[object]
    if ($list.Count -eq 0) { return $results.ToArray() }
    $failures = New-Object System.Collections.Generic.List[string]

    if ($Sequential -or $list.Count -eq 1 -or $ThrottleLimit -le 1) {
        foreach ($it in $list) {
            $name = [string](& $Label $it)
            try { foreach ($o in @(& $ScriptBlock $it $Arguments)) { $results.Add($o) } }
            catch {
                Write-LabLog "[$name] failed: $($_.Exception.Message)" -Level ERROR
                $failures.Add(('{0}: {1}' -f $name, $_.Exception.Message))
            }
        }
    } else {
        Write-LabLog ("Running {0} {1} in parallel (up to {2} at a time) ..." -f $list.Count, $What, $ThrottleLimit)
        $modulePath = Join-Path $script:ModuleRoot 'LabBuilder.psd1'
        $logFiles = Get-LabLogFile
        $runner = {
            param($ModulePath, $LogFiles, $LogFolder, $Name, $Text, $Item, $Arguments)
            $ErrorActionPreference = 'Stop'
            $m = Import-Module $ModulePath -PassThru -DisableNameChecking -WarningAction SilentlyContinue
            & $m {
                param($Files, $Folder, $N)
                foreach ($f in @($Files)) { if ($f) { Set-LabLogFile -Path $f } }
                if ($Folder) { Set-LabLogFile -Path (Join-Path $Folder ('vm-{0}.log' -f ($N -replace '[^A-Za-z0-9_.-]', '_'))) }
                $script:LabLogPrefix = "[$N] "
            } $LogFiles $LogFolder $Name
            & ($m.NewBoundScriptBlock([scriptblock]::Create($Text))) $Item $Arguments
        }.ToString()
        $pool = [runspacefactory]::CreateRunspacePool(1, $ThrottleLimit)
        $pool.Open()
        $jobs = New-Object System.Collections.Generic.List[object]
        try {
            foreach ($it in $list) {
                $name = [string](& $Label $it)
                $ps = [powershell]::Create()
                $ps.RunspacePool = $pool
                [void]$ps.AddScript($runner).AddArgument($modulePath).AddArgument($logFiles).AddArgument($LogFolder).AddArgument($name).AddArgument($ScriptBlock.ToString()).AddArgument($it).AddArgument($Arguments)
                $jobs.Add([pscustomobject]@{ Name = $name; PS = $ps; Handle = $ps.BeginInvoke(); Info = 0; Warn = 0; Done = $false })
            }
            $relay = {
                param($j)
                $recs = $j.PS.Streams.Information
                for ($i = $j.Info; $i -lt $recs.Count; $i++) {
                    $md = $recs[$i].MessageData
                    if ($md -is [System.Management.Automation.HostInformationMessage]) {
                        if ($null -ne $md.ForegroundColor) { Write-Host $md.Message -ForegroundColor $md.ForegroundColor } else { Write-Host $md.Message }
                    } else { Write-Host ([string]$md) }
                }
                $j.Info = $recs.Count
                $warns = $j.PS.Streams.Warning
                for ($i = $j.Warn; $i -lt $warns.Count; $i++) { Write-Warning $warns[$i].Message }
                $j.Warn = $warns.Count
            }
            while (@($jobs | Where-Object { -not $_.Done }).Count -gt 0) {
                foreach ($j in @($jobs | Where-Object { -not $_.Done })) {
                    & $relay $j
                    if (-not $j.Handle.IsCompleted) { continue }
                    try {
                        foreach ($o in @($j.PS.EndInvoke($j.Handle))) { $results.Add($o) }
                    } catch {
                        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
                        $failures.Add(('{0}: {1}' -f $j.Name, $e.Message))
                    }
                    & $relay $j
                    $j.Done = $true
                    $j.PS.Dispose()
                }
                Start-Sleep -Milliseconds 300
            }
        } finally {
            foreach ($j in $jobs) { if (-not $j.Done) { try { $j.PS.Stop(); $j.PS.Dispose() } catch { } } }
            $pool.Close(); $pool.Dispose()
        }
        foreach ($f in $failures) { Write-LabLog "  failed - $f" -Level ERROR }
    }
    if ($failures.Count -gt 0) {
        throw ('{0} of {1} {2} failed: {3}' -f $failures.Count, $list.Count, $What, ($failures -join ' | '))
    }
    return $results.ToArray()
}
