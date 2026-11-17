function Get-LabLicenceVerdict {
    <#
    .SYNOPSIS
        Decides whether a VM's Windows licence is usable (validation check "Windows licence not expired").
        Pure function: also injected into the in-VM validation block, so it must not call other module functions.
    .DESCRIPTION
        LicenseStatus (SoftwareLicensingProduct): 0 Unlicensed, 1 Licensed, 2 OOB grace, 3 OOT grace, 4 non-genuine grace,
        5 Notification, 6 extended grace. An evaluation edition (description TIMEBASED_EVAL, or the WLMS service present)
        whose time has run out is shut down every hour by wlms.exe (host run seven, Windows 11 LTSC eval 26100.1742).
        Non-evaluation installs that are merely not activated pass with a note: they keep running.
    #>
    param(
        [int]$LicenseStatus,
        [int64]$GraceMinutes,
        [string]$Description,
        [bool]$HasWlms,
        [datetime]$Now
    )
    $statusNames = @{ 0 = 'unlicensed'; 1 = 'licensed'; 2 = 'initial grace'; 3 = 'additional grace'; 4 = 'non-genuine grace'; 5 = 'notification'; 6 = 'extended grace' }
    $statusName = [string]$statusNames[$LicenseStatus]
    if (-not $statusName) { $statusName = "status $LicenseStatus" }
    $isEval = ($Description -match 'TIMEBASED_EVAL') -or $HasWlms
    $okStatus = @(1, 2, 3, 6) -contains $LicenseStatus
    if ($isEval) {
        if ($okStatus -and $GraceMinutes -gt 0) {
            $days = [math]::Floor($GraceMinutes / 1440)
            $ends = $Now.AddMinutes($GraceMinutes).ToString('yyyy-MM-dd')
            return [pscustomobject]@{ Passed = $true; Expired = $false; Detail = "evaluation, $days day(s) left (until $ends)" }
        }
        return [pscustomobject]@{ Passed = $false; Expired = $true
            Detail = "evaluation EXPIRED ($statusName) - Windows shuts this VM down every hour; use a newer evaluation ISO or a licensed ISO" }
    }
    if ($LicenseStatus -eq 1) {
        $how = 'licensed'; if ($Description -match 'VIRTUAL_MACHINE_ACTIVATION') { $how = 'licensed (AVMA, renewed by the host)' }
        return [pscustomobject]@{ Passed = $true; Expired = $false; Detail = $how }
    }
    return [pscustomobject]@{ Passed = $true; Expired = $false; Detail = "not activated ($statusName) - keeps running" }
}
