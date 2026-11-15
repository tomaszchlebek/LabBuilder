#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Builds the isolated TEST lab on THIS Hyper-V host: AD forest (1..5 DCs), CA, member servers with roles, Windows 11 workstations.

.DESCRIPTION
    Run in an elevated Windows PowerShell 5.1 (or 7) console directly on the dedicated Hyper-V host (ADR 0007),
    or let LabBuilderSetup.exe (ADR 0011) start it. The topology comes from the config file (ADR 0009).
    Phases (idempotent - re-run after a failure, optionally from a given phase):
      Preflight, Iso, BaseImages, Network, DomainControllers, MemberServers, Workstations, Validate

    Output (git-ignored) in output\<LabName>\:
      lab-admin.cred.xml  lab administrator credential (DPAPI, this user on this host)
      lab-accounts.csv    generated domain admins and test users with passwords and groups
      lab-sql.csv         SQL Server sa password (only with role SQL and Roles.SQL.AuthenticationMode = Mixed)
      build-*.log         build log; validation-*.md report; lab-summary.md

.PARAMETER DomainFqdn
    FQDN of the new forest root domain (overrides Domain.Fqdn), e.g. lab.test.
.PARAMETER DomainNetbios
    NetBIOS name (overrides Domain.NetBiosName), e.g. LABTEST.
.PARAMETER ConfigPath
    Config file; default config\lab.config.psd1, else config\lab.config.example.psd1.
.PARAMETER LabRoot
    Folder of this lab on the host: VMs, logs, reports, lab.json (overrides Paths.LabRoot). ISOs and base images are in
    the shared image library (Paths.LibraryRoot, default <LabRoot drive>:\LabBuilder-Library).
.PARAMETER LabAdminCredential
    Optional lab administrator password (user name is ignored). Default: generated once and reused.
.PARAMETER AdminPasswordFromStdin
    Read the lab administrator password from the first line of standard input (used by LabBuilderSetup.exe).
.PARAMETER IsoSource
    Optional folder with ISOs pre-downloaded by scripts\Get-LabIso.ps1 (e.g. USB drive or share).
.PARAMETER Phase
    Phases to run (default All). Old names DomainController / IisServer are accepted.

.EXAMPLE
    .\scripts\Invoke-LabBuild.ps1 -DomainFqdn lab.test -DomainNetbios LABTEST

.EXAMPLE
    .\scripts\Invoke-LabBuild.ps1 -ConfigPath .\config\lab.config.psd1 -Phase MemberServers, Workstations, Validate
#>
[CmdletBinding()]
param(
    [string]$DomainFqdn,
    [string]$DomainNetbios,
    [string]$ConfigPath,
    [string]$LabRoot,
    [pscredential]$LabAdminCredential,
    [switch]$AdminPasswordFromStdin,
    [string]$IsoSource,
    [ValidateSet('All', 'Preflight', 'Iso', 'BaseImages', 'Network', 'DomainControllers', 'MemberServers', 'Workstations', 'Validate', 'DomainController', 'IisServer')]
    [string[]]$Phase = 'All'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\LabBuilder\LabBuilder.psd1') -Force

# Password from stdin first, before anything else is printed (LabBuilderSetup.exe writes one line).
$stdinPassword = $null
if ($AdminPasswordFromStdin) {
    $line = [Console]::In.ReadLine()
    if ($line) { $stdinPassword = ConvertTo-SecureString -String $line -AsPlainText -Force }
    $line = $null
}

$fqdnOverride = ''; if ($DomainFqdn) { $fqdnOverride = $DomainFqdn.Trim().TrimEnd('.').ToLowerInvariant() }
$nbOverride = ''; if ($DomainNetbios) { $nbOverride = $DomainNetbios.Trim().ToUpperInvariant() }
$ConfigPath = Resolve-LabConfigPath -RepoRoot $repo -ConfigPath $ConfigPath
$config = Import-LabConfig -Path $ConfigPath -Overrides @{
    'Domain.Fqdn'        = $fqdnOverride
    'Domain.NetBiosName' = $nbOverride
    'Paths.LabRoot'      = $LabRoot
}
$errors = @(Test-LabConfig -Config $config -Scope Full)
# Another lab on this host with the same name, lab folder or switch (checked before anything is written).
if ($errors.Count -eq 0) { $errors = @(Test-LabHostConflict -Config $config -OutputRoot (Join-Path $repo 'output')) }
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    throw "Configuration is not valid ($ConfigPath)."
}
if ($IsoSource -and -not (Test-Path -LiteralPath $IsoSource)) { throw "IsoSource folder not found: $IsoSource" }

$outDir = Join-Path $repo "output\$($config.LabName)"
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Start-Transcript -Path (Join-Path $outDir "build-$stamp.transcript.log") | Out-Null
Set-LabLogFile -Path (Join-Path $outDir "build-$stamp.log") -Clear

$allPhases = @('Preflight', 'Iso', 'BaseImages', 'Network', 'DomainControllers', 'MemberServers', 'Workstations', 'Validate')
$Phase = @($Phase | ForEach-Object { if ($_ -eq 'DomainController') { 'DomainControllers' } elseif ($_ -eq 'IisServer') { 'MemberServers' } else { $_ } })
if ($Phase -contains 'All') { $run = $allPhases } else { $run = @($allPhases | Where-Object { $Phase -contains $_ }) }

try {
    $defs = @(Get-LabVmDefinition -Config $config)
    Write-LabLog "Lab '$($config.LabName)' on $env:COMPUTERNAME - domain $($config.Domain.Fqdn) ($($config.Domain.NetBiosName)) - config $ConfigPath" -Level STEP
    Write-LabLog ("Topology: {0} DC(s), {1} member server(s), {2} workstation(s); network {3}.0/24 on {4} switch '{5}'" -f `
        @($defs | Where-Object Role -eq 'DomainController').Count, @($defs | Where-Object Role -eq 'MemberServer').Count,
        @($defs | Where-Object Role -eq 'Workstation').Count, $config.Network.Prefix, $config.Network.SwitchType, $config.Network.SwitchName)
    Write-LabLog "Phases: $($run -join ', ')"

    # --- Lab administrator credential (ADR 0006) ---
    $credFile = Join-Path $outDir 'lab-admin.cred.xml'
    $suppliedPassword = $null
    if ($LabAdminCredential) { $suppliedPassword = $LabAdminCredential.Password }
    if ($stdinPassword) { $suppliedPassword = $stdinPassword }
    if ($suppliedPassword) {
        $check = (New-Object System.Management.Automation.PSCredential('x', $suppliedPassword)).GetNetworkCredential().Password
        if (-not (Test-LabPasswordComplexity -Password $check)) {
            throw 'The lab administrator password does not meet AD complexity (>= 8 chars, 3 of: upper, lower, digit, symbol).'
        }
        $check = $null
        $adminCred = New-Object System.Management.Automation.PSCredential('Administrator', $suppliedPassword)
        $adminCred | Export-Clixml -LiteralPath $credFile
        Write-LabLog "Lab administrator password supplied; saved (DPAPI) to $credFile"
    } elseif (Test-Path -LiteralPath $credFile) {
        $adminCred = Import-Clixml -LiteralPath $credFile
        Write-LabLog "Using saved lab administrator credential $credFile"
    } else {
        $secure = ConvertTo-SecureString -String (New-LabPassword -Length 20) -AsPlainText -Force
        $adminCred = New-Object System.Management.Automation.PSCredential('Administrator', $secure)
        $adminCred | Export-Clixml -LiteralPath $credFile
        Write-LabLog "Generated a lab administrator password; saved (DPAPI) to $credFile"
    }
    Protect-LabFile -Path $credFile

    # --- Account plan: dedicated domain admins + test users (FR-8) ---
    $accFile = Join-Path $outDir 'lab-accounts.csv'
    $upnSuffix = [string]$config.Accounts.UpnSuffix
    if (-not $upnSuffix) { $upnSuffix = [string]$config.Domain.Fqdn }
    $groupNames = [string[]]@($config.Groups | ForEach-Object { [string]$_.Name })
    $wantAdmins = [int]$config.Accounts.DomainAdminCount
    $wantUsers = [int]$config.Accounts.TestUserCount
    $accounts = @()
    if (Test-Path -LiteralPath $accFile) {
        $accounts = @(Import-Csv -LiteralPath $accFile | ForEach-Object {
            if (-not ($_.PSObject.Properties.Name -contains 'Type') -or -not $_.Type) { $_ | Add-Member -NotePropertyName Type -NotePropertyValue 'TestUser' -Force }
            $_
        })
        $wrong = @($accounts | Where-Object { $_.UserPrincipalName -notlike "*@$upnSuffix" })
        if ($wrong.Count -gt 0) { throw "Lab name '$($config.LabName)' is already used by a lab of another domain ($accFile). Choose another lab name, or remove the old lab first (Remove-Lab.ps1 -ConfigPath <old lab config> -RemoveOutput)." }
        Write-LabLog "Using existing account plan $accFile"
    }
    $haveAdmins = @($accounts | Where-Object Type -eq 'DomainAdmin').Count
    $haveUsers = @($accounts | Where-Object Type -eq 'TestUser').Count
    if ($haveAdmins -lt $wantAdmins -or $haveUsers -lt $wantUsers) {
        # Top up: generate the missing accounts, skipping names already in the plan.
        $used = @{}; foreach ($a in $accounts) { $used[$a.SamAccountName] = $true }
        $extra = New-Object System.Collections.Generic.List[object]
        $needA = $wantAdmins - $haveAdmins; $needU = $wantUsers - $haveUsers
        for ($try = 0; ($needA -gt 0 -or $needU -gt 0) -and $try -lt 50; $try++) {
            $batch = @(New-LabAccountPlan -DomainAdminCount ([math]::Max(0, $needA)) -TestUserCount ([math]::Max(0, $needU)) -GroupNames $groupNames -UpnSuffix $upnSuffix -PasswordLength ([int]$config.Accounts.PasswordLength))
            foreach ($b in $batch) {
                if ($used.ContainsKey($b.SamAccountName)) { continue }
                if ($b.Type -eq 'DomainAdmin' -and $needA -gt 0) { $extra.Add($b); $used[$b.SamAccountName] = $true; $needA-- }
                elseif ($b.Type -eq 'TestUser' -and $needU -gt 0) { $extra.Add($b); $used[$b.SamAccountName] = $true; $needU-- }
            }
        }
        $accounts = @($accounts) + @($extra.ToArray())
        $accounts | Select-Object Type, SamAccountName, GivenName, Surname, DisplayName, UserPrincipalName, Password, Groups |
            Export-Csv -LiteralPath $accFile -NoTypeInformation -Encoding UTF8
        Protect-LabFile -Path $accFile
        Write-LabLog "Account plan: $wantAdmins domain admin(s), $wantUsers test user(s) -> $accFile (new: $(($extra | ForEach-Object SamAccountName) -join ', '))"
    } elseif ($haveAdmins -gt $wantAdmins -or $haveUsers -gt $wantUsers) {
        Write-LabLog "Account plan has more accounts than configured ($haveAdmins admins, $haveUsers users); all are kept." -Level WARN
    }
    $accountsJson = ConvertTo-Json -InputObject @($accounts | Select-Object Type, SamAccountName, GivenName, Surname, DisplayName, UserPrincipalName, Password, Groups) -Depth 3 -Compress
    $configJson = $config | ConvertTo-Json -Depth 20 -Compress

    # --- SQL Server sa password (role SQL, Mixed authentication; FR-20) - generated once, kept in lab-sql.csv ---
    $sqlSaCred = $null
    $sqlFile = Join-Path $outDir 'lab-sql.csv'
    $sqlDefs = @($defs | Where-Object { $_.Roles -contains 'SQL' })
    if ($sqlDefs.Count -gt 0 -and [string]$config.Roles.SQL.AuthenticationMode -eq 'Mixed') {
        $saRow = $null
        if (Test-Path -LiteralPath $sqlFile) { $saRow = @(Import-Csv -LiteralPath $sqlFile | Where-Object { $_.Login -eq 'sa' }) | Select-Object -First 1 }
        if (-not $saRow) {
            $saRow = [pscustomobject]@{ Login = 'sa'; Password = (New-LabPassword -Length ([math]::Max(16, [int]$config.Accounts.PasswordLength))); Servers = '' }
            Write-LabLog "Generated the SQL Server sa password -> $sqlFile"
        }
        $instance = [string]$config.Roles.SQL.InstanceName
        $saRow.Servers = (@($sqlDefs | ForEach-Object { if ($instance -ieq 'MSSQLSERVER') { "$($_.Name).$($config.Domain.Fqdn)" } else { "$($_.Name).$($config.Domain.Fqdn)\$instance" } }) -join ';')
        $saRow | Select-Object Login, Password, Servers | Export-Csv -LiteralPath $sqlFile -NoTypeInformation -Encoding UTF8
        Protect-LabFile -Path $sqlFile
        $sqlSaCred = New-Object System.Management.Automation.PSCredential('sa', (ConvertTo-SecureString -String ([string]$saRow.Password) -AsPlainText -Force))
    }

    # --- Phases ---
    $validation = $null
    foreach ($p in $run) {
        try {
            $r = Invoke-LabPhase -Name $p -ConfigJson $configJson -AdminCredential $adminCred -AccountsJson $accountsJson -IsoSource $IsoSource -SqlSaCredential $sqlSaCred
            if ($p -eq 'Validate') { $validation = $r }
        } catch {
            Write-LabLog "Phase $p failed: $($_.Exception.Message)" -Level ERROR
            $rest = $allPhases[([array]::IndexOf($allPhases, $p))..($allPhases.Count - 1)] -join ','
            Write-LabLog "Fix the cause, then resume with: .\scripts\Invoke-LabBuild.ps1 -ConfigPath `"$ConfigPath`" -Phase $rest" -Level ERROR
            throw
        }
    }

    # --- Summary (no secrets) ---
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# Lab $($config.LabName) - summary")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- Built on host: $env:COMPUTERNAME, $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$sb.AppendLine("- Domain: $($config.Domain.Fqdn) (NetBIOS $($config.Domain.NetBiosName)), switch $($config.Network.SwitchName) ($($config.Network.SwitchType))")
    [void]$sb.AppendLine("- Administrator: $($config.Domain.NetBiosName)\Administrator - password: (Import-Clixml '$credFile').GetNetworkCredential().Password")
    [void]$sb.AppendLine("- Accounts ($wantAdmins domain admins, $wantUsers test users): $accFile")
    if ($config.Accounts.TestUsersAreLocalAdmins) { [void]$sb.AppendLine("- Test users ($(@($config.Groups)[0].Name)) are local administrators on the workstations") }
    if ($sqlDefs.Count -gt 0) {
        $sqlCfg = $config.Roles.SQL
        $inst = [string]$sqlCfg.InstanceName
        $targets = @($sqlDefs | ForEach-Object { if ($inst -ieq 'MSSQLSERVER') { "$($_.Name).$($config.Domain.Fqdn),$($sqlCfg.TcpPort)" } else { "$($_.Name).$($config.Domain.Fqdn)\$inst (TCP $($sqlCfg.TcpPort))" } })
        [void]$sb.AppendLine("- SQL Server ($($sqlCfg.Description)): $($targets -join '; '); $($sqlCfg.AuthenticationMode) authentication")
        if ([string]$sqlCfg.DatabaseName) { [void]$sb.AppendLine("  - test database $($sqlCfg.DatabaseName) (db_owner: $(@($sqlCfg.DbOwnerGroups) -join ', '))") }
        if ($sqlSaCred) { [void]$sb.AppendLine("  - sa password: $sqlFile") }
    }
    if ($validation) { [void]$sb.AppendLine("- Validation: $($validation.Passed) passed, $($validation.Failed) failed - $($validation.ReportPath)") }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- Image library (shared by all labs): $(Get-LabLibraryRoot -Config $config); lab manifest: $(Join-Path $config.Paths.LabRoot 'lab.json')")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| VM (Hyper-V) | Computer | Type | OS | Roles | IP | vCPU | RAM | Disk (dynamic) |')
    [void]$sb.AppendLine('|---|---|---|---|---|---|---|---|---|')
    foreach ($d in $defs) {
        $roles = @($d.Roles + $d.AdditionalFeatures); if ($d.Role -eq 'DomainController') { $roles = @('AD DS', 'DNS') + $roles }
        $osName = [string]$config.Iso.Images.($d.Image).Description -replace ' \((en-US|ISO supplied by the tester)\)$', ''
        [void]$sb.AppendLine(("| {0} | {1}.{2} | {3} | {4} | {5} | {6} | {7} | {8:N0} GB | {9:N0} GB |" -f $d.VMName, $d.Name, $config.Domain.Fqdn, $d.Role, $osName, ($roles -join ', '), $d.IPAddress, $d.ProcessorCount, ($d.MemoryBytes / 1GB), ($d.DiskSizeBytes / 1GB)))
    }
    $summary = Join-Path $outDir 'lab-summary.md'
    Set-Content -LiteralPath $summary -Value $sb.ToString() -Encoding UTF8
    if ($validation -and (Test-Path -LiteralPath $validation.ReportPath)) { Copy-Item -LiteralPath $validation.ReportPath -Destination $outDir -Force }

    Write-LabLog "Done. Summary: $summary" -Level OK
    if ($validation -and $validation.Failed -gt 0) {
        Write-LabLog "$($validation.Failed) validation check(s) failed - see $($validation.ReportPath)" -Level WARN
        $global:LASTEXITCODE = 2
    }
}
finally {
    Stop-Transcript | Out-Null
}
