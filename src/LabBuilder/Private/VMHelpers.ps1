# PowerShell Direct helpers (ADR 0007). All run on the Hyper-V host.

function New-LabCredential {
    param([Parameter(Mandatory)][string]$UserName, [Parameter(Mandatory)][pscredential]$PasswordFrom)
    return New-Object System.Management.Automation.PSCredential($UserName, $PasswordFrom.Password)
}

function Get-LabLocalCredential {
    # <Computer>\Administrator (server) or <Computer>\LabAdmin (Windows 11), lab admin password.
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][pscredential]$AdminCredential)
    $user = '{0}\{1}' -f $Definition.Name, (Get-LabLocalAdminName -Image $Definition.Image)
    return New-LabCredential -UserName $user -PasswordFrom $AdminCredential
}

function Get-LabDomainCredential {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][pscredential]$AdminCredential)
    return New-LabCredential -UserName ('{0}\Administrator' -f $Config.Domain.NetBiosName) -PasswordFrom $AdminCredential
}

function Wait-LabVMReady {
    <#
    Waits until PowerShell Direct accepts the credential (OOBE finished / reboot done). Returns the computer name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$TimeoutMinutes = 30
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastError = ''
    Write-LabLog "  waiting for $VMName (PowerShell Direct as $($Credential.UserName)) ..."
    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        if ($vm.State -eq 'Off') { Start-VM -Name $VMName | Out-Null }
        try {
            $name = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            if ($name) { Write-LabLog "  $VMName is ready ($name)."; return $name }
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds 15
    }
    throw "Timed out after $TimeoutMinutes min waiting for $VMName. Last error: $lastError"
}

function Invoke-LabVMCommand {
    <#
    Runs a script block in a VM over PowerShell Direct, with optional retries (script blocks must be idempotent).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$RetryCount = 0,
        [int]$RetryDelaySeconds = 30
    )
    for ($attempt = 0; ; $attempt++) {
        try {
            return Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
        } catch {
            if ($attempt -ge $RetryCount) { throw }
            Write-LabLog "  ${VMName}: attempt $($attempt + 1) failed ($($_.Exception.Message)); retrying in $RetryDelaySeconds s" -Level WARN
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

function Restart-LabVM {
    # Graceful shutdown through the integration service, start, wait for PowerShell Direct.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$TimeoutMinutes = 30
    )
    Write-LabLog "  restarting $VMName ..."
    Stop-VM -Name $VMName -Force -ErrorAction Stop
    Start-VM -Name $VMName -ErrorAction Stop
    Start-Sleep -Seconds 20
    Wait-LabVMReady -VMName $VMName -Credential $Credential -TimeoutMinutes $TimeoutMinutes | Out-Null
}

function Set-LabVMNetwork {
    # Static IPv4 + DNS on the single lab adapter; enables ICMP echo for diagnostics. Idempotent.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][int]$PrefixLength,
        [Parameter(Mandatory)][string[]]$DnsServers
    )
    Write-LabLog "  ${VMName}: IP $IPAddress/$PrefixLength, DNS $($DnsServers -join ',')"
    Invoke-LabVMCommand -VMName $VMName -Credential $Credential -RetryCount 3 -RetryDelaySeconds 15 -ArgumentList $IPAddress, $PrefixLength, $DnsServers -ScriptBlock {
        param($IP, $Len, $Dns)
        $ErrorActionPreference = 'Stop'
        $nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Sort-Object ifIndex | Select-Object -First 1
        if (-not $nic) { $nic = Get-NetAdapter | Sort-Object ifIndex | Select-Object -First 1 }
        if (-not $nic) { throw 'No network adapter found.' }
        $has = Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $IP
        if (-not $has) {
            Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled
            Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Get-NetRoute -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object DestinationPrefix -eq '0.0.0.0/0' | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $IP -PrefixLength $Len | Out-Null
        }
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $Dns
        if ($nic.Name -ne 'Lab') { Rename-NetAdapter -Name $nic.Name -NewName 'Lab' -ErrorAction SilentlyContinue }
        Get-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In*', 'CoreNet-Diag-ICMP4-EchoRequest-In*' -ErrorAction SilentlyContinue | Enable-NetFirewallRule -ErrorAction SilentlyContinue
    } | Out-Null
}

function Join-LabVMDomain {
    # Joins the VM to the domain in the given OU and restarts it. Skips when already joined.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$LocalCredential,
        [Parameter(Mandatory)][pscredential]$DomainCredential,
        [Parameter(Mandatory)][string]$DomainFqdn,
        [Parameter(Mandatory)][string]$OuPath,
        [int]$TimeoutMinutes = 30
    )
    $state = Invoke-LabVMCommand -VMName $VMName -Credential $LocalCredential -RetryCount 10 -RetryDelaySeconds 30 -ArgumentList $DomainFqdn, $DomainCredential, $OuPath -ScriptBlock {
        param($Domain, $Cred, $Ou)
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        if ($cs.PartOfDomain -and $cs.Domain -ieq $Domain) { return 'AlreadyJoined' }
        Add-Computer -DomainName $Domain -Credential $Cred -OUPath $Ou -Force -ErrorAction Stop -WarningAction SilentlyContinue
        return 'Joined'
    }
    if ($state -eq 'Joined') {
        Write-LabLog "  ${VMName}: joined $DomainFqdn ($OuPath)"
        Restart-LabVM -VMName $VMName -Credential $LocalCredential -TimeoutMinutes $TimeoutMinutes
    } else {
        Write-LabLog "  ${VMName}: already a member of $DomainFqdn"
    }
}

function Remove-LabVMUnattend {
    # Deletes the answer file (it contains the encoded admin password) - NFR-3.
    param([Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][pscredential]$Credential)
    Invoke-LabVMCommand -VMName $VMName -Credential $Credential -ScriptBlock {
        foreach ($p in @("$env:windir\Panther\unattend.xml", "$env:windir\Panther\Unattend\unattend.xml", "$env:windir\System32\Sysprep\unattend.xml")) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
        }
    } | Out-Null
}

function Get-LabOuPath {
    # Distinguished name of OU=<sub>,OU=<OuRoot>,DC=...
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$SubOu)
    return 'OU={0},OU={1},{2}' -f $SubOu, $Config.Domain.OuRoot, (Get-LabDomainDN -Fqdn $Config.Domain.Fqdn)
}
