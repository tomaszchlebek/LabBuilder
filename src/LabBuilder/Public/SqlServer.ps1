# Role SQL: SQL Server Express, unattended (FR-20, ADR 0012). All functions run on the Hyper-V host
# (media download also on any Windows machine via scripts\Get-LabIso.ps1).

function Test-LabSqlRequired {
    # True when at least one server carries role SQL.
    param([Parameter(Mandatory)]$Config)
    return (@(Get-LabVmDefinition -Config $Config -Role Server | Where-Object { $_.Roles -contains 'SQL' }).Count -gt 0)
}

function Get-LabSqlServiceName {
    param([Parameter(Mandatory)][string]$InstanceName)
    if ($InstanceName -ieq 'MSSQLSERVER') { return 'MSSQLSERVER' }
    return ('MSSQL${0}' -f $InstanceName)
}

function Test-LabMicrosoftSignature {
    <#
    Authenticode check: the file must carry a valid signature whose signer is Microsoft Corporation.
    Used instead of a pinned hash because Microsoft updates the SQL media in place.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    $subject = ''
    if ($sig.SignerCertificate) { $subject = [string]$sig.SignerCertificate.Subject }
    return [pscustomobject]@{
        Valid   = ([string]$sig.Status -eq 'Valid' -and $subject -match '(^|,\s*)O=Microsoft Corporation(,|$)')
        Status  = [string]$sig.Status
        Subject = $subject
    }
}

function Read-LabSqlMediaManifest {
    param([Parameter(Mandatory)][string]$Folder)
    $file = Join-Path $Folder 'sql-media.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $m = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    return $m
}

function Confirm-LabSqlPackage {
    # Returns the manifest entry when <Folder>\<FileName> matches it (size + timestamp) and is Microsoft-signed; else $null.
    param([Parameter(Mandatory)][string]$Folder)
    $m = Read-LabSqlMediaManifest -Folder $Folder
    if (-not $m) { return $null }
    $path = Join-Path $Folder ([string]$m.FileName)
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $item = Get-Item -LiteralPath $path
    if ($item.Length -ne [int64]$m.Length -or $item.LastWriteTimeUtc.Ticks -ne [int64]$m.LastWriteTicks) { return $null }
    if (-not (Test-LabMicrosoftSignature -Path $path).Valid) { return $null }
    return $m
}

function Write-LabSqlMediaManifest {
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$Path, [string]$Source = '')
    $item = Get-Item -LiteralPath $Path
    $sig = Test-LabMicrosoftSignature -Path $Path
    $entry = [ordered]@{
        FileName       = $item.Name
        Length         = $item.Length
        LastWriteTicks = $item.LastWriteTimeUtc.Ticks
        Sha256         = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
        Version        = [string]$item.VersionInfo.ProductVersion
        Signer         = $sig.Subject
        Source         = $Source
        Recorded       = (Get-Date).ToString('s')
    }
    ConvertTo-Json -InputObject $entry | Set-Content -LiteralPath (Join-Path $Folder 'sql-media.json') -Encoding ASCII
    return [pscustomobject]$entry
}

function Save-LabSqlMedia {
    <#
    .SYNOPSIS
        Makes the SQL Server Express offline package available in <Destination>\SQL (phase Iso, Get-LabIso.ps1 -IncludeSql).
    .DESCRIPTION
        1. Downloads the official web installer (Roles.SQL.BootstrapperUrl; redirects checked like the ISOs).
        2. Checks its Authenticode signature (Microsoft Corporation).
        3. Runs it with /ACTION=Download /MEDIATYPE=<MediaType> /QUIET, which fetches the offline package (SQLEXPR_x64_ENU.exe).
        4. Checks the package signature and records it in sql-media.json (size, SHA-256, version).
        A verified package already in the folder is reused. A tester can also put a package downloaded by hand
        (web installer -> Download Media -> Express Core) into <ISO folder>\SQL.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Destination
    )
    $sql = $Config.Roles.SQL
    $dir = Join-Path $Destination 'SQL'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $ok = Confirm-LabSqlPackage -Folder $dir
    if ($ok) { Write-LabLog "SQL media cached and verified: $dir\$($ok.FileName) ($($ok.Version), SHA-256 $($ok.Sha256))" -Level OK; return $ok }

    # A package placed here by hand (no manifest yet).
    $manual = Get-ChildItem -LiteralPath $dir -Filter ([string]$sql.PackagePattern) -File -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 1
    if ($manual) {
        $sig = Test-LabMicrosoftSignature -Path $manual.FullName
        if (-not $sig.Valid) { throw "$($manual.FullName) is not signed by Microsoft (signature $($sig.Status), '$($sig.Subject)'). Delete it." }
        $m = Write-LabSqlMediaManifest -Folder $dir -Path $manual.FullName -Source 'placed in folder'
        Write-LabLog "SQL media found and verified: $($manual.FullName) ($($m.Version))" -Level OK
        return $m
    }

    Write-LabLog "SQL media ($($sql.Description)): resolving $($sql.BootstrapperUrl)" -Level STEP
    $resolved = Resolve-LabDownloadUrl -Url ([string]$sql.BootstrapperUrl) -AllowedHosts @($Config.Iso.AllowedDownloadHosts)
    $bootName = Split-Path ([uri]$resolved.Url).AbsolutePath -Leaf
    if ($bootName -notmatch '^[A-Za-z0-9_.-]+\.exe$') { throw "Unexpected web installer name '$bootName' from $($resolved.Url)." }
    $boot = Join-Path $dir $bootName
    if (-not ((Test-Path -LiteralPath $boot) -and (Get-Item -LiteralPath $boot).Length -eq $resolved.ContentLength)) {
        if (Test-Path -LiteralPath $boot) { Remove-Item -LiteralPath $boot -Force }
        Invoke-LabFileDownload -Url $resolved.Url -Destination $boot -ExpectedLength $resolved.ContentLength
    }
    $sig = Test-LabMicrosoftSignature -Path $boot
    if (-not $sig.Valid) {
        Move-Item -LiteralPath $boot -Destination "$boot.rejected" -Force
        throw "SQL web installer $bootName is not signed by Microsoft (signature $($sig.Status), '$($sig.Subject)'); moved to $boot.rejected."
    }
    Write-LabLog "  web installer $bootName verified (signed by Microsoft)."

    $work = Join-Path $dir 'download'
    if (-not (Test-Path -LiteralPath $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
    Write-LabLog "  downloading the offline package (/MEDIATYPE=$($sql.MediaType)) - several hundred MB ..."
    $bootArgs = @('/ACTION=Download', ('/MEDIAPATH="{0}"' -f $work), ('/MEDIATYPE={0}' -f $sql.MediaType), '/QUIET')
    $p = Start-Process -FilePath $boot -ArgumentList $bootArgs -PassThru -WindowStyle Hidden
    $null = $p.Handle
    $limit = (Get-Date).AddMinutes([int]$sql.SetupTimeoutMinutes)
    while (-not $p.HasExited) {
        if ((Get-Date) -gt $limit) { try { $p.Kill() } catch { }; throw "SQL web installer did not finish within $($sql.SetupTimeoutMinutes) minutes." }
        Start-Sleep -Seconds 10
    }
    $p.WaitForExit()
    $pkg = Get-ChildItem -LiteralPath $work -Recurse -Filter ([string]$sql.PackagePattern) -File -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 1
    if (-not $pkg) {
        throw ("SQL web installer exited with code {0} and produced no {1} in {2}. Download the media by hand " +
            "(run {3} -> Download Media -> Express Core) and put the package into {4}, then run phase Iso again.") -f $p.ExitCode, $sql.PackagePattern, $work, $bootName, $dir
    }
    $sig = Test-LabMicrosoftSignature -Path $pkg.FullName
    if (-not $sig.Valid) { throw "$($pkg.FullName) is not signed by Microsoft (signature $($sig.Status)); not used." }
    $final = Join-Path $dir $pkg.Name
    Move-Item -LiteralPath $pkg.FullName -Destination $final -Force
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    $m = Write-LabSqlMediaManifest -Folder $dir -Path $final -Source $resolved.Url
    Write-LabLog ('SQL media ready: {0} ({1}, {2:N0} MB, SHA-256 {3})' -f $final, $m.Version, ($m.Length / 1MB), $m.Sha256) -Level OK
    return $m
}

function Import-LabSqlMedia {
    # Copies <Source>\SQL\<package> (pre-downloaded with Get-LabIso.ps1 -IncludeSql) into the image library <Library>\ISO\SQL.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Source)
    $src = Join-Path $Source 'SQL'
    $dst = Join-Path (Get-LabLibraryIsoFolder -Config $Config) 'SQL'
    if (Confirm-LabSqlPackage -Folder $dst) { Write-LabLog 'SQL media already on the host.' -Level OK; return }
    $pkg = Get-ChildItem -LiteralPath $src -Filter ([string]$Config.Roles.SQL.PackagePattern) -File -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 1
    if (-not $pkg) { Write-LabLog "No SQL media in $src - it will be downloaded." -Level WARN; return }
    $sig = Test-LabMicrosoftSignature -Path $pkg.FullName
    if (-not $sig.Valid) { throw "$($pkg.FullName) is not signed by Microsoft (signature $($sig.Status)); not imported." }
    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    Write-LabLog "Importing SQL media $($pkg.Name) from $src ..." -Level STEP
    Copy-Item -LiteralPath $pkg.FullName -Destination (Join-Path $dst $pkg.Name) -Force
    $m = Write-LabSqlMediaManifest -Folder $dst -Path (Join-Path $dst $pkg.Name) -Source $pkg.FullName
    Write-LabLog "SQL media imported and verified ($($m.Version))." -Level OK
}

function Get-LabSqlMediaPath {
    param([Parameter(Mandatory)]$Config)
    $dir = Join-Path (Get-LabLibraryIsoFolder -Config $Config) 'SQL'
    $m = Confirm-LabSqlPackage -Folder $dir
    if (-not $m) { throw "SQL Server media missing or not verified in $dir - run phase Iso." }
    return (Join-Path $dir ([string]$m.FileName))
}

function Install-LabSqlServer {
    <#
    .SYNOPSIS
        Role SQL on one member server: copies the offline package into the VM (PowerShell Direct), extracts it,
        runs SQL Setup unattended from a configuration file (deleted afterwards; holds the sa password in Mixed mode),
        then - on every run - static TCP port, firewall, SQL Browser for named instances, sysadmin logins,
        test database with db_owner groups and a LabCheck table.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][pscredential]$AdminCredential,
        [pscredential]$SaCredential
    )
    $d = $Definition
    $sql = $Config.Roles.SQL
    $cred = Get-LabDomainCredential -Config $Config -AdminCredential $AdminCredential
    $nb = ([string]$Config.Domain.NetBiosName).ToUpperInvariant()
    $instance = [string]$sql.InstanceName
    $mixed = ([string]$sql.AuthenticationMode -eq 'Mixed')
    if ($mixed -and -not $SaCredential) { throw 'Roles.SQL.AuthenticationMode is Mixed but no sa password was passed (Invoke-LabBuild.ps1 creates lab-sql.csv).' }
    $svc = Get-LabSqlServiceName -InstanceName $instance

    $installed = Invoke-LabVMCommand -VMName $d.VMName -Credential $cred -ArgumentList $svc -ScriptBlock {
        param($Svc) [bool](Get-Service -Name $Svc -ErrorAction SilentlyContinue)
    }
    if ($installed) {
        Write-LabLog "  [$($d.Name)] SQL Server instance $instance already installed." -Level OK
    } else {
        $pkg = Get-LabSqlMediaPath -Config $Config
        $pkgItem = Get-Item -LiteralPath $pkg
        $remotePkg = 'C:\LabMedia\SQL\' + $pkgItem.Name
        Write-LabLog ('  [{0}] copying SQL media {1} ({2:N0} MB) into the VM ...' -f $d.Name, $pkgItem.Name, ($pkgItem.Length / 1MB)) -Level STEP
        $session = New-PSSession -VMName $d.VMName -Credential $cred -ErrorAction Stop
        try {
            $need = Invoke-Command -Session $session -ArgumentList $remotePkg, $pkgItem.Length -ScriptBlock {
                param($P, $Len)
                New-Item -ItemType Directory -Path (Split-Path $P) -Force | Out-Null
                -not ((Test-Path -LiteralPath $P) -and (Get-Item -LiteralPath $P).Length -eq $Len)
            }
            if ($need) { Copy-Item -LiteralPath $pkg -Destination $remotePkg -ToSession $session -Force -ErrorAction Stop }
        } finally { Remove-PSSession -Session $session }

        Write-LabLog "  [$($d.Name)] installing SQL Server ($($sql.Description)), instance $instance, $($sql.AuthenticationMode) authentication - 10-30 min ..." -Level STEP
        $saPw = ''
        if ($mixed) { $saPw = $SaCredential.GetNetworkCredential().Password }
        $groups = [string[]]@($sql.SysadminGroups | Where-Object { $_ })
        $r = Invoke-LabVMCommand -VMName $d.VMName -Credential $cred -ArgumentList $remotePkg, $instance, $svc, $mixed, $saPw, $groups, ([string]$sql.Collation), $nb, ([int]$sql.SetupTimeoutMinutes) -ScriptBlock {
            param($Package, $Instance, $Svc, $Mixed, $SaPassword, $SysadminGroups, $Collation, $NetBios, $TimeoutMinutes)
            $ErrorActionPreference = 'Stop'
            $extract = 'C:\LabMedia\SQL\Setup'
            if (-not (Test-Path -LiteralPath "$extract\setup.exe")) {
                $x = Start-Process -FilePath $Package -ArgumentList '/q', "/x:$extract" -Wait -PassThru
                if (-not (Test-Path -LiteralPath "$extract\setup.exe")) { throw "Extracting $Package failed (exit $($x.ExitCode))." }
            }
            # Domain Admins by well-known RID (any OS language); krbtgt exists in every domain.
            $domainSid = (New-Object System.Security.Principal.NTAccount("$NetBios\krbtgt")).Translate([System.Security.Principal.SecurityIdentifier]).AccountDomainSid
            $admins = (New-Object System.Security.Principal.SecurityIdentifier("$($domainSid.Value)-512")).Translate([System.Security.Principal.NTAccount]).Value
            $sysadmins = @($admins) + @($SysadminGroups | Where-Object { $_ } | ForEach-Object { "$NetBios\$_" })
            $svcAccount = 'NT Service\' + $Svc
            $lines = New-Object System.Collections.Generic.List[string]
            $lines.Add('[OPTIONS]')
            $lines.Add('ACTION="Install"')
            $lines.Add('QUIET="True"')
            $lines.Add('UPDATEENABLED="False"')
            $lines.Add('FEATURES=SQLENGINE')
            $lines.Add("INSTANCENAME=""$Instance""")
            $lines.Add("INSTANCEID=""$Instance""")
            $lines.Add("SQLSVCACCOUNT=""$svcAccount""")
            $lines.Add('SQLSVCSTARTUPTYPE="Automatic"')
            $lines.Add('TCPENABLED="1"')
            $lines.Add('NPENABLED="0"')
            $lines.Add('SQLSYSADMINACCOUNTS=' + (($sysadmins | ForEach-Object { '"' + $_ + '"' }) -join ' '))
            if ($Instance -ine 'MSSQLSERVER') { $lines.Add('BROWSERSVCSTARTUPTYPE="Automatic"') }
            if ($Collation) { $lines.Add("SQLCOLLATION=""$Collation""") }
            if ($Mixed) { $lines.Add('SECURITYMODE="SQL"'); $lines.Add("SAPWD=""$SaPassword""") }
            $ini = Join-Path $env:TEMP ('labbuilder-sql-{0}.ini' -f [guid]::NewGuid().ToString('N'))
            try {
                Set-Content -LiteralPath $ini -Value $lines -Encoding ASCII
                $p = Start-Process -FilePath "$extract\setup.exe" -ArgumentList ('/ConfigurationFile="{0}"' -f $ini), '/IACCEPTSQLSERVERLICENSETERMS' -PassThru -WindowStyle Hidden
                $null = $p.Handle
                if (-not $p.WaitForExit($TimeoutMinutes * 60000)) { try { $p.Kill() } catch { }; throw "SQL Setup did not finish within $TimeoutMinutes minutes." }
                $code = $p.ExitCode
            } finally {
                Remove-Item -LiteralPath $ini -Force -ErrorAction SilentlyContinue
            }
            if ($code -eq 0) { return 'installed' }
            if ($code -eq 3010) { return 'reboot' }
            $summary = Get-ChildItem -Path "$env:ProgramFiles\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $detail = ''
            if ($summary) {
                $detail = (Get-Content -LiteralPath $summary.FullName | Where-Object { $_ -match 'Exit code|Exit facility|Exit error code|Exit message|Final result|Requested action' } |
                    ForEach-Object { $_.Trim() }) -join ' | '
                $detail += " (log: $($summary.FullName))"
            }
            throw "SQL Setup failed with exit code $code. $detail"
        }
        if ($r -eq 'reboot') {
            Write-LabLog "  [$($d.Name)] SQL Setup asks for a restart." -Level INFO
            Restart-LabVM -VMName $d.VMName -Credential $cred -TimeoutMinutes ([int]$Config.Timeouts.VmReadyMinutes)
        }
        Write-LabLog "  [$($d.Name)] SQL Server installed." -Level OK
    }

    # --- Configuration, every run (idempotent) ---
    $sysGroups = [string[]]@($sql.SysadminGroups | Where-Object { $_ })
    $ownerGroups = [string[]]@($sql.DbOwnerGroups | Where-Object { $_ })
    $summary = Invoke-LabVMCommand -VMName $d.VMName -Credential $cred -RetryCount 2 -RetryDelaySeconds 30 `
        -ArgumentList $instance, $svc, ([int]$sql.TcpPort), $nb, $sysGroups, ([string]$sql.DatabaseName), $ownerGroups -ScriptBlock {
        param($Instance, $Svc, $Port, $NetBios, $SysadminGroups, $Database, $DbOwnerGroups)
        $ErrorActionPreference = 'Stop'
        $log = New-Object System.Collections.Generic.List[string]
        $id = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').$Instance
        if (-not $id) { throw "SQL instance $Instance not found in the registry." }
        $tcp = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$id\MSSQLServer\SuperSocketNetLib\Tcp"
        $restart = $false
        if ([int](Get-ItemProperty -Path $tcp).Enabled -ne 1) { Set-ItemProperty -Path $tcp -Name Enabled -Value 1; $restart = $true }
        $all = Get-ItemProperty -Path "$tcp\IPAll"
        if ([string]$all.TcpPort -ne [string]$Port -or [string]$all.TcpDynamicPorts -ne '') {
            Set-ItemProperty -Path "$tcp\IPAll" -Name TcpPort -Value ([string]$Port)
            Set-ItemProperty -Path "$tcp\IPAll" -Name TcpDynamicPorts -Value ''
            $restart = $true
        }
        Set-Service -Name $Svc -StartupType Automatic
        if ($restart) { Restart-Service -Name $Svc -Force; $log.Add("TCP $Port static") } else { Start-Service -Name $Svc }
        $rule = "LabBuilder-SQL-$Instance-TCP"
        if (-not (Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name $rule -DisplayName "LabBuilder SQL Server $Instance (TCP $Port)" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any | Out-Null
            $log.Add("firewall TCP $Port")
        } else { Set-NetFirewallRule -Name $rule -LocalPort $Port }
        if ($Instance -ine 'MSSQLSERVER') {
            Set-Service -Name SQLBrowser -StartupType Automatic; Start-Service -Name SQLBrowser
            if (-not (Get-NetFirewallRule -Name 'LabBuilder-SQL-Browser-UDP' -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -Name 'LabBuilder-SQL-Browser-UDP' -DisplayName 'LabBuilder SQL Server Browser (UDP 1434)' -Direction Inbound -Protocol UDP -LocalPort 1434 -Action Allow -Profile Any | Out-Null
                $log.Add('firewall UDP 1434 (Browser)')
            }
        }

        $server = '.'; if ($Instance -ine 'MSSQLSERVER') { $server = ".\$Instance" }
        $cs = "Data Source=$server;Integrated Security=SSPI;Initial Catalog=master;Connect Timeout=15"
        $exec = {
            param($Text)
            $cn = New-Object System.Data.SqlClient.SqlConnection($cs)
            try { $cn.Open(); $cmd = $cn.CreateCommand(); $cmd.CommandText = $Text; $cmd.CommandTimeout = 300; $null = $cmd.ExecuteNonQuery() }
            finally { $cn.Dispose() }
        }
        $deadline = (Get-Date).AddMinutes(3)
        while ($true) {
            try { & $exec 'SELECT 1'; break } catch { if ((Get-Date) -gt $deadline) { throw "SQL Server $server does not accept connections: $($_.Exception.Message)" }; Start-Sleep -Seconds 5 }
        }
        $id_ = { param($n) '[' + $n.Replace(']', ']]') + ']' }
        $lit = { param($n) "N'" + $n.Replace("'", "''") + "'" }
        foreach ($g in @($SysadminGroups)) {
            $login = "$NetBios\$g"
            & $exec ("IF SUSER_ID({0}) IS NULL CREATE LOGIN {1} FROM WINDOWS; ALTER SERVER ROLE [sysadmin] ADD MEMBER {1};" -f (& $lit $login), (& $id_ $login))
            $log.Add("sysadmin $login")
        }
        if ($Database) {
            & $exec ("IF DB_ID({0}) IS NULL CREATE DATABASE {1};" -f (& $lit $Database), (& $id_ $Database))
            $db = & $id_ $Database
            & $exec ("USE $db; IF OBJECT_ID(N'dbo.LabCheck') IS NULL CREATE TABLE dbo.LabCheck (Id int IDENTITY(1,1) PRIMARY KEY, Note nvarchar(100) NOT NULL, Created datetime2 NOT NULL DEFAULT SYSUTCDATETIME()); " +
                "IF NOT EXISTS (SELECT 1 FROM dbo.LabCheck WHERE Note = N'LAB-SQL-OK') INSERT dbo.LabCheck (Note) VALUES (N'LAB-SQL-OK');")
            foreach ($g in @($DbOwnerGroups)) {
                $login = "$NetBios\$g"
                & $exec ("IF SUSER_ID({0}) IS NULL CREATE LOGIN {1} FROM WINDOWS;" -f (& $lit $login), (& $id_ $login))
                & $exec ("USE $db; IF USER_ID({0}) IS NULL CREATE USER {1} FOR LOGIN {1}; ALTER ROLE [db_owner] ADD MEMBER {1};" -f (& $lit $login), (& $id_ $login))
                $log.Add("db_owner $login on $Database")
            }
            $log.Add("database $Database")
        }
        return ($log -join ', ')
    }
    $where = "$($d.Name)"; if ($instance -ine 'MSSQLSERVER') { $where = "$($d.Name)\$instance" }
    Write-LabLog "  [$($d.Name)] SQL Server $where ready on TCP $($sql.TcpPort): $summary" -Level OK
}
