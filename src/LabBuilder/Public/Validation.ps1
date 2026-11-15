function Test-LabEnvironment {
    <#
    .SYNOPSIS
        Phase Validate (FR-12): host/VM layout and isolation, DCs and replication, accounts and groups, DNS,
        each catalog role, workstations, client access to web/file/SQL roles, account logon.
        Writes <LabRoot>\Reports\validation-<timestamp>.md/.json.
    .OUTPUTS
        PSCustomObject with Passed, Failed, Results, ReportPath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][pscredential]$AdminCredential,
        [Parameter(Mandatory)][string]$AccountsJson,
        [pscredential]$SqlSaCredential
    )

    $results = New-Object System.Collections.Generic.List[object]
    $add = {
        param($Target, $Check, $Passed, $Detail)
        $results.Add([pscustomobject]@{ Target = $Target; Check = $Check; Passed = [bool]$Passed; Detail = [string]$Detail })
    }
    $addMany = {
        param($Target, $Items)
        foreach ($i in @($Items)) { if ($i) { & $add $Target $i.Check $i.Passed $i.Detail } }
    }
    $remote = {
        # Runs a check script block in a VM; a failure to connect becomes one failed check.
        param($Def, $Block, $ArgList)
        try { & $addMany $Def.Name (Invoke-LabVMCommand -VMName $Def.VMName -Credential $domainCred -ScriptBlock $Block -ArgumentList $ArgList) }
        catch { & $add $Def.Name 'PowerShell Direct (domain admin)' $false $_.Exception.Message }
    }
    # In-VM check blocks: first line is param(...); the $out list and $c adder are inserted after it.
    $prologue = '$out = New-Object System.Collections.Generic.List[object]; $c = { param($n, $p, $d) $out.Add([pscustomobject]@{ Check = $n; Passed = [bool]$p; Detail = [string]$d }) }'

    $newCheck = {
        param([string]$Text)
        $parts = $Text -split "`n", 2
        [scriptblock]::Create($parts[0] + "`n" + $prologue + "`n" + $parts[1])
    }

    $fqdn = [string]$Config.Domain.Fqdn
    $nb = [string]$Config.Domain.NetBiosName
    $domainCred = Get-LabDomainCredential -Config $Config -AdminCredential $AdminCredential
    $defs = @(Get-LabVmDefinition -Config $Config)
    $dcs = @($defs | Where-Object Role -eq 'DomainController' | Sort-Object Index)
    $rootDc = $dcs[0]
    $workstations = @($defs | Where-Object Role -eq 'Workstation')
    $client = $rootDc; if ($workstations.Count -gt 0) { $client = $workstations[0] }
    $accounts = @($AccountsJson | ConvertFrom-Json | ForEach-Object { $_ })
    $caName = Get-LabCAName -Config $Config
    $caServer = @($defs | Where-Object { $_.Roles -contains 'ADCS' }) | Select-Object -First 1

    # --- Host: switch, VMs, sizes, dynamic disks, adapters ---
    $sw = Get-VMSwitch -Name $Config.Network.SwitchName -ErrorAction SilentlyContinue
    $wantType = [string]$Config.Network.SwitchType
    $swDetail = 'missing'; if ($sw) { $swDetail = [string]$sw.SwitchType }
    if ($wantType -eq 'Internal') { $swDetail += ' (tester choice: host can reach the lab, not isolated)' }
    & $add 'Host' "Switch $($Config.Network.SwitchName) is $wantType" ($sw -and [string]$sw.SwitchType -eq $wantType) $swDetail
    foreach ($d in $defs) {
        $vm = Get-VM -Name $d.VMName -ErrorAction SilentlyContinue
        $vmState = 'missing'; if ($vm) { $vmState = [string]$vm.State }
        & $add 'Host' "$($d.VMName) running" ($vm -and $vm.State -eq 'Running') $vmState
        if (-not $vm) { continue }
        & $add 'Host' "$($d.VMName) has $($d.ProcessorCount) vCPU / $([math]::Round($d.MemoryBytes / 1GB)) GB RAM" ($vm.ProcessorCount -eq $d.ProcessorCount -and $vm.MemoryStartup -eq $d.MemoryBytes) ("{0} vCPU / {1:N0} GB" -f $vm.ProcessorCount, ($vm.MemoryStartup / 1GB))
        $hdd = Get-VMHardDiskDrive -VMName $d.VMName | Select-Object -First 1
        $vhd = $null; if ($hdd) { $vhd = Get-VHD -Path $hdd.Path -ErrorAction SilentlyContinue }
        $vhdDetail = 'no disk'; if ($vhd) { $vhdDetail = ('{0}, {1:N0} GB' -f $vhd.VhdType, ($vhd.Size / 1GB)) }
        & $add 'Host' ("$($d.VMName) disk is dynamic {0:N0} GB" -f ($d.DiskSizeBytes / 1GB)) ($vhd -and [string]$vhd.VhdType -eq 'Dynamic' -and $vhd.Size -eq $d.DiskSizeBytes) $vhdDetail
        $nics = @(Get-VMNetworkAdapter -VMName $d.VMName)
        $foreign = @($nics | Where-Object { $_.SwitchName -ne $Config.Network.SwitchName })
        & $add 'Host' "$($d.VMName) adapters only on lab switch" ($nics.Count -ge 1 -and $foreign.Count -eq 0) (($nics | ForEach-Object { [string]$_.SwitchName }) -join ', ')
    }

    # --- Operating system of every VM (FR-22, ADR 0013) ---
    $osCheck = & $newCheck @'
param($Pattern, $Label)
$os = Get-CimInstance Win32_OperatingSystem
& $c "OS is $Label" ($os.Caption -like $Pattern) "$($os.Caption) $($os.BuildNumber)"
return $out.ToArray()
'@
    foreach ($d in $defs) {
        $img = $Config.Iso.Images.($d.Image)
        $label = [string]$img.Description -replace ' \((en-US|ISO supplied by the tester)\)$', ''
        & $remote $d $osCheck @(([string]$img.CaptionPattern), $label)
    }

    # --- Forest root DC: domain, DC list, accounts, groups, DNS, CA publication ---
    $dcCheck = & $newCheck @'
param($Fqdn, $NetBios, $DcNames, $OuRoot, $GroupsJson, $AccountsJson, $AllNames, $CAName, $ExpectMembers)
$env:ADPS_LoadDefaultDrive = 0; Import-Module ActiveDirectory -WarningAction SilentlyContinue
$dom = Get-ADDomain
& $c "Domain FQDN is $Fqdn" ($dom.DNSRoot -ieq $Fqdn) $dom.DNSRoot
& $c "NetBIOS name is $NetBios" ($dom.NetBIOSName -ieq $NetBios) $dom.NetBIOSName
& $c 'Forest root domain' ((Get-ADForest).RootDomain -ieq $Fqdn) (Get-ADForest).RootDomain
$found = @(Get-ADDomainController -Filter * | ForEach-Object Name)
$missing = @($DcNames | Where-Object { $found -notcontains $_ })
& $c "Domain controllers: $($DcNames -join ', ')" ($missing.Count -eq 0) ("found: " + ($found -join ', '))
$rootDn = "OU=$OuRoot,$($dom.DistinguishedName)"
$da = Get-ADGroup -Identity ('{0}-512' -f $dom.DomainSID.Value)
$daMembers = @(Get-ADGroupMember -Identity $da -Recursive | ForEach-Object SamAccountName)
foreach ($a in ($AccountsJson | ConvertFrom-Json)) {
    $ou = "OU=Users,$rootDn"; if ([string]$a.Type -eq 'DomainAdmin') { $ou = "OU=Admins,$rootDn" }
    $usr = Get-ADUser -Filter "SamAccountName -eq '$($a.SamAccountName)'" -SearchBase $ou -ErrorAction SilentlyContinue
    $detail = 'missing'; if ($usr) { $detail = $usr.DistinguishedName }
    & $c "$($a.Type) $($a.SamAccountName) exists and is enabled" ($usr -and $usr.Enabled) $detail
    if ([string]$a.Type -eq 'DomainAdmin') { & $c "$($a.SamAccountName) is in Domain Admins" ($daMembers -contains $a.SamAccountName) $da.Name }
}
foreach ($g in ($GroupsJson | ConvertFrom-Json)) {
    $grp = Get-ADGroup -Filter "SamAccountName -eq '$($g.Name)'" -SearchBase "OU=Groups,$rootDn" -ErrorAction SilentlyContinue
    $n = 0; if ($grp) { $n = @(Get-ADGroupMember -Identity $grp).Count }
    $ok = ($grp -and $grp.GroupCategory -eq 'Security'); if ($ExpectMembers) { $ok = $ok -and $n -ge 1 }
    & $c "Security group $($g.Name)" $ok "$n member(s)"
}
foreach ($name in $AllNames) {
    $rec = Resolve-DnsName -Name "$name.$Fqdn" -Type A -DnsOnly -ErrorAction SilentlyContinue | Where-Object Type -eq 'A'
    & $c "DNS A record $name.$Fqdn" ([bool]$rec) (($rec | ForEach-Object IPAddress) -join ',')
}
if ($CAName) {
    $cfg = (Get-ADRootDSE).configurationNamingContext
    $caObj = Get-ADObject -SearchBase "CN=Certification Authorities,CN=Public Key Services,CN=Services,$cfg" -Filter "Name -eq '$CAName'" -ErrorAction SilentlyContinue
    & $c "Enterprise Root CA '$CAName' published in AD" ([bool]$caObj) ''
}
return $out.ToArray()
'@
    $caForCheck = ''; if ($caServer) { $caForCheck = $caName }
    & $remote $rootDc $dcCheck @($fqdn, $nb, ([string[]]@($dcs | ForEach-Object Name)), ([string]$Config.Domain.OuRoot),
        (ConvertTo-Json -InputObject @($Config.Groups) -Compress), $AccountsJson, ([string[]]@($defs | ForEach-Object Name)), $caForCheck,
        ([bool](@($accounts | Where-Object { [string]$_.Type -ne 'DomainAdmin' }).Count -gt 0)))

    # --- Every DC: services and replication ---
    $dcSvc = & $newCheck @'
param($Multi)
foreach ($s in @('NTDS', 'DNS', 'Netlogon', 'ADWS', 'Kdc')) {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    $st = 'missing'; if ($svc) { $st = [string]$svc.Status }
    & $c "Service $s running" ($svc -and $svc.Status -eq 'Running') $st
}
if ($Multi) {
    $env:ADPS_LoadDefaultDrive = 0; Import-Module ActiveDirectory -WarningAction SilentlyContinue
    $f = @(Get-ADReplicationFailure -Target $env:COMPUTERNAME -ErrorAction SilentlyContinue | Where-Object { $_.FailureCount -gt 0 })
    & $c 'AD replication without failures' ($f.Count -eq 0) "$($f.Count) failure(s)"
}
return $out.ToArray()
'@
    foreach ($dc in $dcs) { & $remote $dc $dcSvc @(($dcs.Count -gt 1)) }

    # --- Member servers: membership ---
    $member = & $newCheck @'
param($Fqdn)
$cs = Get-CimInstance Win32_ComputerSystem
& $c "Member of $Fqdn" ($cs.PartOfDomain -and $cs.Domain -ieq $Fqdn) $cs.Domain
& $c 'Secure channel to DC' (Test-ComputerSecureChannel -ErrorAction SilentlyContinue) ''
return $out.ToArray()
'@
    foreach ($s in @($defs | Where-Object Role -eq 'MemberServer')) { & $remote $s $member @($fqdn) }

    # --- Roles ---
    foreach ($s in @($defs | Where-Object { $_.Role -ne 'Workstation' -and $_.Roles.Count -gt 0 })) {
        $roleCheck = & $newCheck @'
param($Roles, $CAName, $Https, $IP, $ScopeId, $Share)
if ($Roles -contains 'ADCS') {
    $svc = Get-Service CertSvc -ErrorAction SilentlyContinue
    & $c 'AD CS service (CertSvc) running' ($svc -and $svc.Status -eq 'Running') ''
    $null = & certutil.exe -ping 2>&1
    & $c 'CA answers (certutil -ping)' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
}
if ($Roles -contains 'DHCP') {
    $svc = Get-Service DHCPServer -ErrorAction SilentlyContinue
    & $c 'DHCP Server running' ($svc -and $svc.Status -eq 'Running') ''
    & $c 'DHCP authorised in AD' ([bool](Get-DhcpServerInDC -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $IP })) ''
    $sc = Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue
    $st = 'missing'; if ($sc) { $st = "$($sc.StartRange)-$($sc.EndRange) $($sc.State)" }
    & $c "DHCP scope $ScopeId active" ($sc -and [string]$sc.State -eq 'Active') $st
}
if ($Roles -contains 'FileServer') {
    $sh = Get-SmbShare -Name $Share -ErrorAction SilentlyContinue
    $st = 'missing'; if ($sh) { $st = $sh.Path }
    & $c "SMB share $Share" ([bool]$sh) $st
}
if ($Roles -contains 'IIS') {
    $w3 = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
    & $c 'IIS (W3SVC) running' ($w3 -and $w3.Status -eq 'Running') ''
    if ($Https) {
        Import-Module WebAdministration
        $b = Get-Item 'IIS:\SslBindings\0.0.0.0!443' -ErrorAction SilentlyContinue
        $cert = $null
        if ($b) { $cert = Get-Item ("Cert:\LocalMachine\My\" + $b.Thumbprint) -ErrorAction SilentlyContinue }
        $st = 'no binding'; if ($cert) { $st = "$($cert.Subject) / $($cert.Issuer) / until $($cert.NotAfter.ToString('yyyy-MM-dd'))" }
        & $c "HTTPS certificate issued by $CAName" ($cert -and $cert.Issuer -like "CN=$CAName*") $st
    }
}
return $out.ToArray()
'@
        & $remote $s $roleCheck @(([string[]]$s.Roles), $caName, ([bool]$Config.Roles.IIS.EnableHttps), $s.IPAddress, "$($Config.Network.Prefix).0", ([string]$Config.Roles.FileServer.ShareName))
    }

    # --- SQL Server (FR-20): inside each SQL server, then over the network from the client ---
    $sqlDefs = @($defs | Where-Object { $_.Roles -contains 'SQL' })
    if ($sqlDefs.Count -gt 0) {
        $sqlCfg = $Config.Roles.SQL
        $sqlInstance = [string]$sqlCfg.InstanceName
        $sqlPort = [int]$sqlCfg.TcpPort
        $sqlCheck = & $newCheck @'
param($Instance, $Svc, $Port, $NetBios, $SysadminGroups, $Database, $DbOwnerGroups, $Mixed)
$s = Get-Service -Name $Svc -ErrorAction SilentlyContinue
& $c "SQL Server service $Svc running" ($s -and $s.Status -eq 'Running') ''
$listen = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
& $c "SQL Server listens on TCP $Port" ($listen.Count -gt 0) ''
& $c "Firewall allows TCP $Port" ([bool](Get-NetFirewallRule -Name "LabBuilder-SQL-$Instance-TCP" -ErrorAction SilentlyContinue)) ''
$server = '.'; if ($Instance -ine 'MSSQLSERVER') { $server = ".\$Instance" }
$query = {
    param($Text)
    $cn = New-Object System.Data.SqlClient.SqlConnection("Data Source=$server;Integrated Security=SSPI;Initial Catalog=master;Connect Timeout=15")
    try { $cn.Open(); $cmd = $cn.CreateCommand(); $cmd.CommandText = $Text; $r = $cmd.ExecuteReader(); $rows = @(); while ($r.Read()) { $v = @(); for ($i = 0; $i -lt $r.FieldCount; $i++) { $v += [string]$r.GetValue($i) }; $rows += ,$v }; $r.Close(); return ,$rows }
    finally { $cn.Dispose() }
}
try {
    $v = (& $query "SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(128)), CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)), CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int)")[0]
    & $c 'SQL Server edition is Express' ($v[0] -like '*Express*') "$($v[0]) $($v[1])"
    $mode = 'Windows'; if ($v[2] -eq '0') { $mode = 'Mixed' }
    $want = 'Windows'; if ($Mixed) { $want = 'Mixed' }
    & $c "Authentication mode $want" ($mode -eq $want) $mode
    $sys = @((& $query "SELECT p.name FROM sys.server_role_members m JOIN sys.server_principals r ON r.principal_id = m.role_principal_id JOIN sys.server_principals p ON p.principal_id = m.member_principal_id WHERE r.name = 'sysadmin'") | ForEach-Object { $_[0] })
    $domainSid = (New-Object System.Security.Principal.NTAccount("$NetBios\krbtgt")).Translate([System.Security.Principal.SecurityIdentifier]).AccountDomainSid
    $admins = (New-Object System.Security.Principal.SecurityIdentifier("$($domainSid.Value)-512")).Translate([System.Security.Principal.NTAccount]).Value
    foreach ($g in @($admins) + @($SysadminGroups | Where-Object { $_ } | ForEach-Object { "$NetBios\$_" })) {
        & $c "$g is sysadmin" (@($sys | Where-Object { $_ -ieq $g }).Count -gt 0) ''
    }
    if ($Database) {
        $db = '[' + $Database.Replace(']', ']]') + ']'
        $n = [int]((& $query "SELECT COUNT(*) FROM $db.dbo.LabCheck WHERE Note = N'LAB-SQL-OK'")[0][0])
        & $c "Database $Database with LabCheck row" ($n -ge 1) "$n row(s)"
        $owners = @((& $query "SELECT p.name FROM $db.sys.database_role_members m JOIN $db.sys.database_principals r ON r.principal_id = m.role_principal_id JOIN $db.sys.database_principals p ON p.principal_id = m.member_principal_id WHERE r.name = 'db_owner'") | ForEach-Object { $_[0] })
        foreach ($g in @($DbOwnerGroups | Where-Object { $_ })) { & $c "$NetBios\$g is db_owner of $Database" (@($owners | Where-Object { $_ -ieq "$NetBios\$g" }).Count -gt 0) '' }
    }
} catch { & $c 'SQL Server answers queries (Windows authentication)' $false $_.Exception.Message }
return $out.ToArray()
'@
        foreach ($s in $sqlDefs) {
            & $remote $s $sqlCheck @($sqlInstance, (Get-LabSqlServiceName -InstanceName $sqlInstance), $sqlPort, $nb,
                ([string[]]@($sqlCfg.SysadminGroups | Where-Object { $_ })), ([string]$sqlCfg.DatabaseName),
                ([string[]]@($sqlCfg.DbOwnerGroups | Where-Object { $_ })), ([string]$sqlCfg.AuthenticationMode -eq 'Mixed'))
        }

        $sqlNet = & $newCheck @'
param($Hosts, $Port, $Database, $SaPassword)
foreach ($h in @($Hosts)) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $ok = $false; $d = ''
    try { $ok = $tcp.ConnectAsync($h, $Port).Wait(10000) -and $tcp.Connected } catch { $d = $_.Exception.InnerException.Message } finally { $tcp.Close() }
    & $c "TCP $h`:$Port reachable" $ok $d
    $logins = @(@{ Name = 'Windows authentication (domain admin)'; Cs = "Data Source=tcp:$h,$Port;Integrated Security=SSPI;Connect Timeout=15" })
    if ($SaPassword) { $logins += @{ Name = 'SQL authentication (sa)'; Cs = "Data Source=tcp:$h,$Port;User ID=sa;Password=$SaPassword;Connect Timeout=15" } }
    foreach ($l in $logins) {
        $cat = 'master'; if ($Database) { $cat = $Database }
        $cn = New-Object System.Data.SqlClient.SqlConnection(($l.Cs + ";Initial Catalog=$cat"))
        $ok = $false; $d = ''
        try { $cn.Open(); $cmd = $cn.CreateCommand(); $cmd.CommandText = 'SELECT @@SERVERNAME'; $d = [string]$cmd.ExecuteScalar(); $ok = $true }
        catch { $d = $_.Exception.Message } finally { $cn.Dispose() }
        & $c "SQL $h`:$Port $($l.Name)" $ok $d
    }
}
return $out.ToArray()
'@
        $saPw = ''
        if ($SqlSaCredential -and [string]$sqlCfg.AuthenticationMode -eq 'Mixed') { $saPw = $SqlSaCredential.GetNetworkCredential().Password }
        $sqlHosts = [string[]]@($sqlDefs | ForEach-Object { "$($_.Name).$fqdn" })
        & $remote $client $sqlNet @($sqlHosts, $sqlPort, ([string]$sqlCfg.DatabaseName), $saPw)
    }

    # --- Workstations ---
    $wsCheck = & $newCheck @'
param($Fqdn, $AdminGroup)
$cs = Get-CimInstance Win32_ComputerSystem
& $c "Member of $Fqdn" ($cs.PartOfDomain -and $cs.Domain -ieq $Fqdn) $cs.Domain
& $c 'Secure channel to DC' (Test-ComputerSecureChannel -ErrorAction SilentlyContinue) ''
if ($AdminGroup) {
    $m = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue | ForEach-Object Name)
    & $c "$AdminGroup in local Administrators" ($m -contains $AdminGroup) ($m -join ', ')
}
return $out.ToArray()
'@
    $adminGroup = ''
    if ($Config.Accounts.TestUsersAreLocalAdmins) { $adminGroup = '{0}\{1}' -f $nb, (@($Config.Groups)[0].Name) }
    foreach ($ws in $workstations) { & $remote $ws $wsCheck @($fqdn, $adminGroup) }

    # --- Client access (first workstation, or root DC without workstations) ---
    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($s in @($defs | Where-Object { $_.Roles -contains 'IIS' })) {
        $urls.Add("http://$($s.Name).$fqdn/lab-health.html")
        if ($Config.Roles.IIS.EnableHttps) { $urls.Add("https://$($s.Name).$fqdn/lab-health.html") }
    }
    $shares = [string[]]@($defs | Where-Object { $_.Roles -contains 'FileServer' } | ForEach-Object { "\\$($_.Name).$fqdn\$($Config.Roles.FileServer.ShareName)\lab-share-ok.txt" })
    $logons = @()
    $firstUser = $accounts | Where-Object { [string]$_.Type -ne 'DomainAdmin' } | Select-Object -First 1
    $firstAdmin = $accounts | Where-Object { [string]$_.Type -eq 'DomainAdmin' } | Select-Object -First 1
    foreach ($a in @($firstUser, $firstAdmin)) { if ($a) { $logons += [string]$a.SamAccountName; $logons += [string]$a.Password } }

    $clientCheck = & $newCheck @'
param($Fqdn, $Urls, $Shares, $Logons)
if (@($Urls).Count -gt 0) { & gpupdate.exe /target:computer /force | Out-Null; & certutil.exe -pulse | Out-Null }
foreach ($u in @($Urls)) {
    try {
        $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 30
        & $c "GET $u" ($r.StatusCode -eq 200 -and $r.Content -match 'LAB-IIS-OK') "HTTP $($r.StatusCode)"
    } catch { & $c "GET $u" $false $_.Exception.Message }
}
foreach ($s in @($Shares)) {
    $ok = $false; $d = ''
    try { $ok = ((Get-Content -LiteralPath $s -ErrorAction Stop) -match 'LAB-SHARE-OK') } catch { $d = $_.Exception.Message }
    & $c "Read $s" $ok $d
}
for ($i = 0; $i -lt @($Logons).Count; $i += 2) {
    $user = $Logons[$i]; $pw = $Logons[$i + 1]
    $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$Fqdn", "$user@$Fqdn", $pw)
    $ok = $false; $d = ''
    try { $null = $entry.NativeObject; $ok = $true } catch { $d = $_.Exception.Message } finally { $entry.Dispose() }
    & $c "Account $user can authenticate (LDAP bind)" $ok $d
}
return $out.ToArray()
'@
    & $remote $client $clientCheck @($fqdn, ([string[]]$urls.ToArray()), $shares, ([string[]]$logons))

    # --- Report ---
    $passed = @($results | Where-Object Passed).Count
    $failed = @($results | Where-Object { -not $_.Passed }).Count
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reportDir = Join-Path ([string]$Config.Paths.LabRoot) 'Reports'
    if (-not (Test-Path -LiteralPath $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine("# Lab validation report - $($Config.LabName)")
    [void]$md.AppendLine('')
    [void]$md.AppendLine("- Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$md.AppendLine("- Host: $env:COMPUTERNAME")
    [void]$md.AppendLine("- Domain: $fqdn ($nb); $($dcs.Count) DC(s), $(@($defs | Where-Object Role -eq 'MemberServer').Count) member server(s), $($workstations.Count) workstation(s)")
    [void]$md.AppendLine("- Result: **$passed passed, $failed failed**")
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Target | Check | Result | Detail |')
    [void]$md.AppendLine('|--------|-------|--------|--------|')
    foreach ($r in $results) {
        $res = 'FAIL'; if ($r.Passed) { $res = 'PASS' }
        [void]$md.AppendLine(('| {0} | {1} | {2} | {3} |' -f $r.Target, $r.Check, $res, ($r.Detail -replace '\|', '/' -replace "`r?`n", ' ')))
    }
    $mdPath = Join-Path $reportDir "validation-$stamp.md"
    Set-Content -LiteralPath $mdPath -Value $md.ToString() -Encoding UTF8
    ConvertTo-Json -InputObject @($results.ToArray()) -Depth 4 | Set-Content -LiteralPath (Join-Path $reportDir "validation-$stamp.json") -Encoding UTF8

    foreach ($r in $results) {
        $lvl = 'OK'; if (-not $r.Passed) { $lvl = 'ERROR' }
        Write-LabLog ('{0,-8} {1}  {2}' -f $r.Target, $r.Check, $r.Detail) -Level $lvl
    }
    $sumLevel = 'OK'; if ($failed) { $sumLevel = 'WARN' }
    Write-LabLog "Validation: $passed passed, $failed failed. Report: $mdPath" -Level $sumLevel

    return [pscustomobject]@{ Passed = $passed; Failed = $failed; ReportPath = $mdPath; Results = $results.ToArray() }
}
