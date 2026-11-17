$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\src\LabBuilder\LabBuilder.psd1') -Force

Describe 'AVMA activation of Windows Server VMs (ADR 0017)' {
    $m = Get-Module LabBuilder

    It 'has an AVMA entry for every server OS in the catalog and none for clients' {
        $c = Import-LabConfig -Path (Join-Path $here '..\config\lab.config.example.psd1')
        foreach ($p in $c.Iso.Images.PSObject.Properties) {
            $e = & $m { param($K) Get-LabAvmaEntry -Key $K } $p.Name
            if ($p.Value.Kind -eq 'Server') {
                $e | Should Not BeNullOrEmpty
                $e.Edition | Should Be 'ServerStandard'
                $e.AvmaKey | Should Match '^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$'
            } else { $e | Should BeNullOrEmpty }
        }
    }
    It 'maps role images to their OS' {
        (& $m { Get-LabAvmaEntry -Key 'Server2022-Roles' }).Build | Should Be 20348
    }
    It 'uses the KMS client key to convert 2019 (DISM rejects its AVMA key offline - host test)' {
        $e = & $m { Get-LabAvmaEntry -Key 'Server2019' }
        $e.ConvertKey | Should Not Be $e.AvmaKey
    }
    It 'needs an activated Datacenter host that is not older than the guest' {
        $v = { param($Cap, $St, $H, $G) & $m { param($Cap, $St, $H, $G) Get-LabAvmaHostVerdict -Caption $Cap -LicenseStatus $St -HostBuild $H -GuestBuild $G } $Cap $St $H $G }
        (& $v 'Microsoft Windows Server 2025 Datacenter' 1 26100 20348).Supported | Should Be $true
        (& $v 'Microsoft Windows Server 2025 Datacenter' 1 26100 26100).Supported | Should Be $true
        (& $v 'Microsoft Windows Server 2025 Standard' 1 26100 26100).Reason | Should Match 'Datacenter'
        (& $v 'Microsoft Windows Server 2022 Datacenter' 1 20348 26100).Reason | Should Match 'older than the guest'
        (& $v 'Microsoft Windows Server 2025 Datacenter' 5 26100 26100).Reason | Should Match 'not activated'
        (& $v 'Microsoft Windows 11 Pro' 1 26100 26100).Supported | Should Be $false
    }
    It 'is on by default and can be switched off with Build.Avma' {
        $c = Import-LabConfig -Path (Join-Path $here '..\config\lab.config.example.psd1')
        (& $m { param($C) Test-LabAvmaEnabled -Config $C } $c) | Should Be $true
        $c.Build | Add-Member -NotePropertyName Avma -NotePropertyValue $false -Force
        (& $m { param($C) Test-LabAvmaEnabled -Config $C } $c) | Should Be $false
    }
    It 'reports AVMA-activated VMs as licensed (AVMA)' {
        $r = & $m { Get-LabLicenceVerdict -LicenseStatus 1 -GraceMinutes 10080 -Description 'Windows(R) Operating System, VIRTUAL_MACHINE_ACTIVATION channel' -HasWlms $false -Now (Get-Date) }
        $r.Passed | Should Be $true
        $r.Detail | Should Be 'licensed (AVMA, renewed by the host)'
    }
    It 'activates every server VM after its network setup (root DC, additional DCs, member servers)' {
        $src = Get-Content (Join-Path $here '..\src\LabBuilder\Public\Roles.ps1') -Raw
        ([regex]::Matches($src, 'Enable-LabVMActivation -Config \$Config -Definition \$(root|dc|s) ')).Count | Should Be 3
        $hs = Get-Content (Join-Path $here '..\src\LabBuilder\Public\HostSetup.ps1') -Raw
        $hs | Should Match 'New-LabBaseImageItem -Config \$A.Config -Key \$Item\s+#[^\n]*\n[^\n]*\n\s+Update-LabBaseImageEdition'
    }
    It 'converts the base before the role images are built (role images copy the base)' {
        $hs = Get-Content (Join-Path $here '..\src\LabBuilder\Public\HostSetup.ps1') -Raw
        $hs.IndexOf('Update-LabBaseImageEdition') | Should BeLessThan $hs.IndexOf('New-LabRoleBaseImageItem')
    }
    It 'leaves a converted base alone and skips client OSes' {
        Mock -ModuleName LabBuilder Get-LabAvmaHostSupport { throw 'must not be called' }
        $dir = Join-Path $env:TEMP ('avma-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $dir 'BaseImages') -Force | Out-Null
        try {
            $c = Import-LabConfig -Path (Join-Path $here '..\config\lab.config.example.psd1')
            $c.Paths | Add-Member -NotePropertyName LibraryRoot -NotePropertyValue $dir -Force
            $vhd = & $m { param($C) Get-LabBaseImagePath -Config $C -Image 'Server2025' } $c
            Set-Content -LiteralPath $vhd -Value 'x'
            '{"Image":"Server2025","Edition":"ServerStandard"}' | Set-Content -LiteralPath "$vhd.json"
            { & $m { param($C) Update-LabBaseImageEdition -Config $C -Key 'Server2025' } $c } | Should Not Throw
            { & $m { param($C) Update-LabBaseImageEdition -Config $C -Key 'Win11LTSC' } $c } | Should Not Throw
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}
