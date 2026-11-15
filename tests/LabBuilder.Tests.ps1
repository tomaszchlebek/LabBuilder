# Pester 3.4+ tests (inbox Pester syntax: Should Be). Run: Invoke-Pester .\tests
# Cover the logic that runs without Hyper-V: config v2, validation rules, topology, secrets, account plan,
# locale resolution, unattend rendering, URL allow-list, validation check blocks.

$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\LabBuilder\LabBuilder.psd1') -Force
$example = Join-Path $repo 'config\lab.config.example.psd1'

function Get-ValidConfig {
    Import-LabConfig -Path $example -Overrides @{ 'Domain.Fqdn' = 'lab.test'; 'Domain.NetBiosName' = 'LABTEST' }
}
function Get-Errors { param($Config, $Scope = 'Full') (@(Test-LabConfig -Config $Config -Scope $Scope) -join ' | ') }

Describe 'Import-LabConfig' {
    It 'loads the example config (schema v2) and applies overrides' {
        $c = Get-ValidConfig
        $c.SchemaVersion | Should Be 2
        $c.Domain.Fqdn | Should Be 'lab.test'
        $c.Domain.NetBiosName | Should Be 'LABTEST'
    }
    It 'keeps size literals as bytes' {
        $c = Get-ValidConfig
        [int64]$c.DomainControllers[0].MemoryBytes | Should Be 4GB
        [int64]$c.DomainControllers[0].DiskSizeBytes | Should Be 80GB
        [int64]$c.BaseDiskSizeBytes | Should Be 32GB
    }
    It 'keeps single-element arrays as arrays' {
        $c = Get-ValidConfig
        @($c.DomainControllers).Count | Should Be 1
        @($c.DomainControllers[0].Roles) -contains 'ADCS' | Should Be $true
        @($c.MemberServers[0].Roles).Count | Should Be 1
    }
    It 'uses Windows 11 Enterprise LTSC' {
        (Get-ValidConfig).Iso.Images.Win11LTSC.ImageNamePattern | Should Be 'Windows 11 Enterprise LTSC*'
    }
}

Describe 'BaseConfig layering (wizard configs)' {
    It 'merges a small config over the example and keeps base values it does not set' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("cfg-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            Copy-Item -LiteralPath $example -Destination (Join-Path $dir 'lab.config.example.psd1')
            $text = @"
@{
    BaseConfig = 'lab.config.example.psd1'
    LabName = 'QA'
    Domain = @{ Fqdn = 'qa.test'; NetBiosName = 'QA' }
    Network = @{ SwitchType = 'Internal' }
    DomainControllers = @(
        @{ Name = 'DC01'; HostOctet = 10; ProcessorCount = 2; MemoryBytes = 4GB; DiskSizeBytes = 60GB; Roles = @('ADCS'); AdditionalFeatures = @() }
        @{ Name = 'DC02'; HostOctet = 11; ProcessorCount = 2; MemoryBytes = 4GB; DiskSizeBytes = 60GB; Roles = @(); AdditionalFeatures = @() }
    )
    MemberServers = @()
    Workstations = @{ Count = 2 }
    Roles = @{ IIS = @{ EnableHttps = `$false } }
}
"@
            $f = Join-Path $dir 'lab.config.psd1'
            Set-Content -LiteralPath $f -Value $text -Encoding ASCII
            $c = Import-LabConfig -Path $f
            $c.LabName | Should Be 'QA'
            $c.Network.SwitchType | Should Be 'Internal'
            $c.Network.SwitchName | Should Be 'LAB-Isolated'
            @($c.DomainControllers).Count | Should Be 2
            @($c.MemberServers).Count | Should Be 0
            $c.Workstations.Count | Should Be 2
            $c.Workstations.NamePrefix | Should Be 'WS'
            @($c.Roles.IIS.Features).Count | Should Be 4
            $c.Iso.Images.Win11LTSC.Url | Should Match 'linkid=2289029'
            ($c.PSObject.Properties.Name -contains 'BaseConfig') | Should Be $false
            Get-Errors $c | Should Be ''
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

Describe 'Get-LabVmDefinition' {
    $defs = @(Get-LabVmDefinition -Config (Get-ValidConfig))
    It 'returns 1 DC, 1 member server and 1 workstation by default' {
        $defs.Count | Should Be 3
        @($defs | Where-Object Role -eq 'DomainController').Count | Should Be 1
        @($defs | Where-Object Role -eq 'MemberServer').Count | Should Be 1
        @($defs | Where-Object Role -eq 'Workstation').Count | Should Be 1
    }
    It 'builds names, VM names, IPs and sizes' {
        $dc = $defs | Where-Object Role -eq 'DomainController'
        $dc.VMName | Should Be 'TESTLAB-DC01'
        $dc.IPAddress | Should Be '10.10.10.10'
        ($defs | Where-Object Name -eq 'WS01').IPAddress | Should Be '10.10.10.101'
        ($defs | Where-Object Name -eq 'WS01').DiskSizeBytes | Should Be 80GB
        ($defs | Where-Object Name -eq 'WS01').Image | Should Be 'Win11LTSC'
    }
    It 'generates the requested number of workstations' {
        $c = Get-ValidConfig
        $c.Workstations.Count = 7
        $c.Workstations.NamePrefix = 'PC'
        $ws = @(Get-LabVmDefinition -Config $c -Role Workstation)
        $ws.Count | Should Be 7
        $ws[6].Name | Should Be 'PC07'
        $ws[6].IPAddress | Should Be '10.10.10.107'
    }
    It 'places member servers and workstations in OUs, DCs not' {
        ($defs | Where-Object Role -eq 'MemberServer').OuName | Should Be 'Servers'
        ($defs | Where-Object Name -eq 'WS01').OuName | Should Be 'Workstations'
        ($defs | Where-Object Role -eq 'DomainController').OuName | Should Be $null
    }
    It 'finds role servers' {
        (Get-LabRoleServer -Config (Get-ValidConfig) -RoleName 'IIS').Name | Should Be 'IIS01'
        (Get-LabRoleServer -Config (Get-ValidConfig) -RoleName 'ADCS').Name | Should Be 'DC01'
    }
}

Describe 'Test-LabConfig' {
    It 'accepts the example config with domain inputs' { Get-Errors (Get-ValidConfig) | Should Be '' }
    It 'accepts the example for ISO-only and teardown use without domain inputs' {
        Get-Errors (Import-LabConfig -Path $example) 'Iso' | Should Be ''
        Get-Errors (Import-LabConfig -Path $example) 'Host' | Should Be ''
    }
    It 'rejects a single-label or .local FQDN' {
        Get-Errors (Import-LabConfig -Path $example -Overrides @{ 'Domain.Fqdn' = 'lab'; 'Domain.NetBiosName' = 'LAB' }) | Should Match 'FQDN'
        Get-Errors (Import-LabConfig -Path $example -Overrides @{ 'Domain.Fqdn' = 'corp.local'; 'Domain.NetBiosName' = 'CORP' }) | Should Match '\.local'
    }
    It 'rejects a bad NetBIOS name' {
        Get-Errors (Import-LabConfig -Path $example -Overrides @{ 'Domain.Fqdn' = 'lab.test'; 'Domain.NetBiosName' = 'ABCDEFGHIJKLMNOP' }) | Should Match 'NetBIOS'
        Get-Errors (Import-LabConfig -Path $example -Overrides @{ 'Domain.Fqdn' = 'lab.test'; 'Domain.NetBiosName' = 'DC01' }) | Should Match 'differ'
    }
    It 'rejects a config without SchemaVersion 2' {
        $c = Get-ValidConfig; $c.SchemaVersion = 1
        Get-Errors $c | Should Match 'SchemaVersion'
    }
    It 'requires 1-5 domain controllers and limits workstations' {
        $c = Get-ValidConfig; $c.DomainControllers = @()
        Get-Errors $c | Should Match 'domain controllers must be 1-5'
        $c = Get-ValidConfig; $c.Workstations.Count = 21
        Get-Errors $c | Should Match 'workstations must be 0-20'
    }
    It 'accepts 0 workstations and 0 member servers (without IIS)' {
        $c = Get-ValidConfig; $c.Workstations.Count = 0; $c.MemberServers = @()
        Get-Errors $c | Should Be ''
    }
    It 'checks sizes' {
        $c = Get-ValidConfig; $c.Workstations.DiskSizeBytes = 50GB
        Get-Errors $c | Should Match 'disk must be 64-2048 GB'
        $c = Get-ValidConfig; $c.Workstations.MemoryBytes = 2GB
        Get-Errors $c | Should Match '4 GB RAM'
        $c = Get-ValidConfig; $c.DomainControllers[0].DiskSizeBytes = 30GB
        Get-Errors $c | Should Match 'disk must be 40-2048 GB'
    }
    It 'rejects duplicate IPs, including generated workstation IPs' {
        $c = Get-ValidConfig; $c.MemberServers[0].HostOctet = 101   # clashes with WS01 (default 1 workstation from .101)
        Get-Errors $c | Should Match 'Duplicate IP address 10.10.10.101'
    }
    It 'rejects unknown roles, a second CA and a second DHCP server' {
        $c = Get-ValidConfig; $c.MemberServers[0].Roles = @('IIS', 'Exchange')
        Get-Errors $c | Should Match "unknown role 'Exchange'"
        $c = Get-ValidConfig; $c.MemberServers[0].Roles = @('IIS', 'ADCS')
        Get-Errors $c | Should Match 'ADCS .* one server only'
        $c = Get-ValidConfig; $c.MemberServers[0].Roles = @('DHCP'); $c.DomainControllers[0].Roles = @('ADCS', 'DHCP')
        Get-Errors $c | Should Match 'DHCP may be on one server only'
    }
    It 'rejects IIS HTTPS without a CA' {
        $c = Get-ValidConfig; $c.DomainControllers[0].Roles = @()
        Get-Errors $c | Should Match 'HTTPS needs a certificate authority'
        $c.Roles.IIS.EnableHttps = $false
        Get-Errors $c | Should Be ''
    }
    It 'rejects static IPs inside the DHCP range' {
        $c = Get-ValidConfig; $c.MemberServers[0].Roles = @('DHCP'); $c.Workstations.FirstHostOctet = 210
        Get-Errors $c | Should Match 'inside the DHCP range'
    }
    It 'checks account counts' {
        $c = Get-ValidConfig; $c.Accounts.DomainAdminCount = 11
        Get-Errors $c | Should Match 'domain admin accounts must be 0-10'
        $c = Get-ValidConfig; $c.Accounts.TestUserCount = 101
        Get-Errors $c | Should Match 'test users must be 0-100'
    }
    It 'rejects a non-https ISO URL' {
        $c = Get-ValidConfig; $c.Iso.Images.Server2025.Url = 'http://example.com/x.iso'
        Get-Errors $c 'Iso' | Should Match 'https'
    }
    It 'rejects invalid additional feature names' {
        $c = Get-ValidConfig; $c.MemberServers[0].AdditionalFeatures = @('RSAT-AD-Tools', 'bad name;')
        Get-Errors $c | Should Match "feature 'bad name;'"
    }
}

Describe 'Get-LabDomainDN' {
    It 'converts an FQDN' { Get-LabDomainDN -Fqdn 'corp.lab.test' | Should Be 'DC=corp,DC=lab,DC=test' }
}

Describe 'New-LabPassword' {
    It 'has the requested length and meets complexity, 50 samples' {
        for ($i = 0; $i -lt 50; $i++) {
            $p = New-LabPassword -Length 16
            $p.Length | Should Be 16
            Test-LabPasswordComplexity -Password $p | Should Be $true
            $p -cmatch '[A-Z]' | Should Be $true
            $p -cmatch '[a-z]' | Should Be $true
            $p -match '[0-9]' | Should Be $true
            $p -match '[^A-Za-z0-9]' | Should Be $true
        }
    }
    It 'avoids look-alike characters' {
        $all = -join (1..40 | ForEach-Object { New-LabPassword -Length 64 })
        $all -cmatch '[O0Il1]' | Should Be $false
    }
    It 'produces different passwords' { (New-LabPassword) -eq (New-LabPassword) | Should Be $false }
}

Describe 'Test-LabPasswordComplexity' {
    It 'rejects short and simple passwords' {
        Test-LabPasswordComplexity -Password 'Ab1!' | Should Be $false
        Test-LabPasswordComplexity -Password 'alllowercase' | Should Be $false
    }
    It 'accepts 3 of 4 categories' { Test-LabPasswordComplexity -Password 'Password123' | Should Be $true }
}

Describe 'New-LabAccountPlan' {
    $groups = @('SG-Lab-Testers', 'SG-Lab-WebAdmins', 'SG-Lab-Finance', 'SG-Lab-HR')
    $plan = @(New-LabAccountPlan -TestUserCount 5 -DomainAdminCount 2 -GroupNames $groups -UpnSuffix 'lab.test' -PasswordLength 16)
    $admins = @($plan | Where-Object Type -eq 'DomainAdmin')
    $users = @($plan | Where-Object Type -eq 'TestUser')
    It 'creates the requested admins and users with unique names' {
        $admins.Count | Should Be 2
        $users.Count | Should Be 5
        @($plan | Select-Object -ExpandProperty SamAccountName -Unique).Count | Should Be 7
    }
    It 'names admins adm.* and puts them in Domain Admins only' {
        foreach ($a in $admins) {
            $a.SamAccountName | Should Match '^adm\.'
            $a.SamAccountName.Length -le 20 | Should Be $true
            $a.Groups | Should Be 'Domain Admins'
        }
    }
    It 'uses the UPN suffix and complex passwords' {
        foreach ($u in $plan) {
            $u.UserPrincipalName | Should Be "$($u.SamAccountName)@lab.test"
            Test-LabPasswordComplexity -Password $u.Password | Should Be $true
        }
    }
    It 'puts every test user in the first group and gives every group a member' {
        foreach ($u in $users) { ($u.Groups -split ';') -contains 'SG-Lab-Testers' | Should Be $true }
        foreach ($g in $groups) { @($users | Where-Object { ($_.Groups -split ';') -contains $g }).Count -ge 1 | Should Be $true }
    }
    It 'supports zero test users or zero admins' {
        @(New-LabAccountPlan -TestUserCount 0 -DomainAdminCount 1 -GroupNames $groups -UpnSuffix 'lab.test').Count | Should Be 1
        @(New-LabAccountPlan -TestUserCount 0 -DomainAdminCount 0 -GroupNames $groups -UpnSuffix 'lab.test').Count | Should Be 0
    }
    It 'round-trips through CSV' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("plan-{0}.csv" -f [guid]::NewGuid())
        try {
            $plan | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8
            $back = @(Import-Csv -LiteralPath $tmp)
            $back.Count | Should Be 7
            $back[0].Type | Should Be $plan[0].Type
            $back[0].Password | Should Be $plan[0].Password
        } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    }
}

Describe 'Resolve-LabLocale' {
    It 'takes empty values from the host and UI language from the image' {
        $l = Resolve-LabLocale -Config (Get-ValidConfig) -ImageLanguage 'en-US'
        $l.TimeZone | Should Be ([TimeZoneInfo]::Local.Id)
        $l.UserLocale | Should Be ((Get-Culture).Name)
        $l.UILanguage | Should Be 'en-US'
        [string]::IsNullOrEmpty($l.InputLocale) | Should Be $false
        [string]::IsNullOrEmpty($l.SystemLocale) | Should Be $false
    }
    It 'keeps explicit config values' {
        $c = Get-ValidConfig
        $c.Locale.TimeZone = 'UTC'; $c.Locale.UILanguage = 'de-DE'; $c.Locale.InputLocale = '0407:00000407'
        $l = Resolve-LabLocale -Config $c -ImageLanguage 'en-US'
        $l.TimeZone | Should Be 'UTC'
        $l.UILanguage | Should Be 'de-DE'
        $l.InputLocale | Should Be '0407:00000407'
    }
}

Describe 'ConvertTo-UnattendPassword' {
    It 'encodes in unattend format' {
        $enc = ConvertTo-UnattendPassword -Password 'P@ss' -Kind AdministratorPassword
        [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($enc)) | Should Be 'P@ssAdministratorPassword'
        $enc2 = ConvertTo-UnattendPassword -Password 'P@ss' -Kind Password
        [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($enc2)) | Should Be 'P@ssPassword'
    }
}

Describe 'New-LabUnattendXml' {
    $loc = Resolve-LabLocale -Config (Get-ValidConfig) -ImageLanguage 'en-US'
    $pw = 'S3cret<&>"Pw!'
    $cred = New-Object System.Management.Automation.PSCredential('Administrator', (ConvertTo-SecureString $pw -AsPlainText -Force))
    $ns = @{ u = 'urn:schemas-microsoft-com:unattend' }

    It 'renders a well-formed server answer file with host time zone and no plaintext password' {
        $xml = New-LabUnattendXml -Image Server -ComputerName 'DC01' -AdminCredential $cred -Locale $loc
        $doc = [xml]$xml
        (Select-Xml -Xml $doc -XPath '//u:ComputerName' -Namespace $ns).Node.InnerText | Should Be 'DC01'
        (Select-Xml -Xml $doc -XPath '//u:TimeZone' -Namespace $ns).Node.InnerText | Should Be ([TimeZoneInfo]::Local.Id)
        $xml.Contains($pw) | Should Be $false
        $val = (Select-Xml -Xml $doc -XPath '//u:AdministratorPassword/u:Value' -Namespace $ns).Node.InnerText
        [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($val)) | Should Be ($pw + 'AdministratorPassword')
        @(Select-Xml -Xml $doc -XPath '//u:LocalAccount' -Namespace $ns).Count | Should Be 0
    }
    It 'renders a client answer file with the LabAdmin local account' {
        $xml = New-LabUnattendXml -Image Client -ComputerName 'WS01' -AdminCredential $cred -Locale $loc
        $doc = [xml]$xml
        (Select-Xml -Xml $doc -XPath '//u:LocalAccount/u:Name' -Namespace $ns).Node.InnerText | Should Be 'LabAdmin'
        (Select-Xml -Xml $doc -XPath '//u:HideOnlineAccountScreens' -Namespace $ns).Node.InnerText | Should Be 'true'
        $val = (Select-Xml -Xml $doc -XPath '//u:LocalAccount/u:Password/u:Value' -Namespace $ns).Node.InnerText
        [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($val)) | Should Be ($pw + 'Password')
    }
}

Describe 'SQL Server role (FR-20)' {
    function Add-Sql { param($c) $c.MemberServers += @{ Name = 'SQL01'; HostOctet = 30; ProcessorCount = 2; MemoryBytes = 4GB; DiskSizeBytes = 80GB; Roles = @('SQL'); AdditionalFeatures = @() }; $c }
    It 'accepts the example SQL settings on a member server' {
        $c = Add-Sql (Get-ValidConfig)
        Get-Errors $c | Should Be ''
        Test-LabSqlRequired -Config $c | Should Be $true
        Test-LabSqlRequired -Config (Get-ValidConfig) | Should Be $false
    }
    It 'rejects SQL on a domain controller' {
        $c = Get-ValidConfig; $c.DomainControllers[0].Roles = @('ADCS', 'SQL')
        Get-Errors $c | Should Match 'not supported on domain controller DC01'
    }
    It 'checks instance, port, mode, groups, database and collation' {
        $c = Add-Sql (Get-ValidConfig); $c.Roles.SQL.InstanceName = '1BAD'; Get-Errors $c | Should Match 'InstanceName'
        $c = Add-Sql (Get-ValidConfig); $c.Roles.SQL.InstanceName = 'MSSQLSERVER'; Get-Errors $c | Should Be ''
        $c = Add-Sql (Get-ValidConfig); $c.Roles.SQL.TcpPort = 80; Get-Errors $c | Should Match 'TcpPort'
        $c = Add-Sql (Get-ValidConfig); $c.Roles.SQL.AuthenticationMode = 'SqlOnly'; Get-Errors $c | Should Match 'AuthenticationMode'
        $c = Add-Sql (Get-ValidConfig); $c.Roles.SQL.AuthenticationMode = 'Mixed'; Get-Errors $c | Should Be ''
        $c = Add-Sql (Get-ValidConfig); $c.Roles.SQL.SysadminGroups = @('SG-Nope'); Get-Errors $c | Should Match 'SysadminGroups lists .SG-Nope.'
        $c = Add-Sql (Get-ValidConfig); $c.Roles.SQL.DatabaseName = 'tempdb'; Get-Errors $c | Should Match 'system database'
        $c = Add-Sql (Get-ValidConfig); $c.Roles.SQL.DatabaseName = ''; Get-Errors $c | Should Be ''
        $c = Add-Sql (Get-ValidConfig); $c.Roles.SQL.Collation = 'bad collation'; Get-Errors $c | Should Match 'Collation'
    }
    It 'derives the service name from the instance' {
        Get-LabSqlServiceName -InstanceName 'SQLEXPRESS' | Should Be 'MSSQL$SQLEXPRESS'
        Get-LabSqlServiceName -InstanceName 'MSSQLSERVER' | Should Be 'MSSQLSERVER'
    }
    It 'accepts only Microsoft-signed media' {
        (Test-LabMicrosoftSignature -Path (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')).Valid | Should Be $true
        $fake = Join-Path $env:TEMP ('labbuilder-test-{0}.exe' -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $fake -Value 'not a real package' -Encoding ASCII
        try { (Test-LabMicrosoftSignature -Path $fake).Valid | Should Be $false } finally { Remove-Item -LiteralPath $fake -Force }
    }
}

Describe 'Validation check blocks' {
    It 'every in-VM check block compiles once the prologue is inserted after param()' {
        $file = Join-Path $repo 'src\LabBuilder\Public\Validation.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        $blocks = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -eq 'SingleQuotedHereString' }, $true))
        $blocks.Count | Should Be 9
        foreach ($b in $blocks) {
            $parts = $b.Value -split "`n", 2
            $parts[0] | Should Match '^param\('
            $sb = [scriptblock]::Create($parts[0] + "`n" + '$out = 1' + "`n" + $parts[1])
            $sb.Ast.ParamBlock | Should Not Be $null
        }
    }
}

InModuleScope LabBuilder {
    Describe 'Test-LabMicrosoftHost (download hop allow-list)' {
        It 'allows Microsoft hosts' {
            Test-LabMicrosoftHost -HostName 'go.microsoft.com' | Should Be $true
            Test-LabMicrosoftHost -HostName 'software-static.download.prss.microsoft.com' | Should Be $true
            Test-LabMicrosoftHost -HostName 'aka.ms' | Should Be $true
        }
        It 'refuses look-alike hosts' {
            Test-LabMicrosoftHost -HostName 'evilmicrosoft.com' | Should Be $false
            Test-LabMicrosoftHost -HostName 'microsoft.com.evil.example' | Should Be $false
            Test-LabMicrosoftHost -HostName 'aka.ms.evil.example' | Should Be $false
        }
    }

    Describe 'ISO manifest read/write' {
        It 'reads back a single-entry manifest as one entry' {
            $dir = Join-Path ([IO.Path]::GetTempPath()) ("man-{0}" -f [guid]::NewGuid())
            New-Item -ItemType Directory -Path $dir | Out-Null
            try {
                Write-LabIsoManifest -Folder $dir -Map @{ 'a.iso' = [pscustomobject]@{ FileName = 'a.iso'; Length = 5; Sha256 = 'AB' } }
                $m = Read-LabIsoManifest -Folder $dir
                $m.Count | Should Be 1
                $m['a.iso'].Sha256 | Should Be 'AB'
            } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
        }
    }

    Describe 'Required images' {
        It 'skips the client ISO when no workstations are configured' {
            $c = Import-LabConfig -Path (Join-Path (Split-Path -Parent (Split-Path -Parent (Get-Module LabBuilder).ModuleBase)) 'config\lab.config.example.psd1')
            $c.Workstations.Count = 0
            @(Get-LabRequiredImageKey -Config $c) -join ',' | Should Be 'Server2025'
        }
    }
}
