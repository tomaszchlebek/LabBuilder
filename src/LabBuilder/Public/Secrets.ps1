# Password and account-plan generation (ADR 0006, ADR 0009).

$script:PwUpper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'   # no I, O
$script:PwLower   = 'abcdefghijkmnopqrstuvwxyz'  # no l
$script:PwDigits  = '23456789'                   # no 0, 1
$script:PwSymbols = '!#%+-=?@'

# Marker in the account plan's Groups column; resolved on the DC by well-known RID 512 (language independent).
$script:DomainAdminsMarker = 'Domain Admins'

function Get-LabRandomIndex {
    param([Parameter(Mandatory)][int]$MaxExclusive, [Parameter(Mandatory)]$Rng)
    $bytes = New-Object byte[] 4
    $Rng.GetBytes($bytes)
    return [int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]$MaxExclusive)
}

function New-LabPassword {
    <#
    .SYNOPSIS
        Generates a random password (crypto RNG) with upper, lower, digit and symbol characters, no look-alikes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateRange(12, 128)][int]$Length = 20)

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $all = $script:PwUpper + $script:PwLower + $script:PwDigits + $script:PwSymbols
        $chars = New-Object System.Collections.Generic.List[char]
        foreach ($set in @($script:PwUpper, $script:PwLower, $script:PwDigits, $script:PwSymbols)) {
            $chars.Add($set[(Get-LabRandomIndex -MaxExclusive $set.Length -Rng $rng)])
        }
        while ($chars.Count -lt $Length) {
            $chars.Add($all[(Get-LabRandomIndex -MaxExclusive $all.Length -Rng $rng)])
        }
        # Fisher-Yates shuffle so the category characters are not always first.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = Get-LabRandomIndex -MaxExclusive ($i + 1) -Rng $rng
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        return (-join $chars.ToArray())
    }
    finally {
        $rng.Dispose()
    }
}

function Test-LabPasswordComplexity {
    <#
    .SYNOPSIS
        True when the password meets the AD default complexity rule (>= 8 chars, 3 of 4 categories).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Password)

    if ($Password.Length -lt 8) { return $false }
    $categories = 0
    if ($Password -cmatch '[A-Z]') { $categories++ }
    if ($Password -cmatch '[a-z]') { $categories++ }
    if ($Password -match '[0-9]') { $categories++ }
    if ($Password -match '[^A-Za-z0-9]') { $categories++ }
    return ($categories -ge 3)
}

function New-LabAccountPlan {
    <#
    .SYNOPSIS
        Creates the random dedicated domain admins and domain test users (FR-8) and their group memberships.
    .DESCRIPTION
        Type DomainAdmin: SamAccountName adm.<first>.<last>, member of Domain Admins (OU=Admins).
        Type TestUser: <first>.<last>, member of the first group; every other group gets at least one random
        test user, and each test user joins each other group with a 50% chance (OU=Users).
        Groups are a ';'-separated string so the plan round-trips through CSV.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(0, 100)][int]$TestUserCount = 3,
        [ValidateRange(0, 10)][int]$DomainAdminCount = 0,
        [Parameter(Mandatory)][string[]]$GroupNames,
        [Parameter(Mandatory)][string]$UpnSuffix,
        [ValidateRange(12, 128)][int]$PasswordLength = 16
    )

    $first = @('Alex', 'Maria', 'John', 'Anna', 'Peter', 'Kate', 'Tom', 'Julia', 'Mark', 'Eva',
               'Adam', 'Nina', 'Paul', 'Laura', 'Simon', 'Olga', 'David', 'Sara', 'Chris', 'Helen')
    $last  = @('Novak', 'Smith', 'Kowalski', 'Brown', 'Fischer', 'Garcia', 'Wilson', 'Nowak', 'Taylor', 'Martin',
               'Weber', 'Lopez', 'Clark', 'Walker', 'Young', 'Hall', 'Wright', 'King', 'Scott', 'Green')

    $usedPeople = @{}
    $newPerson = {
        for ($try = 0; $try -lt 5000; $try++) {
            $g = $first | Get-Random
            $s = $last | Get-Random
            if (-not $usedPeople.ContainsKey("$g $s")) { $usedPeople["$g $s"] = $true; return @($g, $s) }
        }
        throw 'Ran out of unique random names.'
    }
    $makeAccount = {
        param($Type, $Prefix)
        $p = & $newPerson
        $sam = ('{0}{1}.{2}' -f $Prefix, $p[0], $p[1]).ToLowerInvariant()
        if ($sam.Length -gt 20) { $sam = $sam.Substring(0, 20) }
        $display = '{0} {1}' -f $p[0], $p[1]
        if ($Type -eq 'DomainAdmin') { $display = "$display (Admin)" }
        [pscustomobject]@{
            Type              = $Type
            SamAccountName    = $sam
            GivenName         = $p[0]
            Surname           = $p[1]
            DisplayName       = $display
            UserPrincipalName = "$sam@$UpnSuffix"
            Password          = (New-LabPassword -Length $PasswordLength)
            Groups            = ''
        }
    }

    $admins = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $DomainAdminCount; $i++) {
        $a = & $makeAccount 'DomainAdmin' 'adm.'
        $a.Groups = $script:DomainAdminsMarker
        $admins.Add($a)
    }

    $users = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $TestUserCount; $i++) { $users.Add((& $makeAccount 'TestUser' '')) }

    if ($users.Count -gt 0) {
        $membership = @{}
        foreach ($u in $users) { $membership[$u.SamAccountName] = New-Object System.Collections.Generic.List[string] }
        for ($gi = 0; $gi -lt $GroupNames.Count; $gi++) {
            $group = $GroupNames[$gi]
            if ($gi -eq 0) {
                foreach ($u in $users) { $membership[$u.SamAccountName].Add($group) }
                continue
            }
            $guaranteed = ($users | Get-Random).SamAccountName
            foreach ($u in $users) {
                if ($u.SamAccountName -eq $guaranteed -or (Get-Random -Maximum 2) -eq 1) {
                    $membership[$u.SamAccountName].Add($group)
                }
            }
        }
        foreach ($u in $users) { $u.Groups = ($membership[$u.SamAccountName] -join ';') }
    }

    return @($admins.ToArray() + $users.ToArray())
}

function Protect-LabFile {
    <#
    .SYNOPSIS
        Restricts a secrets file to the current user and SYSTEM (removes inherited ACEs) - ADR 0006.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $out = & icacls.exe $Path /inheritance:r /grant:r "*${sid}:(F)" '*S-1-5-18:(F)' 2>&1
    if ($LASTEXITCODE -ne 0) { Write-LabLog "Could not restrict ACL of ${Path}: $out" -Level WARN }
}

function ConvertTo-UnattendPassword {
    <#
    .SYNOPSIS
        Encodes a password the way Windows Setup expects in unattend.xml (PlainText=false).
    .PARAMETER Kind
        'AdministratorPassword' for UserAccounts/AdministratorPassword, 'Password' for LocalAccount/Password.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Password,
        [ValidateSet('AdministratorPassword', 'Password')][string]$Kind = 'AdministratorPassword'
    )
    return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Password + $Kind))
}
