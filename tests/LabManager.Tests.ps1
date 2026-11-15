# Pester 3.4 tests for release 1.4.0: lab manager - host settings, lab and library inventory, per-lab output folder, config
# reconstruction, delete (ADR 0015). Run: Invoke-Pester .\tests

$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\LabBuilder\LabBuilder.psd1') -Force
$example = Join-Path $repo 'config\lab.config.example.psd1'

function Get-ValidConfig {
    Import-LabConfig -Path $example -Overrides @{ 'Domain.Fqdn' = 'lab.test'; 'Domain.NetBiosName' = 'LABTEST' }
}
function New-TempDir { $d = Join-Path ([IO.Path]::GetTempPath()) ("lm-{0}" -f [guid]::NewGuid()); New-Item -ItemType Directory -Path $d | Out-Null; $d }
function New-FakeLab {
    # A lab folder as LabBuilder leaves it: lab.json (+ optional config, output, VMs).
    param([string]$Root, [string]$Name, [string]$Domain = 'lab.test', [switch]$WithConfig)
    New-Item -ItemType Directory -Path (Join-Path $Root 'VMs'), (Join-Path $Root 'Logs'), (Join-Path $Root 'output') -Force | Out-Null
    $m = [ordered]@{ Format = 'LabBuilder.Lab/1'; LabName = $Name; Version = '1.3.0'; LabRoot = $Root; Domain = $Domain; DiskType = 'Differencing'
        Switch = [ordered]@{ Name = "LAB-$Name"; Type = 'Private'; Prefix = '10.10.30' }; LastPhase = 'Validate'
        VMs = @([ordered]@{ Name = 'DC01'; VMName = "$Name-DC01"; Role = 'DomainController'; Image = 'Server2025'; IPAddress = '10.10.30.10' },
                [ordered]@{ Name = 'WEB01'; VMName = "$Name-WEB01"; Role = 'MemberServer'; Image = 'Server2022'; IPAddress = '10.10.30.20' },
                [ordered]@{ Name = 'WS01'; VMName = "$Name-WS01"; Role = 'Workstation'; Image = 'Win11LTSC'; IPAddress = '10.10.30.101' },
                [ordered]@{ Name = 'WS02'; VMName = "$Name-WS02"; Role = 'Workstation'; Image = 'Win11LTSC'; IPAddress = '10.10.30.102' }) }
    ConvertTo-Json -InputObject $m -Depth 5 | Set-Content -LiteralPath (Join-Path $Root 'lab.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Root 'output\lab-accounts.csv') -Value 'Type,UserPrincipalName' -Encoding ASCII
    if ($WithConfig) { Set-Content -LiteralPath (Join-Path $Root 'lab.config.psd1') -Value '@{ LabName = ''X'' }' -Encoding ASCII }
}

Describe 'Host settings (settings.json)' {
    It 'returns first-run defaults when the file does not exist and round-trips what is saved' {
        $dir = New-TempDir
        try {
            $p = Join-Path $dir 'settings.json'
            $s = Get-LabHostSettings -Path $p
            $s.Exists | Should Be $false
            $s.AppFolder | Should Be 'C:\LabBuilder'
            $s.LabsFolder | Should Match '^[CD]:\\LabBuilder-Labs$'
            $s.LibraryFolder | Should Match '^[CD]:\\LabBuilder-Library$'
            $s.LabsFolder = 'E:\Labs'; $s.ExternalLabs = @([pscustomobject]@{ Name = 'OLD'; LabRoot = 'D:\HyperVLab'; ConfigPath = ''; OutputPath = 'C:\LabBuilder\output\OLD' })
            Set-LabHostSettings -Settings $s -Path $p
            $r = Get-LabHostSettings -Path $p
            $r.Exists | Should Be $true
            $r.LabsFolder | Should Be 'E:\Labs'
            @($r.ExternalLabs).Count | Should Be 1
            $r.ExternalLabs[0].LabRoot | Should Be 'D:\HyperVLab'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

Describe 'Per-lab output folder (Paths.OutputPath)' {
    It 'uses Paths.OutputPath, else the 1.0-1.3 location <App>\output\<Lab>, and validates it' {
        $c = Get-ValidConfig
        Get-LabOutputPath -Config $c -AppFolder 'C:\LabBuilder' | Should Be 'C:\LabBuilder\output\TESTLAB'
        $c.Paths.OutputPath = 'E:\Labs\TESTLAB\output\'
        Get-LabOutputPath -Config $c -AppFolder 'C:\LabBuilder' | Should Be 'E:\Labs\TESTLAB\output'
        (@(Test-LabConfig -Config $c) -join ' | ') | Should Be ''
        $c.Paths.OutputPath = 'output'
        (@(Test-LabConfig -Config $c) -join ' | ') | Should Match 'Paths.OutputPath'
    }
    It 'finds a lab-name conflict in the lab''s own output folder too' {
        $dir = New-TempDir
        try {
            New-Item -ItemType Directory -Path (Join-Path $dir 'out') | Out-Null
            [pscustomobject]@{ Type = 'TestUser'; UserPrincipalName = 'a.b@old.lab' } | Export-Csv -LiteralPath (Join-Path $dir 'out\lab-accounts.csv') -NoTypeInformation
            $c = Get-ValidConfig; $c.Paths.OutputPath = (Join-Path $dir 'out'); $c.Paths.LabRoot = (Join-Path $dir 'lab'); $c.Network.SwitchName = 'LAB-Pester-None'
            (@(Test-LabHostConflict -Config $c) -join ' | ') | Should Match "by a lab of domain 'old.lab'"
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

Describe 'Lab inventory (Get-LabInventory)' {
    It 'lists labs of the Labs folder and registered external labs, with config/output paths' {
        $dir = New-TempDir
        try {
            New-FakeLab -Root (Join-Path $dir 'Labs\NEWLAB') -Name 'NEWLAB' -WithConfig
            New-FakeLab -Root (Join-Path $dir 'HyperVLab') -Name 'OLDLAB' -Domain 'one.lab'
            New-Item -ItemType Directory -Path (Join-Path $dir 'Labs\empty') | Out-Null   # no lab.json - ignored
            $s = [pscustomobject]@{ Exists = $true; AppFolder = (Join-Path $dir 'App'); LabsFolder = (Join-Path $dir 'Labs'); LibraryFolder = (Join-Path $dir 'Lib')
                ExternalLabs = @([pscustomobject]@{ Name = 'OLDLAB'; LabRoot = (Join-Path $dir 'HyperVLab'); ConfigPath = ''; OutputPath = '' }) }
            $labs = @(Get-LabInventory -Settings $s)
            ($labs | ForEach-Object Name) -join ',' | Should Be 'NEWLAB,OLDLAB'
            $new = $labs | Where-Object Name -eq 'NEWLAB'
            $new.Source | Should Be 'Labs'
            $new.HasConfig | Should Be $true
            $new.OutputPath | Should Be (Join-Path $dir 'Labs\NEWLAB\output')
            @($new.VMs).Count | Should Be 4
            $new.DiskType | Should Be 'Differencing'
            ($new.SizeBytes -gt 0) | Should Be $true
            $old = $labs | Where-Object Name -eq 'OLDLAB'
            $old.Source | Should Be 'External'
            $old.Domain | Should Be 'one.lab'
            $old.HasConfig | Should Be $false
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
    It 'registers discovered labs once (Register-LabExternal)' {
        $s = [pscustomobject]@{ ExternalLabs = @() }
        $labs = @([pscustomobject]@{ Name = 'TESTLAB'; Source = 'Discovered'; LabRoot = 'D:\HyperVLab'; ConfigPath = 'D:\HyperVLab\lab.config.psd1'; OutputPath = 'C:\LabBuilder\output\TESTLAB' },
                  [pscustomobject]@{ Name = 'NEW'; Source = 'Labs'; LabRoot = 'D:\Labs\NEW'; ConfigPath = ''; OutputPath = '' })
        $s = Register-LabExternal -Settings $s -Labs $labs
        $s = Register-LabExternal -Settings $s -Labs $labs
        @($s.ExternalLabs).Count | Should Be 1
        $s.ExternalLabs[0].Name | Should Be 'TESTLAB'
    }
}

Describe 'Restoring a 1.0-1.3 lab config from the shared config and its backups (Restore-LabLegacyConfig)' {
    It 'picks the newest backup with the same lab name and folder and makes BaseConfig absolute' {
        $dir = New-TempDir
        try {
            $app = Join-Path $dir 'App'; New-Item -ItemType Directory -Path (Join-Path $app 'config') | Out-Null
            Copy-Item -LiteralPath $example -Destination (Join-Path $app 'config\lab.config.example.psd1')
            $root = Join-Path $dir 'HyperVLab'
            New-FakeLab -Root $root -Name 'TESTLAB' -Domain 'one.lab'
            $mk = { param($file, $name, $labRoot, $member)
                "@{`r`n    BaseConfig    = 'lab.config.example.psd1'`r`n    SchemaVersion = 2`r`n    LabName       = '$name'`r`n    Paths   = @{ LabRoot = '$labRoot' }`r`n    Domain  = @{ Fqdn = 'one.lab'; NetBiosName = 'ONE' }`r`n    MemberServers = @( @{ Name = '$member'; HostOctet = 20; ProcessorCount = 2; MemoryBytes = 4GB; DiskSizeBytes = 80GB; Roles = @('IIS'); AdditionalFeatures = @() } )`r`n}" |
                    Set-Content -LiteralPath (Join-Path $app "config\$file") -Encoding ASCII }
            & $mk 'lab.config.psd1' 'DIFFLAB' (Join-Path $dir 'HyperVLab-Diff') 'WEB01'                 # current shared file = another lab
            & $mk 'lab.config.psd1.bak-20261115-120000' 'TESTLAB' $root 'OLDWEB'
            Start-Sleep -Milliseconds 50
            & $mk 'lab.config.psd1.bak-20261115-140000' 'TESTLAB' $root 'WEB01'                       # newest TESTLAB backup
            $s = [pscustomobject]@{ Exists = $true; AppFolder = $app; LabsFolder = (Join-Path $dir 'Labs'); LibraryFolder = (Join-Path $dir 'Lib')
                ExternalLabs = @([pscustomobject]@{ Name = 'TESTLAB'; LabRoot = $root; ConfigPath = ''; OutputPath = '' }) }
            $lab = @(Get-LabInventory -Settings $s -NoSize)[0]
            $path = Restore-LabLegacyConfig -Lab $lab -AppFolder $app
            $path | Should Be (Join-Path $root 'lab.config.psd1')
            $c = Import-LabConfig -Path $path
            $c.LabName | Should Be 'TESTLAB'
            $c.MemberServers[0].Name | Should Be 'WEB01'
            @($c.MemberServers[0].Roles) -contains 'IIS' | Should Be $true
            $c.Iso.Images.Server2025.Kind | Should Be 'Server'    # BaseConfig resolved from the lab folder
            Restore-LabLegacyConfig -Lab ([pscustomobject]@{ Name = 'NOPE'; LabRoot = $root; ConfigPath = (Join-Path $dir 'x.psd1') }) -AppFolder $app | Should Be ''
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

Describe 'Config reconstruction (New-LabConfigFromInventory)' {
    It 'rebuilds a valid config from lab.json (servers, workstations, network, disks)' {
        $dir = New-TempDir
        try {
            $root = Join-Path $dir 'HyperVLab'
            New-FakeLab -Root $root -Name 'OLDLAB' -Domain 'one.lab'
            $s = [pscustomobject]@{ Exists = $true; AppFolder = $repo; LabsFolder = (Join-Path $dir 'Labs'); LibraryFolder = (Join-Path $dir 'Lib')
                ExternalLabs = @([pscustomobject]@{ Name = 'OLDLAB'; LabRoot = $root; ConfigPath = ''; OutputPath = (Join-Path $root 'output') }) }
            $lab = @(Get-LabInventory -Settings $s -NoSize)[0]
            $text = New-LabConfigFromInventory -Lab $lab -BaseConfig $example -LibraryRoot (Join-Path $dir 'Lib')
            [IO.File]::WriteAllText($lab.ConfigPath, $text, [Text.Encoding]::ASCII)
            $c = Import-LabConfig -Path $lab.ConfigPath
            $c.LabName | Should Be 'OLDLAB'
            $c.Domain.Fqdn | Should Be 'one.lab'
            $c.Domain.NetBiosName | Should Be 'ONE'
            $c.Network.SwitchName | Should Be 'LAB-OLDLAB'
            $c.Network.Prefix | Should Be '10.10.30'
            $c.Disks.Type | Should Be 'Differencing'
            $defs = @(Get-LabVmDefinition -Config $c)
            ($defs | ForEach-Object VMName | Sort-Object) -join ',' | Should Be 'OLDLAB-DC01,OLDLAB-WEB01,OLDLAB-WS01,OLDLAB-WS02'
            ($defs | Where-Object Name -eq 'WEB01').Image | Should Be 'Server2022'
            ($defs | Where-Object Name -eq 'WS02').IPAddress | Should Be '10.10.30.102'
            (@(Test-LabConfig -Config $c) -join ' | ') | Should Be ''
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

Describe 'Image library inventory (Get-LabLibraryInventory)' {
    It 'reports ISOs, base images (current or older ISO) and unknown ISO files, servers first' {
        $dir = New-TempDir
        try {
            $c = Get-ValidConfig
            New-Item -ItemType Directory -Path (Join-Path $dir 'ISO'), (Join-Path $dir 'BaseImages') | Out-Null
            $iso = Join-Path $dir ('ISO\' + $c.Iso.Images.Server2022.FileName)
            Set-Content -LiteralPath $iso -Value 'iso' -Encoding ASCII
            & (Get-Module LabBuilder) { param($C, $I, $D)
                $e = New-LabIsoManifestEntry -Key 'Server2022' -Image $C.Iso.Images.Server2022 -Path $I -Sha256 'AAA' -ResolvedUrl 'https://x'
                Write-LabIsoManifest -Folder (Join-Path $D 'ISO') -Map @{ ([string]$e.FileName) = $e } } $c $iso $dir
            Set-Content -LiteralPath (Join-Path $dir 'BaseImages\Server2022.vhdx') -Value 'vhd' -Encoding ASCII
            '{ "Version": "10.0.20348.587", "Language": "en-US", "IsoSha256": "BBB", "CreatedUtc": "2026-11-15T10:00:00Z" }' | Set-Content -LiteralPath (Join-Path $dir 'BaseImages\Server2022.vhdx.json') -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $dir 'ISO\something-else.iso') -Value 'x' -Encoding ASCII
            $inv = Get-LabLibraryInventory -LibraryRoot $dir -Catalog $c.Iso.Images -NoUsers
            (@($inv.Images) | ForEach-Object Key) -join ',' | Should Be 'Server2025,Server2022,Server2019,Win11LTSC,Win10'
            $s22 = $inv.Images | Where-Object Key -eq 'Server2022'
            $s22.IsoPresent | Should Be $true
            $s22.BasePresent | Should Be $true
            $s22.BaseVersion | Should Be '10.0.20348.587'
            $s22.BaseCurrent | Should Be $false     # base built from another ISO hash
            ($inv.Images | Where-Object Key -eq 'Server2025').IsoPresent | Should Be $false
            @($inv.UnknownIsos).Count | Should Be 1
            $inv.UnknownIsos[0].FileName | Should Be 'something-else.iso'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

Describe 'Delete a lab (Remove-LabFromInventory) - files only, no Hyper-V objects' {
    It 'removes the lab''s own files and folder and its credentials, keeps foreign files and the library' {
        $dir = New-TempDir
        try {
            $root = Join-Path $dir 'HyperVLab'
            New-FakeLab -Root $root -Name 'GONELAB' -WithConfig
            New-Item -ItemType Directory -Path (Join-Path $root 'VMs\GONELAB-DC01'), (Join-Path $dir 'Lib\BaseImages') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'VMs\GONELAB-DC01\disk.vhdx') -Value 'x'
            Set-Content -LiteralPath (Join-Path $dir 'Lib\BaseImages\Server2025.vhdx') -Value 'base'
            $s = [pscustomobject]@{ Exists = $false; AppFolder = $dir; LabsFolder = (Join-Path $dir 'Labs'); LibraryFolder = (Join-Path $dir 'Lib')
                ExternalLabs = @([pscustomobject]@{ Name = 'GONELAB'; LabRoot = $root; ConfigPath = ''; OutputPath = '' }) }
            $lab = @(Get-LabInventory -Settings $s -NoSize)[0]
            $lab.Switch = ''   # no Hyper-V switch in the test
            Remove-LabFromInventory -Lab $lab -Settings $s -Confirm:$false 6>$null 3>$null
            Test-Path -LiteralPath $root | Should Be $false
            Test-Path -LiteralPath (Join-Path $dir 'Lib\BaseImages\Server2025.vhdx') | Should Be $true
            @($s.ExternalLabs).Count | Should Be 0
            # a foreign file keeps the folder
            New-FakeLab -Root $root -Name 'GONELAB'
            Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Value 'mine'
            $lab = @(Get-LabInventory -Settings ([pscustomobject]@{ Exists = $false; AppFolder = $dir; LabsFolder = $dir; LibraryFolder = (Join-Path $dir 'Lib'); ExternalLabs = @([pscustomobject]@{ Name = 'GONELAB'; LabRoot = $root; ConfigPath = ''; OutputPath = '' }) }) -NoSize)[0]
            $lab.Switch = ''
            Remove-LabFromInventory -Lab $lab -Settings $s -Confirm:$false 6>$null 3>$null
            Test-Path -LiteralPath (Join-Path $root 'notes.txt') | Should Be $true
            Test-Path -LiteralPath (Join-Path $root 'lab.json') | Should Be $false
            Test-Path -LiteralPath (Join-Path $root 'output') | Should Be $false
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}
