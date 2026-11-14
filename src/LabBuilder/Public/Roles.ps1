# Server and workstation deployment (FR-6..FR-11, ADR 0009). All run on the Hyper-V host.

function Get-LabDcIPs {
    param([Parameter(Mandatory)]$Config)
    return [string[]]@(Get-LabVmDefinition -Config $Config -Role DomainController | Sort-Object Index | ForEach-Object IPAddress)
}

function Get-LabCAName {
    param([Parameter(Mandatory)]$Config)
    $n = [string]$Config.Domain.CACommonName
    if (-not $n) { $n = '{0}-ROOT-CA' -f ([string]$Config.Domain.NetBiosName).ToUpperInvariant() }
    return $n
}

function Grant-LabCertificateTemplateEnroll {
    <#
    .SYNOPSIS
        Gives one computer account the Enroll right on a certificate template (run on the forest root DC),
        then restarts the CA service so the new permission is used at once. Idempotent.
    .DESCRIPTION
        The built-in WebServer template allows enrolment only for Domain Admins and Enterprise Admins. A server that
        requests a certificate into Cert:\LocalMachine\My enrols as its computer account (e.g. IIS01$), which is
        denied with CERTSRV_E_TEMPLATE_DENIED (0x80094012) unless that account has Enroll on the template.
        Only the named computer is granted (least privilege), not Domain Computers.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][pscredential]$AdminCredential,
        [Parameter(Mandatory)][string]$TemplateName,
        [Parameter(Mandatory)][string]$ComputerName
    )
    $cred = Get-LabDomainCredential -Config $Config -AdminCredential $AdminCredential
    $rootDc = @(Get-LabVmDefinition -Config $Config -Role DomainController | Sort-Object Index)[0]
    Write-LabLog "  [$ComputerName] granting Enroll on template '$TemplateName' to $ComputerName`$ ..." -Level STEP
    $r = Invoke-LabVMCommand -VMName $rootDc.VMName -Credential $cred -RetryCount 3 -RetryDelaySeconds 20 -ArgumentList $TemplateName, $ComputerName -ScriptBlock {
        param($Template, $Computer)
        $ErrorActionPreference = 'Stop'
        Import-Module ActiveDirectory
        $configNc = (Get-ADRootDSE).configurationNamingContext
        $dn = "CN=$Template,CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNc"
        # Templates live in the configuration partition; a -Filter search would only look in the domain partition.
        $tpl = $null
        try { $tpl = Get-ADObject -Identity $dn } catch { $tpl = $null }
        if (-not $tpl) { throw "Certificate template '$Template' not found at '$dn' (is the Enterprise CA installed?)." }
        $sid = (Get-ADComputer -Identity $Computer).SID
        $enroll = [guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55'   # Certificate-Enrollment extended right
        $path = "AD:\$dn"
        $acl = Get-Acl -Path $path
        $existing = @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | Where-Object {
                $_.IdentityReference -eq $sid -and $_.ObjectType -eq $enroll -and $_.AccessControlType -eq 'Allow' })
        if ($existing.Count -gt 0) { return 'exists' }
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid,
            [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight, [System.Security.AccessControl.AccessControlType]::Allow, $enroll)
        $acl.AddAccessRule($rule)
        Set-Acl -Path $path -AclObject $acl
        return 'granted'
    }
    Write-LabLog "  [$ComputerName] Enroll on '$TemplateName': $r." -Level OK

    if ($r -eq 'granted') {
        foreach ($ca in @(Get-LabRoleServer -Config $Config -RoleName 'ADCS')) {
            Write-LabLog "  [$($ca.Name)] restarting CertSvc to apply the template permission ..." -Level INFO
            Invoke-LabVMCommand -VMName $ca.VMName -Credential $cred -RetryCount 2 -ScriptBlock {
                $ErrorActionPreference = 'Stop'
                Restart-Service -Name CertSvc -Force
                $deadline = (Get-Date).AddMinutes(2)
                while ((Get-Service -Name CertSvc).Status -ne 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
                Start-Sleep -Seconds 5
            } | Out-Null
        }
    }
}

function Install-LabDomainController {
    <#
    .SYNOPSIS
        Phase DomainControllers: forest root DC (new forest + DNS), OUs/groups/accounts, additional DCs,
        DNS client order, then the catalog roles of each DC.
    .PARAMETER AccountsJson
        JSON array from New-LabAccountPlan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][pscredential]$AdminCredential,
        [Parameter(Mandatory)][string]$AccountsJson
    )

    $dcs = @(Get-LabVmDefinition -Config $Config -Role DomainController | Sort-Object Index)
    $root = $dcs[0]
    $fqdn = [string]$Config.Domain.Fqdn
    $nb = ([string]$Config.Domain.NetBiosName).ToUpperInvariant()
    $domainCred = Get-LabDomainCredential -Config $Config -AdminCredential $AdminCredential
    $timeout = [int]$Config.Timeouts.VmReadyMinutes

    # Create all DC VMs first so their OOBE runs while the forest is built.
    foreach ($dc in $dcs) { New-LabVM -Config $Config -Definition $dc -AdminCredential $AdminCredential }

    # --- Forest root DC ---
    $vm = $root.VMName
    $local = Get-LabLocalCredential -Definition $root -AdminCredential $AdminCredential
    if (-not (Test-LabIsDomainController -VMName $vm -DomainCredential $domainCred)) {
        Wait-LabVMReady -VMName $vm -Credential $local -TimeoutMinutes $timeout | Out-Null
        Set-LabVMNetwork -VMName $vm -Credential $local -IPAddress $root.IPAddress -PrefixLength $Config.Network.PrefixLength -DnsServers @($root.IPAddress)

        Write-LabLog "Promoting $($root.Name) to the first DC of new forest $fqdn ($nb) - 5 to 15 minutes ..." -Level STEP
        $res = Invoke-LabVMCommand -VMName $vm -Credential $local -ArgumentList $fqdn, $nb, $Config.Domain.DomainMode, $Config.Domain.ForestMode, $AdminCredential -ScriptBlock {
            param($Fqdn, $NetBios, $DomainMode, $ForestMode, $Cred)
            $ErrorActionPreference = 'Stop'
            Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
            Import-Module ADDSDeployment
            $r = Install-ADDSForest -DomainName $Fqdn -DomainNetbiosName $NetBios -DomainMode $DomainMode -ForestMode $ForestMode `
                -InstallDns -SafeModeAdministratorPassword $Cred.Password -NoRebootOnCompletion -Force -WarningAction SilentlyContinue
            [pscustomobject]@{ Status = [string]$r.Status; Message = [string]$r.Message }
        }
        if ($res.Status -ne 'Success') { throw "Install-ADDSForest failed: $($res.Status) $($res.Message)" }
        Write-LabLog '  forest created; restarting (first boot as DC takes a while) ...'
        Restart-LabVM -VMName $vm -Credential $domainCred -TimeoutMinutes $timeout
    } else {
        Write-LabLog "$($root.Name) is already a domain controller." -Level OK
    }
    Wait-LabADReady -Config $Config -VMName $vm -DomainCredential $domainCred
    Remove-LabVMUnattend -VMName $vm -Credential $domainCred

    # --- Directory content ---
    Write-LabLog 'Creating OUs, security groups, domain admin accounts and test users ...' -Level STEP
    $groupsJson = ConvertTo-Json -InputObject @($Config.Groups) -Depth 5 -Compress
    $summary = Invoke-LabVMCommand -VMName $vm -Credential $domainCred -RetryCount 2 -ArgumentList ([string]$Config.Domain.OuRoot), $groupsJson, $AccountsJson -ScriptBlock {
        param($OuRoot, $GroupsJson, $AccountsJson)
        $ErrorActionPreference = 'Stop'
        Import-Module ActiveDirectory
        $domain = Get-ADDomain
        $domainDn = $domain.DistinguishedName
        $rootDn = "OU=$OuRoot,$domainDn"
        $log = New-Object System.Collections.Generic.List[string]

        if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$rootDn'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $OuRoot -Path $domainDn -ProtectedFromAccidentalDeletion $false
            $log.Add("OU $rootDn")
        }
        foreach ($sub in @('Admins', 'Users', 'Groups', 'Servers', 'Workstations')) {
            $dn = "OU=$sub,$rootDn"
            if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue)) {
                New-ADOrganizationalUnit -Name $sub -Path $rootDn -ProtectedFromAccidentalDeletion $false
                $log.Add("OU $dn")
            }
        }

        foreach ($g in ($GroupsJson | ConvertFrom-Json)) {
            if (-not (Get-ADGroup -Filter "SamAccountName -eq '$($g.Name)'" -ErrorAction SilentlyContinue)) {
                New-ADGroup -Name $g.Name -SamAccountName $g.Name -GroupScope Global -GroupCategory Security `
                    -Path "OU=Groups,$rootDn" -Description $g.Description
                $log.Add("group $($g.Name)")
            }
        }

        $domainAdmins = Get-ADGroup -Identity ('{0}-512' -f $domain.DomainSID.Value)   # well-known RID, any language
        foreach ($a in ($AccountsJson | ConvertFrom-Json)) {
            $isAdmin = ([string]$a.Type -eq 'DomainAdmin')
            $ou = "OU=Users,$rootDn"; $desc = 'LabBuilder test user'
            if ($isAdmin) { $ou = "OU=Admins,$rootDn"; $desc = 'LabBuilder dedicated domain admin' }
            if (-not (Get-ADUser -Filter "SamAccountName -eq '$($a.SamAccountName)'" -ErrorAction SilentlyContinue)) {
                New-ADUser -Name $a.DisplayName -SamAccountName $a.SamAccountName -UserPrincipalName $a.UserPrincipalName `
                    -GivenName $a.GivenName -Surname $a.Surname -DisplayName $a.DisplayName -Path $ou `
                    -AccountPassword (ConvertTo-SecureString -String $a.Password -AsPlainText -Force) `
                    -Enabled $true -PasswordNeverExpires $true -ChangePasswordAtLogon $false -Description $desc
                $log.Add("user $($a.SamAccountName) ($($a.Type))")
            }
            foreach ($gn in @(([string]$a.Groups) -split ';' | Where-Object { $_ })) {
                $group = $null
                if ($gn -eq 'Domain Admins') { $group = $domainAdmins } else { $group = Get-ADGroup -Identity $gn }
                $members = @(Get-ADGroupMember -Identity $group | Select-Object -ExpandProperty SamAccountName)
                if ($members -notcontains $a.SamAccountName) {
                    Add-ADGroupMember -Identity $group -Members $a.SamAccountName
                    $log.Add("member $($a.SamAccountName) -> $($group.Name)")
                }
            }
        }
        return $log.ToArray()
    }
    foreach ($line in @($summary)) { if ($line) { Write-LabLog "  + $line" } }
    Write-LabLog 'Directory content ready.' -Level OK

    # --- Additional DCs ---
    foreach ($dc in @($dcs | Select-Object -Skip 1)) {
        $local = Get-LabLocalCredential -Definition $dc -AdminCredential $AdminCredential
        if (Test-LabIsDomainController -VMName $dc.VMName -DomainCredential $domainCred) {
            Write-LabLog "$($dc.Name) is already a domain controller." -Level OK
            continue
        }
        Wait-LabVMReady -VMName $dc.VMName -Credential $local -TimeoutMinutes $timeout | Out-Null
        Set-LabVMNetwork -VMName $dc.VMName -Credential $local -IPAddress $dc.IPAddress -PrefixLength $Config.Network.PrefixLength -DnsServers @($root.IPAddress)
        Write-LabLog "Promoting $($dc.Name) to an additional domain controller (DNS, GC) ..." -Level STEP
        $res = Invoke-LabVMCommand -VMName $dc.VMName -Credential $local -RetryCount 3 -RetryDelaySeconds 60 -ArgumentList $fqdn, $domainCred, $AdminCredential -ScriptBlock {
            param($Fqdn, $DomainCred, $Dsrm)
            $ErrorActionPreference = 'Stop'
            Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
            Import-Module ADDSDeployment
            $r = Install-ADDSDomainController -DomainName $Fqdn -Credential $DomainCred -InstallDns -SafeModeAdministratorPassword $Dsrm.Password `
                -NoRebootOnCompletion -Force -WarningAction SilentlyContinue
            [pscustomobject]@{ Status = [string]$r.Status; Message = [string]$r.Message }
        }
        if ($res.Status -ne 'Success') { throw "Install-ADDSDomainController on $($dc.Name) failed: $($res.Status) $($res.Message)" }
        Restart-LabVM -VMName $dc.VMName -Credential $domainCred -TimeoutMinutes $timeout
        Wait-LabADReady -Config $Config -VMName $dc.VMName -DomainCredential $domainCred
        Remove-LabVMUnattend -VMName $dc.VMName -Credential $domainCred
        Write-LabLog "$($dc.Name) is a domain controller." -Level OK
    }

    # --- DNS client order on every DC: itself first, then the other DCs ---
    if ($dcs.Count -gt 1) {
        foreach ($dc in $dcs) {
            $order = [string[]](@($dc.IPAddress) + @($dcs | Where-Object { $_.Name -ne $dc.Name } | ForEach-Object IPAddress))
            Set-LabVMNetwork -VMName $dc.VMName -Credential $domainCred -IPAddress $dc.IPAddress -PrefixLength $Config.Network.PrefixLength -DnsServers $order
        }
    }

    # --- Catalog roles on DCs (CA first) ---
    foreach ($dc in ($dcs | Sort-Object { if ($_.Roles -contains 'ADCS') { 0 } else { 1 } }, Index)) {
        Install-LabServerRole -Config $Config -Definition $dc -AdminCredential $AdminCredential
    }
}

function Install-LabMemberServer {
    <#
    .SYNOPSIS
        Phase MemberServers: domain-joined member servers with their catalog roles (FR-9); the CA server first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][pscredential]$AdminCredential
    )

    $servers = @(Get-LabVmDefinition -Config $Config -Role MemberServer | Sort-Object { if ($_.Roles -contains 'ADCS') { 0 } else { 1 } }, Index)
    if ($servers.Count -eq 0) { Write-LabLog 'No member servers configured.' -Level OK; return }
    Assert-LabDomainControllerRunning -Config $Config

    $fqdn = [string]$Config.Domain.Fqdn
    $domainCred = Get-LabDomainCredential -Config $Config -AdminCredential $AdminCredential
    $timeout = [int]$Config.Timeouts.VmReadyMinutes
    $dns = Get-LabDcIPs -Config $Config

    foreach ($s in $servers) { New-LabVM -Config $Config -Definition $s -AdminCredential $AdminCredential }
    foreach ($s in $servers) {
        Write-LabLog "Configuring member server $($s.Name) (roles: $(@($s.Roles + $s.AdditionalFeatures) -join ', ')) ..." -Level STEP
        $local = Get-LabLocalCredential -Definition $s -AdminCredential $AdminCredential
        Wait-LabVMReady -VMName $s.VMName -Credential $local -TimeoutMinutes $timeout | Out-Null
        Set-LabVMNetwork -VMName $s.VMName -Credential $local -IPAddress $s.IPAddress -PrefixLength $Config.Network.PrefixLength -DnsServers $dns
        Join-LabVMDomain -VMName $s.VMName -LocalCredential $local -DomainCredential $domainCred -DomainFqdn $fqdn `
            -OuPath (Get-LabOuPath -Config $Config -SubOu $s.OuName) -TimeoutMinutes $timeout
        Remove-LabVMUnattend -VMName $s.VMName -Credential $local
        Install-LabServerRole -Config $Config -Definition $s -AdminCredential $AdminCredential
        Write-LabLog "Member server $($s.Name) ready ($($s.IPAddress))." -Level OK
    }
}

function Install-LabServerRole {
    <#
    .SYNOPSIS
        Installs the catalog roles (ADCS, DHCP, FileServer, IIS - in that order) and AdditionalFeatures on one server.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][pscredential]$AdminCredential
    )
    $d = $Definition
    $cred = Get-LabDomainCredential -Config $Config -AdminCredential $AdminCredential
    $fqdn = [string]$Config.Domain.Fqdn
    $nb = ([string]$Config.Domain.NetBiosName).ToUpperInvariant()

    if ($d.Roles -contains 'ADCS') {
        $caName = Get-LabCAName -Config $Config
        Write-LabLog "  [$($d.Name)] AD CS Enterprise Root CA '$caName' ..." -Level STEP
        $r = Invoke-LabVMCommand -VMName $d.VMName -Credential $cred -RetryCount 2 -ArgumentList $caName, ([int]$Config.Domain.CAValidityYears) -ScriptBlock {
            param($CAName, $Years)
            $ErrorActionPreference = 'Stop'
            $active = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -ErrorAction SilentlyContinue).Active
            if ($active) { return "exists: $active" }
            Install-WindowsFeature -Name ADCS-Cert-Authority -IncludeManagementTools | Out-Null
            Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -CACommonName $CAName `
                -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' -KeyLength 4096 -HashAlgorithmName SHA256 `
                -ValidityPeriod Years -ValidityPeriodUnits $Years -Force -WarningAction SilentlyContinue | Out-Null
            Start-Service -Name CertSvc
            return "installed: $CAName"
        }
        Write-LabLog "  [$($d.Name)] CA $r" -Level OK
    }

    if ($d.Roles -contains 'DHCP') {
        $prefix = [string]$Config.Network.Prefix
        $start = '{0}.{1}' -f $prefix, $Config.Roles.DHCP.RangeStartOctet
        $end = '{0}.{1}' -f $prefix, $Config.Roles.DHCP.RangeEndOctet
        Write-LabLog "  [$($d.Name)] DHCP Server, scope $start - $end ..." -Level STEP
        Invoke-LabVMCommand -VMName $d.VMName -Credential $cred -RetryCount 2 -ArgumentList "$($d.Name).$fqdn", $d.IPAddress, "$prefix.0", $start, $end, ([string[]](Get-LabDcIPs -Config $Config)), $fqdn -ScriptBlock {
            param($DnsName, $IP, $ScopeId, $Start, $End, $Dns, $Fqdn)
            $ErrorActionPreference = 'Stop'
            $f = Install-WindowsFeature -Name DHCP -IncludeManagementTools
            if (-not $f.Success) { throw 'DHCP feature install failed.' }
            if (-not (Get-DhcpServerInDC | Where-Object { $_.IPAddress -eq $IP })) { Add-DhcpServerInDC -DnsName $DnsName -IPAddress $IP }
            & netsh.exe dhcp add securitygroups | Out-Null
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState -Value 2 -ErrorAction SilentlyContinue
            Restart-Service -Name DHCPServer
            if (-not (Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue)) {
                Add-DhcpServerv4Scope -Name 'Lab' -StartRange $Start -EndRange $End -SubnetMask 255.255.255.0 -State Active
            }
            Set-DhcpServerv4OptionValue -ScopeId $ScopeId -DnsServer $Dns -DnsDomain $Fqdn -Force
        } | Out-Null
        Write-LabLog "  [$($d.Name)] DHCP authorised and scope active." -Level OK
    }

    if ($d.Roles -contains 'FileServer') {
        $share = [string]$Config.Roles.FileServer.ShareName
        $firstGroup = [string](@($Config.Groups)[0].Name)
        Write-LabLog "  [$($d.Name)] File Server, share \\$($d.Name)\$share ..." -Level STEP
        Invoke-LabVMCommand -VMName $d.VMName -Credential $cred -RetryCount 2 -ArgumentList $share, ([string]$Config.Roles.FileServer.Path), $nb, $firstGroup -ScriptBlock {
            param($Share, $Path, $NetBios, $Group)
            $ErrorActionPreference = 'Stop'
            $f = Install-WindowsFeature -Name FS-FileServer -IncludeManagementTools
            if (-not $f.Success) { throw 'FS-FileServer install failed.' }
            if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
            $groupAccount = "$NetBios\$Group"
            $domainSid = (New-Object System.Security.Principal.NTAccount($groupAccount)).Translate([System.Security.Principal.SecurityIdentifier]).AccountDomainSid
            $admins = (New-Object System.Security.Principal.SecurityIdentifier("$($domainSid.Value)-512")).Translate([System.Security.Principal.NTAccount]).Value
            & icacls.exe $Path /grant "${groupAccount}:(OI)(CI)M" "${admins}:(OI)(CI)F" | Out-Null
            if (-not (Get-SmbShare -Name $Share -ErrorAction SilentlyContinue)) {
                New-SmbShare -Name $Share -Path $Path -ChangeAccess $groupAccount -FullAccess $admins -Description 'LabBuilder test share' | Out-Null
            }
            Set-Content -LiteralPath (Join-Path $Path 'lab-share-ok.txt') -Value 'LAB-SHARE-OK' -Encoding ASCII
        } | Out-Null
        Write-LabLog "  [$($d.Name)] share \\$($d.Name)\$share ready." -Level OK
    }

    if ($d.Roles -contains 'IIS') {
        Write-LabLog "  [$($d.Name)] IIS: $(@($Config.Roles.IIS.Features) -join ', ')" -Level STEP
        Invoke-LabVMCommand -VMName $d.VMName -Credential $cred -RetryCount 1 -ArgumentList ([string[]]@($Config.Roles.IIS.Features)), $d.Name, $fqdn -ScriptBlock {
            param($Features, $Name, $Fqdn)
            $ErrorActionPreference = 'Stop'
            $r = Install-WindowsFeature -Name $Features -IncludeManagementTools
            if (-not $r.Success) { throw "Install-WindowsFeature failed: $($r.ExitCode)" }
            $page = "<!DOCTYPE html><html><head><title>Lab IIS</title></head><body><h1>LAB-IIS-OK</h1><p>$Name.$Fqdn</p></body></html>"
            Set-Content -LiteralPath 'C:\inetpub\wwwroot\lab-health.html' -Value $page -Encoding ASCII
        } | Out-Null
        Write-LabLog "  [$($d.Name)] IIS installed; health page /lab-health.html." -Level OK

        if ($Config.Roles.IIS.EnableHttps) {
            Grant-LabCertificateTemplateEnroll -Config $Config -AdminCredential $AdminCredential `
                -TemplateName ([string]$Config.Roles.IIS.CertificateTemplate) -ComputerName $d.Name
            Write-LabLog "  [$($d.Name)] requesting '$($Config.Roles.IIS.CertificateTemplate)' certificate from the lab CA, binding HTTPS ..." -Level STEP
            $thumb = Invoke-LabVMCommand -VMName $d.VMName -Credential $cred -RetryCount 5 -RetryDelaySeconds 30 -ArgumentList "$($d.Name).$fqdn", $d.Name, ([string]$Config.Roles.IIS.CertificateTemplate) -ScriptBlock {
                param($HostFqdn, $Short, $Template)
                $ErrorActionPreference = 'Stop'
                Import-Module WebAdministration
                $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=$HostFqdn" -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
                    Sort-Object NotAfter -Descending | Select-Object -First 1
                if (-not $cert) {
                    & gpupdate.exe /target:computer /force | Out-Null
                    & certutil.exe -pulse | Out-Null
                    $req = Get-Certificate -Template $Template -SubjectName "CN=$HostFqdn" -DnsName $HostFqdn, $Short -CertStoreLocation Cert:\LocalMachine\My
                    if ($req.Status -ne 'Issued') { throw "Certificate request status: $($req.Status)" }
                    $cert = $req.Certificate
                }
                if (-not (Get-WebBinding -Name 'Default Web Site' -Protocol https -Port 443)) {
                    New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443 -IPAddress '*'
                }
                if (Test-Path 'IIS:\SslBindings\0.0.0.0!443') { Remove-Item 'IIS:\SslBindings\0.0.0.0!443' -Force }
                (Get-WebBinding -Name 'Default Web Site' -Protocol https -Port 443).AddSslCertificate($cert.Thumbprint, 'My')
                return $cert.Thumbprint
            }
            Write-LabLog "  [$($d.Name)] HTTPS bound with certificate $thumb." -Level OK
        }
    }

    if (@($d.AdditionalFeatures).Count -gt 0) {
        Write-LabLog "  [$($d.Name)] additional features: $($d.AdditionalFeatures -join ', ')" -Level STEP
        Invoke-LabVMCommand -VMName $d.VMName -Credential $cred -RetryCount 1 -ArgumentList (, [string[]]$d.AdditionalFeatures) -ScriptBlock {
            param($Features)
            $ErrorActionPreference = 'Stop'
            $r = Install-WindowsFeature -Name $Features -IncludeManagementTools
            if (-not $r.Success) { throw "Install-WindowsFeature failed: $($r.ExitCode)" }
            if ($r.RestartNeeded -eq 'Yes') { return 'restart' }
        } | Out-Null
        Write-LabLog "  [$($d.Name)] additional features installed." -Level OK
    }
}

function Install-LabWorkstation {
    <#
    .SYNOPSIS
        Phase Workstations: creates all Windows 11 VMs, then joins each to the domain (FR-11).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][pscredential]$AdminCredential
    )

    $defs = @(Get-LabVmDefinition -Config $Config -Role Workstation)
    if ($defs.Count -eq 0) { Write-LabLog 'No workstations configured.' -Level OK; return }
    Assert-LabDomainControllerRunning -Config $Config

    $fqdn = [string]$Config.Domain.Fqdn
    $nb = [string]$Config.Domain.NetBiosName
    $domainCred = Get-LabDomainCredential -Config $Config -AdminCredential $AdminCredential
    $timeout = [int]$Config.Timeouts.VmReadyMinutes
    $dns = Get-LabDcIPs -Config $Config
    $adminGroups = @()
    if ($Config.Accounts.TestUsersAreLocalAdmins) { $adminGroups = @([string](@($Config.Groups)[0].Name)) }

    # Create and start all first so their OOBE runs in parallel.
    foreach ($def in $defs) { New-LabVM -Config $Config -Definition $def -AdminCredential $AdminCredential }

    foreach ($def in $defs) {
        Write-LabLog "Configuring workstation $($def.Name) ..." -Level STEP
        $local = Get-LabLocalCredential -Definition $def -AdminCredential $AdminCredential
        Wait-LabVMReady -VMName $def.VMName -Credential $local -TimeoutMinutes $timeout | Out-Null
        Set-LabVMNetwork -VMName $def.VMName -Credential $local -IPAddress $def.IPAddress -PrefixLength $Config.Network.PrefixLength -DnsServers $dns
        Join-LabVMDomain -VMName $def.VMName -LocalCredential $local -DomainCredential $domainCred -DomainFqdn $fqdn `
            -OuPath (Get-LabOuPath -Config $Config -SubOu $def.OuName) -TimeoutMinutes $timeout
        Remove-LabVMUnattend -VMName $def.VMName -Credential $local

        Invoke-LabVMCommand -VMName $def.VMName -Credential $local -ArgumentList $nb, ([string[]]$adminGroups) -ScriptBlock {
            param($NetBios, $Groups)
            foreach ($g in @($Groups | Where-Object { $_ })) {
                $member = "$NetBios\$g"
                $current = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue | ForEach-Object Name)
                if ($current -notcontains $member) { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $member -ErrorAction Stop }
            }
            & gpupdate.exe /target:computer /force | Out-Null
        } | Out-Null
        if ($adminGroups.Count -gt 0) { Write-LabLog "  $($def.Name): $nb\$($adminGroups[0]) added to local Administrators." }
        Write-LabLog "Workstation $($def.Name) ready ($($def.IPAddress))." -Level OK
    }
}

function Test-LabIsDomainController {
    param([Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][pscredential]$DomainCredential)
    try {
        $role = Invoke-Command -VMName $VMName -Credential $DomainCredential -ScriptBlock { (Get-CimInstance Win32_ComputerSystem).DomainRole } -ErrorAction Stop
        return ([int]$role -ge 4)
    } catch { return $false }
}

function Wait-LabADReady {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][pscredential]$DomainCredential)
    Write-LabLog "  waiting for Active Directory on $VMName ..."
    $fqdn = [string]$Config.Domain.Fqdn
    $deadline = (Get-Date).AddMinutes([int]$Config.Timeouts.AdReadyMinutes)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-Command -VMName $VMName -Credential $DomainCredential -ErrorAction Stop -ScriptBlock {
                Import-Module ActiveDirectory
                (Get-ADDomain -Server $env:COMPUTERNAME).DNSRoot
            }
            if ($r -ieq $fqdn) { Write-LabLog "  Active Directory answers on $VMName." -Level OK; return }
        } catch { }
        Start-Sleep -Seconds 20
    }
    throw "Active Directory on $VMName did not become ready in $($Config.Timeouts.AdReadyMinutes) min."
}

function Assert-LabDomainControllerRunning {
    param([Parameter(Mandatory)]$Config)
    $root = Get-LabVmDefinition -Config $Config -Role DomainController | Sort-Object Index | Select-Object -First 1
    $vm = Get-VM -Name $root.VMName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -ne 'Running') { throw "Domain controller $($root.VMName) is not running - run phase DomainControllers first." }
}
