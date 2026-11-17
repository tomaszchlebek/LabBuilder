$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\src\LabBuilder\LabBuilder.psd1') -Force

Describe 'Windows licence check (host run seven: expired Win11 LTSC evaluation)' {
    $now = [datetime]'2026-11-17T10:00:00'
    $verdict = { param($S, $G, $D, $W) & (Get-Module LabBuilder) { param($S, $G, $D, $W, $N) Get-LabLicenceVerdict -LicenseStatus $S -GraceMinutes $G -Description $D -HasWlms $W -Now $N } $S $G $D $W $now }

    It 'fails an expired evaluation (wlms shuts the VM down every hour)' {
        $r = & $verdict 5 0 'Windows(R) Operating System, TIMEBASED_EVAL channel' $true
        $r.Passed | Should Be $false
        $r.Expired | Should Be $true
        $r.Detail | Should Match 'EXPIRED'
    }
    It 'fails an evaluation with licensed status but no time left' {
        (& $verdict 1 0 'TIMEBASED_EVAL channel' $false).Passed | Should Be $false
    }
    It 'passes a running evaluation and shows the days left' {
        $r = & $verdict 1 (172 * 1440 + 30) 'Windows(R) Operating System, TIMEBASED_EVAL channel' $true
        $r.Passed | Should Be $true
        $r.Detail | Should Be 'evaluation, 172 day(s) left (until 2027-05-08)'
    }
    It 'treats the WLMS service alone as an evaluation' {
        (& $verdict 5 0 'RETAIL channel' $true).Passed | Should Be $false
    }
    It 'passes licensed and merely unactivated non-evaluation installs' {
        (& $verdict 1 0 'Windows(R) Operating System, VOLUME_KMSCLIENT channel' $false).Detail | Should Be 'licensed'
        $r = & $verdict 5 0 'Windows(R) Operating System, RETAIL channel' $false
        $r.Passed | Should Be $true
        $r.Detail | Should Match 'not activated'
    }
    It 'is self-contained so it can run inside the VM' {
        $body = & (Get-Module LabBuilder) { ${function:Get-LabLicenceVerdict} }
        $body | Should Not BeNullOrEmpty
        $cmds = @($body.Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        @($cmds | Where-Object { $_ -like '*-Lab*' }).Count | Should Be 0
    }
    It 'the validation module injects the function into the in-VM OS check' {
        $src = Get-Content (Join-Path $here '..\src\LabBuilder\Public\Validation.ps1') -Raw
        $src | Should Match '__LICENCE_FUNCTION__'
        $src | Should Match 'Windows licence not expired'
        $src | Should Match ([regex]::Escape('${function:Get-LabLicenceVerdict}'))
    }
}
