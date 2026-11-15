# Pester 3.4 tests for release 1.3.0: parallel engine, thread-safe logging, progress events, build/disk options (FR-24..FR-26, ADR 0014).
# Run: Invoke-Pester .\tests

$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\LabBuilder\LabBuilder.psd1') -Force
$example = Join-Path $repo 'config\lab.config.example.psd1'

function Get-ValidConfig {
    Import-LabConfig -Path $example -Overrides @{ 'Domain.Fqdn' = 'lab.test'; 'Domain.NetBiosName' = 'LABTEST' }
}
function Get-Errors { param($Config) (@(Test-LabConfig -Config $Config) -join ' | ') }
$m = Get-Module LabBuilder

Describe 'Parallel engine (Invoke-LabParallel)' {
    It 'runs items concurrently, returns their output and binds the script block to the module' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = & $m { Invoke-LabParallel -Items @(1, 2, 3, 4) -Label { param($i) "item$i" } -ThrottleLimit 4 -Arguments @{ Wait = 2 } -ScriptBlock {
                param($Item, $A)
                Start-Sleep -Seconds $A.Wait
                '{0}:{1}' -f $Item, (Test-LabServicingError -Message '0x80071a2d')   # private module helper
            } }
        $sw.Stop()
        (@($r) | Sort-Object) -join ',' | Should Be '1:True,2:True,3:True,4:True'
        $sw.Elapsed.TotalSeconds | Should BeLessThan 7   # 4 x 2 s sequentially would be >= 8 s
    }
    It 'lets every item finish and reports all failures together' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("par-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $err = $null
            try {
                & $m { param($D) Invoke-LabParallel -Items @('a', 'b', 'c') -Label { param($i) $i } -ThrottleLimit 3 -What 'test items' -Arguments @{ Dir = $D } -ScriptBlock {
                        param($Item, $A)
                        if ($Item -eq 'b') { throw "broken $Item" }
                        Start-Sleep -Milliseconds 500
                        Set-Content -LiteralPath (Join-Path $A.Dir $Item) -Value 'done'
                    } } $dir
            } catch { $err = $_.Exception.Message }
            $err | Should Match '^1 of 3 test items failed: b: broken b'
            (Test-Path (Join-Path $dir 'a')) -and (Test-Path (Join-Path $dir 'c')) | Should Be $true
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
    It 'runs one at a time with -Sequential (Build.Parallel = $false)' {
        $r = & $m { Invoke-LabParallel -Items @(3, 1, 2) -Label { param($i) "s$i" } -Sequential -ScriptBlock { param($Item, $A) $Item * 10 } }
        @($r) -join ',' | Should Be '30,10,20'
    }
    It 'writes complete log lines from parallel workers (no lost or mixed lines) with an item prefix and per-item log files' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("log-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $log = Join-Path $dir 'build.log'
            & $m { param($L, $D)
                Set-LabLogFile -Path $L -Clear
                Invoke-LabParallel -Items @('VM1', 'VM2', 'VM3', 'VM4') -Label { param($i) $i } -ThrottleLimit 4 -LogFolder $D -ScriptBlock {
                    param($Item, $A)
                    for ($n = 1; $n -le 50; $n++) { Write-LabLog ("line {0:D3} of {1}" -f $n, $Item) }
                } | Out-Null
            } $log $dir
            $lines = @(Get-Content -LiteralPath $log | Where-Object { $_ -match 'line \d{3} of VM\d' })
            $lines.Count | Should Be 200
            @($lines | Where-Object { $_ -notmatch '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[INFO\] \[VM(\d)\] line \d{3} of VM\1$' }).Count | Should Be 0
            @(Get-Content -LiteralPath (Join-Path $dir 'vm-VM3.log') | Where-Object { $_ -match 'of VM3' }).Count | Should Be 50
        } finally {
            & $m { Set-LabLogFile -Path (Join-Path $env:TEMP 'labbuilder-pester-dummy.log') -Clear }
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
    }
}

Describe 'Build options (Build.*, Disks.Type)' {
    It 'defaults: parallel on, auto throttle within 2..8 and never above the item count, disks Dynamic' {
        $c = Get-ValidConfig
        & $m { param($C) Test-LabParallelEnabled -Config $C } $c | Should Be $true
        $t = & $m { param($C) Get-LabThrottleLimit -Config $C -Count 20 } $c
        ($t -ge 2 -and $t -le 8) | Should Be $true
        & $m { param($C) Get-LabThrottleLimit -Config $C -Count 1 } $c | Should Be 1
        Get-LabDiskType -Config $c | Should Be 'Dynamic'
        Get-Errors $c | Should Be ''
    }
    It 'honours Build.Parallel = $false, a fixed throttle and Differencing disks; rejects bad values' {
        $c = Get-ValidConfig
        $c.Build.Parallel = $false; $c.Build.ThrottleLimit = 3; $c.Disks.Type = 'Differencing'
        & $m { param($C) Test-LabParallelEnabled -Config $C } $c | Should Be $false
        & $m { param($C) Get-LabThrottleLimit -Config $C -Count 10 } $c | Should Be 3
        Get-LabDiskType -Config $c | Should Be 'Differencing'
        Get-Errors $c | Should Be ''
        $c.Disks.Type = 'Fixed'; $c.Build.ThrottleLimit = 99
        $e = Get-Errors $c
        $e | Should Match 'Disks.Type must be Dynamic or Differencing'
        $e | Should Match 'Build.ThrottleLimit must be 0'
    }
    It 'records the disk type in lab.json' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("lab-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $root | Out-Null
        try {
            $c = Get-ValidConfig; $c.Paths.LabRoot = $root; $c.Disks.Type = 'Differencing'
            Write-LabManifest -Config $c -Phase 'Preflight'
            ((Get-Content -LiteralPath (Join-Path $root 'lab.json') -Raw) | ConvertFrom-Json).DiskType | Should Be 'Differencing'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Describe 'Progress events (Write-LabProgress, FR-26)' {
    It 'appends JSON lines to <LabRoot>\Logs\progress.jsonl' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("prog-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $root | Out-Null
        try {
            $c = Get-ValidConfig; $c.Paths.LabRoot = $root
            Write-LabProgress -Config $c -Phase 'MemberServers' -Item 'WEB01' -Status 'roles' -Detail 'IIS' 6>$null
            Write-LabProgress -Config $c -Phase 'MemberServers' -Item 'WEB01' -Status 'ready' 6>$null
            $events = @(Get-Content -LiteralPath (Join-Path $root 'Logs\progress.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
            $events.Count | Should Be 2
            $events[0].Item | Should Be 'WEB01'
            $events[0].Status | Should Be 'roles'
            $events[0].Detail | Should Be 'IIS'
            $events[1].Lab | Should Be 'TESTLAB'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'maps VM roles to their build phase' {
        & $m { Get-LabPhaseOfRole -Role 'Workstation' } | Should Be 'Workstations'
        & $m { Get-LabPhaseOfRole -Role 'MemberServer' } | Should Be 'MemberServers'
    }
}
