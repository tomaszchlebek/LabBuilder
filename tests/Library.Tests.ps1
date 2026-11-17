# Pester 3.4 tests for release 1.2.0: OS catalog, shared image library and lab manifest (FR-21..FR-23, ADR 0013).
# Run: Invoke-Pester .\tests

$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\LabBuilder\LabBuilder.psd1') -Force
$example = Join-Path $repo 'config\lab.config.example.psd1'

function Get-ValidConfig {
    Import-LabConfig -Path $example -Overrides @{ 'Domain.Fqdn' = 'lab.test'; 'Domain.NetBiosName' = 'LABTEST' }
}
function Get-Errors { param($Config, $Scope = 'Full') (@(Test-LabConfig -Config $Config -Scope $Scope) -join ' | ') }

Describe 'OS catalog (FR-22)' {
    It 'has Server 2025/2022/2019, Windows 11 LTSC and a tester-supplied Windows 10' {
        $c = Get-ValidConfig
        (@($c.Iso.Images.PSObject.Properties | ForEach-Object Name) | Sort-Object) -join ',' | Should Be 'Server2019,Server2022,Server2025,Win10,Win11LTSC'
        $c.Iso.Images.Server2022.Url | Should Match 'LinkID=2195280'
        $c.Iso.Images.Server2019.Url | Should Match 'LinkID=2195167'
        $c.Iso.Images.Win10.Supplied | Should Be $true
        $c.Iso.Images.Win10.Kind | Should Be 'Client'
        Get-Errors $c -Scope Iso | Should Be ''
    }
    It 'gives every VM an OS key and kind; servers default to Iso.DefaultServerImage' {
        $c = Get-ValidConfig
        $c.MemberServers[0] | Add-Member -NotePropertyName Image -NotePropertyValue 'Server2019' -Force
        $defs = @(Get-LabVmDefinition -Config $c)
        ($defs | Where-Object Name -eq 'DC01').Image | Should Be 'Server2025'
        ($defs | Where-Object Name -eq 'IIS01').Image | Should Be 'Server2019'
        ($defs | Where-Object Name -eq 'IIS01').Kind | Should Be 'Server'
        ($defs | Where-Object Name -eq 'WS01').Kind | Should Be 'Client'
        Get-Errors $c | Should Be ''
    }
    It 'rejects unknown OS keys and the wrong kind of OS for a role' {
        $c = Get-ValidConfig; $c.DomainControllers[0] | Add-Member -NotePropertyName Image -NotePropertyValue 'Server2016' -Force
        Get-Errors $c | Should Match "uses OS 'Server2016', which is not in the OS catalog"
        $c = Get-ValidConfig; $c.MemberServers[0] | Add-Member -NotePropertyName Image -NotePropertyValue 'Win11LTSC' -Force
        Get-Errors $c | Should Match 'needs a Server image'
        $c = Get-ValidConfig; $c.Workstations.Image = 'Server2022'
        Get-Errors $c | Should Match 'needs a Client image'
    }
    It 'rejects an additional DC with a newer Windows Server than DC 1 (adprep, host run six)' {
        $c = Get-ValidConfig
        $dc2 = [pscustomobject]@{ Name = 'DC02'; HostOctet = 11; ProcessorCount = 2; MemoryBytes = 4GB; DiskSizeBytes = 80GB; Roles = @(); Image = 'Server2025' }
        $c.DomainControllers[0] | Add-Member -NotePropertyName Image -NotePropertyValue 'Server2022' -Force
        $c.DomainControllers = @($c.DomainControllers[0], $dc2)
        Get-Errors $c | Should Match 'Put the newest Windows Server on DC 1'
        $c.DomainControllers[0].Image = 'Server2025'; $dc2.Image = 'Server2022'
        Get-Errors $c | Should Not Match 'newest Windows Server'
        $dc2.Image = 'Server2025'
        Get-Errors $c | Should Not Match 'newest Windows Server'
    }
    It 'requires the tester ISO for Windows 10 and checks its path' {
        $c = Get-ValidConfig; $c.Workstations.Image = 'Win10'
        Get-Errors $c | Should Match 'choose the ISO file'
        $c.Iso.Images.Win10.SourcePath = 'E:\iso\win10.iso'
        Get-Errors $c | Should Be ''
        $c.Iso.Images.Win10.SourcePath = 'win10.img'
        Get-Errors $c | Should Match 'SourcePath must be the full path of an .iso file'
    }
    It 'explains configs that still use the 1.0/1.1 Server/Client catalog' {
        $c = Get-ValidConfig
        $c.Iso.Images = [pscustomobject]@{ Server = $c.Iso.Images.Server2025; Client = $c.Iso.Images.Win11LTSC }
        Get-Errors $c | Should Match 'LabBuilder 1.0/1.1 keys Server/Client'
    }
    It 'lists the OS images the lab uses (Win10 included when chosen)' {
        $c = Get-ValidConfig; $c.Workstations.Image = 'Win10'
        $c.DomainControllers[0] | Add-Member -NotePropertyName Image -NotePropertyValue 'Server2022' -Force
        $keys = & (Get-Module LabBuilder) { param($C) @(Get-LabRequiredImageKey -Config $C) } $c
        (@($keys) | Sort-Object) -join ',' | Should Be 'Server2022,Server2025,Win10'
    }
}

Describe 'Image library (FR-21)' {
    It 'puts the library on the lab drive by default and rejects a library inside the lab folder' {
        $c = Get-ValidConfig
        Get-LabLibraryRoot -Config $c | Should Be 'D:\LabBuilder-Library'
        $c.Paths.LibraryRoot = 'E:\Lib\'
        Get-LabLibraryRoot -Config $c | Should Be 'E:\Lib'
        $c.Paths.LibraryRoot = 'D:\HyperVLab\Library'
        Get-Errors $c | Should Match 'must not be inside Paths.LabRoot'
        $c.Paths.LibraryRoot = 'Library'
        Get-Errors $c | Should Match 'LibraryRoot .* must be an absolute path'
    }
    It 'stores one base image per OS in the library' {
        $c = Get-ValidConfig
        $c.Paths.LibraryRoot = $env:TEMP
        Get-LabBaseImagePath -Config $c -Image 'Server2022' | Should Be (Join-Path $env:TEMP 'BaseImages\Server2022.vhdx')
    }
    It 'runs a block under the library lock and returns its output (nested locks with other names)' {
        $r = Invoke-LabLibraryLock -Name 'PesterA' -ScriptBlock { Invoke-LabLibraryLock -Name 'PesterB' -ScriptBlock { 'inner' } }
        $r | Should Be 'inner'
    }
    It 'imports a tester-supplied ISO once and re-imports when the source changes' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("sup-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $dir 'lib') -Force | Out-Null
        try {
            $src = Join-Path $dir 'my-win10.iso'
            Set-Content -LiteralPath $src -Value 'fake iso one' -Encoding ASCII
            $c = Get-ValidConfig; $c.Iso.Images.Win10.SourcePath = $src
            $lib = Join-Path $dir 'lib'
            $e1 = Import-LabSuppliedIso -Config $c -Key 'Win10' -Destination $lib
            $e1.SourcePath | Should Be $src
            Test-Path (Join-Path $lib 'Windows10-supplied.iso') | Should Be $true
            $e2 = Import-LabSuppliedIso -Config $c -Key 'Win10' -Destination $lib
            $e2.Sha256 | Should Be $e1.Sha256
            Set-Content -LiteralPath $src -Value 'fake iso two - another build' -Encoding ASCII
            $e3 = Import-LabSuppliedIso -Config $c -Key 'Win10' -Destination $lib
            $e3.Sha256 | Should Not Be $e1.Sha256
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
    It 'moves 1.0/1.1 ISOs from the lab folder into the library' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("mig-{0}" -f [guid]::NewGuid())
        $legacy = Join-Path $dir 'lab\ISO'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        try {
            $c = Get-ValidConfig; $c.Paths.LabRoot = (Join-Path $dir 'lab'); $c.Paths.LibraryRoot = (Join-Path $dir 'library')
            $fileName = [string]$c.Iso.Images.Server2025.FileName
            $iso = Join-Path $legacy $fileName
            Set-Content -LiteralPath $iso -Value 'old server iso' -Encoding ASCII
            $hash = (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash
            & (Get-Module LabBuilder) {
                param($C, $Iso, $Hash, $Legacy)
                $e = New-LabIsoManifestEntry -Key 'Server' -Image $C.Iso.Images.Server2025 -Path $Iso -Sha256 $Hash -ResolvedUrl 'https://x'
                Write-LabIsoManifest -Folder $Legacy -Map @{ ([string]$e.FileName) = $e }
            } $c $iso $hash $legacy
            Move-LabLegacyMedia -Config $c
            Test-Path -LiteralPath (Join-Path $dir "library\ISO\$fileName") | Should Be $true
            Test-Path -LiteralPath $iso | Should Be $false
            $m = & (Get-Module LabBuilder) { param($D) Read-LabIsoManifest -Folder $D } (Join-Path $dir 'library\ISO')
            $m[$fileName].Key | Should Be 'Server2025'
            $m[$fileName].Sha256 | Should Be $hash
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

Describe 'Lab manifest and VM tags (FR-23)' {
    It 'tags VM notes with LabBuilder:<LabName>' {
        $c = Get-ValidConfig
        $d = @(Get-LabVmDefinition -Config $c)[0]
        Get-LabVmNote -Config $c -Definition $d | Should Match '^LabBuilder:TESTLAB \| DomainController DC01 10\.10\.10\.10 \| Server2025$'
    }
    It 'writes lab.json without secrets and keeps CreatedUtc on update' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("lab-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $root | Out-Null
        try {
            $c = Get-ValidConfig; $c.Paths.LabRoot = $root
            Write-LabManifest -Config $c -Phase 'Preflight'
            $file = Join-Path $root 'lab.json'
            $m = (Get-Content -LiteralPath $file -Raw) | ConvertFrom-Json
            $m.LabName | Should Be 'TESTLAB'
            $m.Format | Should Be 'LabBuilder.Lab/1'
            @($m.VMs).Count | Should Be 3
            (@($m.VMs) | Where-Object Name -eq 'WS01').Image | Should Be 'Win11LTSC'
            $created = $m.CreatedUtc
            Start-Sleep -Milliseconds 20
            Write-LabManifest -Config $c -Phase 'Iso'
            $m2 = (Get-Content -LiteralPath $file -Raw) | ConvertFrom-Json
            $m2.CreatedUtc | Should Be $created
            $m2.LastPhase | Should Be 'Iso'
            (Get-Content -LiteralPath $file -Raw) | Should Not Match 'Password'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Describe 'Windows feature install: transient servicing errors (tester run 2026-11-15)' {
    It 'treats the tester''s 0x80071A2D error as transient and real failures as fatal' {
        $tester = 'The request to list features available on the specified server failed. An unexpected error has occurred. The requested operation was made in the context of a transaction that is no longer active.   Error: 0x80071a2d'
        & (Get-Module LabBuilder) { param($M) Test-LabServicingError -Message $M } $tester | Should Be $true
        & (Get-Module LabBuilder) { param($M) Test-LabServicingError -Message $M } 'Install-WindowsFeature : ArgumentNotValid: The role, role service, or feature name is not valid' | Should Be $false
        & (Get-Module LabBuilder) { param($M) Test-LabServicingError -Message $M } 'The source files could not be found. Error: 0x800f081f' | Should Be $false
    }
}

Describe 'AD module loading (tester run 4, 2026-11-15)' {
    It 'never disables the AD: drive in a script block that uses AD:\ paths' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        foreach ($f in Get-ChildItem (Join-Path $repoRoot 'src\LabBuilder') -Recurse -Filter *.ps1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $blocks = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
            foreach ($b in $blocks) {
                $text = $b.Extent.Text
                if ($text -match 'AD:\\' -and $text -match 'ADPS_LoadDefaultDrive\s*=\s*0') {
                    throw "$($f.Name) line $($b.Extent.StartLineNumber): uses AD:\ but disables the AD: drive"
                }
            }
        }
        $true | Should Be $true
    }
}

Describe 'Host conflicts with another lab (Test-LabHostConflict)' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("conf-{0}" -f [guid]::NewGuid())
    It 'finds nothing for a new lab' {
        New-Item -ItemType Directory -Path (Join-Path $dir 'output'), (Join-Path $dir 'lab') -Force | Out-Null
        $c = Get-ValidConfig; $c.Paths.LabRoot = (Join-Path $dir 'lab'); $c.Network.SwitchName = 'LAB-Pester-NoSuchSwitch'
        @(Test-LabHostConflict -Config $c -OutputRoot (Join-Path $dir 'output')).Count | Should Be 0
    }
    It 'reports the same lab name used by a lab of another domain (tester case 2026-11-15)' {
        $c = Get-ValidConfig; $c.Paths.LabRoot = (Join-Path $dir 'lab'); $c.Network.SwitchName = 'LAB-Pester-NoSuchSwitch'
        New-Item -ItemType Directory -Path (Join-Path $dir 'output\TESTLAB') -Force | Out-Null
        [pscustomobject]@{ Type = 'TestUser'; SamAccountName = 'a.b'; UserPrincipalName = 'a.b@old.lab' } |
            Export-Csv -LiteralPath (Join-Path $dir 'output\TESTLAB\lab-accounts.csv') -NoTypeInformation
        $e = @(Test-LabHostConflict -Config $c -OutputRoot (Join-Path $dir 'output')) -join ' | '
        $e | Should Match "Lab name 'TESTLAB' is already used on this host by a lab of domain 'old.lab'"
        $e | Should Match 'Choose another lab name'
        # the same lab (same domain) re-run is fine
        [pscustomobject]@{ Type = 'TestUser'; SamAccountName = 'a.b'; UserPrincipalName = 'a.b@lab.test' } |
            Export-Csv -LiteralPath (Join-Path $dir 'output\TESTLAB\lab-accounts.csv') -NoTypeInformation
        @(Test-LabHostConflict -Config $c -OutputRoot (Join-Path $dir 'output')).Count | Should Be 0
    }
    It 'reports a lab folder that belongs to another lab (1.1 state.json or 1.2 lab.json)' {
        $c = Get-ValidConfig; $c.Paths.LabRoot = (Join-Path $dir 'lab'); $c.Network.SwitchName = 'LAB-Pester-NoSuchSwitch'
        '{ "LabName": "OLDLAB" }' | Set-Content -LiteralPath (Join-Path $dir 'lab\state.json') -Encoding ASCII
        @(Test-LabHostConflict -Config $c) -join ' | ' | Should Match "already belongs to lab 'OLDLAB'"
        '{ "LabName": "TESTLAB", "Domain": "other.test" }' | Set-Content -LiteralPath (Join-Path $dir 'lab\lab.json') -Encoding ASCII
        @(Test-LabHostConflict -Config $c) -join ' | ' | Should Match "already belongs to lab 'TESTLAB' \(domain other.test\)"
        '{ "LabName": "TESTLAB", "Domain": "lab.test" }' | Set-Content -LiteralPath (Join-Path $dir 'lab\lab.json') -Encoding ASCII
        @(Test-LabHostConflict -Config $c).Count | Should Be 0
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}
