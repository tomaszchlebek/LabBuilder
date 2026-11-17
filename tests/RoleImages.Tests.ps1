# Pester 3.4 tests for release 1.4.1: role-ready base images for domain controllers (AD DS + DNS enabled offline, no sysprep, no AD CS)
# and the choice of base image per VM (ADR 0016). The offline DISM step needs Hyper-V + elevation (host test). Run: Invoke-Pester .\tests

$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\LabBuilder\LabBuilder.psd1') -Force
$example = Join-Path $repo 'config\lab.config.example.psd1'
$m = Get-Module LabBuilder
$featureSet = & $m { $script:LabRoleImageFeatureSet }

function Get-ValidConfig {
    Import-LabConfig -Path $example -Overrides @{ 'Domain.Fqdn' = 'lab.test'; 'Domain.NetBiosName' = 'LABTEST' }
}
function Set-Side { param($Path, $Json) Set-Content -LiteralPath $Path -Value $Json -Encoding ASCII }

Describe 'Role image content' {
    It 'never contains AD CS (DC promotion refuses "Certificate Server is installed" - host test 2026-11-17)' {
        $patterns = & $m { $script:LabRoleImageFeaturePatterns }
        @($patterns | Where-Object { 'CertificateServices' -match $_ -or 'ADCertificateServicesRole' -match $_ -or 'CertificateServicesManagementTools' -match $_ }).Count | Should Be 0
        @($patterns | Where-Object { 'DirectoryServices-DomainController' -match $_ }).Count | Should Be 1
        @($patterns | Where-Object { 'DNS-Server-Full-Role' -match $_ }).Count | Should Be 1
        $featureSet | Should Be 'ADDS-DNS/2'
    }
}

Describe 'Which VMs use role-ready images' {
    It 'needs a role image only for the OS of the domain controllers (not for CA member servers)' {
        $c = Get-ValidConfig
        $c.MemberServers[0] | Add-Member -NotePropertyName Image -NotePropertyValue 'Server2019' -Force
        $c.MemberServers[0].Roles = @('IIS', 'ADCS')
        (@(Get-LabRoleImageKey -Config $c)) -join ',' | Should Be 'Server2025'
        $c.Build.RoleImages = $false
        @(Get-LabRoleImageKey -Config $c).Count | Should Be 0
        Test-LabRoleImagesEnabled -Config $c | Should Be $false
    }
    It 'creates DCs from <OS>-Roles only when a CURRENT role image exists; everything else from the plain base' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("ri-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $dir 'BaseImages') -Force | Out-Null
        try {
            $c = Get-ValidConfig; $c.Paths.LibraryRoot = $dir
            $c.MemberServers[0].Roles = @('ADCS')
            $defs = @(Get-LabVmDefinition -Config $c)
            $dc = $defs | Where-Object Name -eq 'DC01'; $ca = $defs | Where-Object Name -eq 'IIS01'; $ws = $defs | Where-Object Name -eq 'WS01'
            Get-LabVmBaseImageKey -Config $c -Definition $dc | Should Be 'Server2025'           # no role image -> plain (fallback)
            $role = Join-Path $dir 'BaseImages\Server2025-Roles.vhdx'
            Set-Content -LiteralPath $role -Value 'x'
            Set-Side "$role.json" '{ "FeatureSet": "" }'                                       # 1.4.1 test image (with AD CS)
            Get-LabVmBaseImageKey -Config $c -Definition $dc | Should Be 'Server2025'           # outdated -> not used
            Set-Side "$role.json" ('{ "FeatureSet": "' + $featureSet + '" }')
            Get-LabVmBaseImageKey -Config $c -Definition $dc | Should Be 'Server2025-Roles'
            Get-LabVmBaseImageKey -Config $c -Definition $ca | Should Be 'Server2025'           # CA member server: plain base
            Get-LabVmBaseImageKey -Config $c -Definition $ws | Should Be 'Win11LTSC'
            $c.Build.RoleImages = $false
            Get-LabVmBaseImageKey -Config $c -Definition $dc | Should Be 'Server2025'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

Describe 'Building a role image (decision paths without Hyper-V)' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("rb-{0}" -f [guid]::NewGuid())
    It 'skips with a warning when the plain base is missing' {
        New-Item -ItemType Directory -Path (Join-Path $dir 'BaseImages') -Force | Out-Null
        $c = Get-ValidConfig; $c.Paths.LibraryRoot = $dir
        New-LabRoleBaseImageItem -Config $c -Key 'Server2025' 6>$null 3>$null
        Test-Path -LiteralPath (Join-Path $dir 'BaseImages\Server2025-Roles.vhdx') | Should Be $false
    }
    It 'keeps a role image made from the current plain base with the current feature set' {
        $c = Get-ValidConfig; $c.Paths.LibraryRoot = $dir
        Set-Content -LiteralPath (Join-Path $dir 'BaseImages\Server2025.vhdx') -Value 'plain'
        Set-Side (Join-Path $dir 'BaseImages\Server2025.vhdx.json') '{ "CreatedUtc": "2026-11-15T10:00:00Z", "IsoSha256": "AAA", "Version": "10.0.26100.1", "Language": "en-US" }'
        Set-Content -LiteralPath (Join-Path $dir 'BaseImages\Server2025-Roles.vhdx') -Value 'role'
        Set-Side (Join-Path $dir 'BaseImages\Server2025-Roles.vhdx.json') ('{ "ParentCreatedUtc": "2026-11-15T10:00:00Z", "FeatureSet": "' + $featureSet + '" }')
        New-LabRoleBaseImageItem -Config $c -Key 'Server2025' 6>$null 3>$null
        Get-Content -LiteralPath (Join-Path $dir 'BaseImages\Server2025-Roles.vhdx') | Should Be 'role'
    }
    It 'treats a role image with the old feature set (AD CS) as outdated; a failed rebuild leaves nothing behind (fallback)' {
        $c = Get-ValidConfig; $c.Paths.LibraryRoot = $dir
        Set-Side (Join-Path $dir 'BaseImages\Server2025-Roles.vhdx.json') '{ "ParentCreatedUtc": "2026-11-15T10:00:00Z" }'
        # Without Hyper-V/elevation (or with a fake disk) Mount-VHD fails -> warning, no role image, no temp file.
        New-LabRoleBaseImageItem -Config $c -Key 'Server2025' 6>$null 3>$null
        Test-Path -LiteralPath (Join-Path $dir 'BaseImages\Server2025-Roles.vhdx') | Should Be $false
        Test-Path -LiteralPath (Join-Path $dir 'BaseImages\Server2025-Roles.building.vhdx') | Should Be $false
        Test-Path -LiteralPath (Join-Path $dir 'BaseImages\Server2025.vhdx') | Should Be $true
        $dcDef = @(Get-LabVmDefinition -Config $c -Role DomainController)[0]
        Get-LabVmBaseImageKey -Config $c -Definition $dcDef | Should Be 'Server2025'
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}

Describe 'Library view lists role images' {
    It 'shows <OS>-Roles as current only with the current base and feature set' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("rl-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $dir 'BaseImages'), (Join-Path $dir 'ISO') -Force | Out-Null
        try {
            $c = Get-ValidConfig
            Set-Content -LiteralPath (Join-Path $dir 'BaseImages\Server2022.vhdx') -Value 'p'
            Set-Side (Join-Path $dir 'BaseImages\Server2022.vhdx.json') '{ "CreatedUtc": "T1", "Version": "10.0.20348.587" }'
            Set-Content -LiteralPath (Join-Path $dir 'BaseImages\Server2022-Roles.vhdx') -Value 'r'
            Set-Side (Join-Path $dir 'BaseImages\Server2022-Roles.vhdx.json') ('{ "ParentCreatedUtc": "T1", "Version": "10.0.20348.587", "CreatedUtc": "T2", "FeatureSet": "' + $featureSet + '" }')
            $inv = Get-LabLibraryInventory -LibraryRoot $dir -Catalog $c.Iso.Images -NoUsers
            $r = $inv.Images | Where-Object Key -eq 'Server2022-Roles'
            $r | Should Not BeNullOrEmpty
            $r.BaseCurrent | Should Be $true
            Set-Side (Join-Path $dir 'BaseImages\Server2022-Roles.vhdx.json') '{ "ParentCreatedUtc": "T1", "CreatedUtc": "T2" }'
            (Get-LabLibraryInventory -LibraryRoot $dir -Catalog $c.Iso.Images -NoUsers).Images | Where-Object Key -eq 'Server2022-Roles' | ForEach-Object BaseCurrent | Should Be $false
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}
