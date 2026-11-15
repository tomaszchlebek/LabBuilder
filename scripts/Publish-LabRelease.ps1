#Requires -Version 5.1
<#
.SYNOPSIS
    Publishes a LabBuilder release to GitHub: checks, tests, builds the exe, commits, tags and creates the release.

.DESCRIPTION
    Maintainer script (ROADMAP "shared groundwork"). Run it only after the tester's host run passed (ROADMAP decision D4).
    1. Checks: git repository on branch main, version = ModuleVersion in src\LabBuilder\LabBuilder.psd1, tag vX.Y.Z does
       not exist yet, CHANGELOG has a "## [X.Y.Z]" section, no git-ignored secret/output file is staged.
    2. Runs Pester 3.4 tests (tests\) - stops on any failure.
    3. Builds installer\bin\LabBuilderSetup.exe (installer\build.ps1) and checks its file version.
    4. Commits all changes (Conventional Commit message from -Message), pushes main, creates and pushes tag vX.Y.Z.
    5. gh release create vX.Y.Z with the exe; notes = the CHANGELOG section + SHA-256 (links absolute to the tag).
    -WhatIf shows the steps without committing, pushing or releasing. Needs git and an authenticated gh CLI.

.EXAMPLE
    .\scripts\Publish-LabRelease.ps1 -Message 'feat: branded, resizable wizard (1.1.1)' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$Message,
    [string]$Repository = 'tomaszchlebek/LabBuilder',
    [string]$Trailer,                     # optional commit trailer line, e.g. Co-Authored-By
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repo
# -WhatIf only guards the publish step; tests and the exe build must really run.
$dryRun = [bool]$WhatIfPreference
$WhatIfPreference = $false

function Invoke-Git {   # simple function: every argument (also --options) goes to git unchanged
    # git writes warnings (e.g. CRLF) to stderr; in Windows PowerShell 5.1 that is an error record, so the exit code decides.
    $ErrorActionPreference = 'Continue'
    $out = @(& git @args 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { throw ('git {0} failed: {1}' -f ($args -join ' '), ($out -join "`n")) }
    $out | Where-Object { $_ -notmatch '^warning: ' }
}

# --- 1. Checks ---
$version = (Import-PowerShellDataFile -LiteralPath (Join-Path $repo 'src\LabBuilder\LabBuilder.psd1')).ModuleVersion
$tag = "v$version"
Write-Host "Release $tag" -ForegroundColor Cyan
$branch = (Invoke-Git rev-parse --abbrev-ref HEAD | Out-String).Trim()
if ($branch -ne 'main') { throw "Not on branch main (on $branch)." }
if ((& git tag --list $tag)) { throw "Tag $tag already exists - bump ModuleVersion first." }

$changelog = Get-Content -LiteralPath (Join-Path $repo 'CHANGELOG.md') -Raw
$m = [regex]::Match($changelog, "(?ms)^## \[$([regex]::Escape($version))\][^\n]*\n(.*?)(?=^## \[|\z)")
if (-not $m.Success) { throw "CHANGELOG.md has no '## [$version]' section." }
$notesBody = $m.Groups[1].Value.Trim()

Invoke-Git add -A | Out-Null
$staged = @(Invoke-Git diff --cached --name-only)
$bad = @($staged | Where-Object { $_ -match '(^|/)output/|\.cred\.xml$|lab-accounts\.csv$|lab-sql\.csv$|config/lab\.config\.psd1$|\.(iso|vhdx?|avhdx)$|^installer/(bin|obj)/' })
if ($bad.Count) { Invoke-Git reset -q | Out-Null; throw "Refusing to commit generated/secret files: $($bad -join ', ')" }
Write-Host ("{0} changed file(s) staged" -f $staged.Count)
trap { & git reset -q 2>$null; break }   # any failure before the commit leaves the index as it was

# --- 2. Tests ---
if (-not $SkipTests) {
    Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop
    $r = Invoke-Pester -Path (Join-Path $repo 'tests') -PassThru -Quiet
    Write-Host ("Pester: {0} passed, {1} failed" -f $r.PassedCount, $r.FailedCount)
    if ($r.FailedCount -gt 0) { throw 'Tests failed - release stopped.' }
}

# --- 3. Build ---
& (Join-Path $repo 'installer\build.ps1') | Out-Host
$exe = Join-Path $repo 'installer\bin\LabBuilderSetup.exe'
$fileVersion = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
if ($fileVersion -ne $version) { throw "Exe product version $fileVersion does not match $version." }
$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash

# --- 4/5. Commit, tag, release ---
$base = "https://github.com/$Repository/blob/$tag"
$notes = ($notesBody -replace '\]\((?!https?://)([^)]+)\)', "]($base/`$1)") + @"


**Download:** ``LabBuilderSetup.exe`` below - run elevated on a Hyper-V host.
SHA-256: ``$hash``
"@
if (-not $dryRun) {
    $msg = $Message
    if ($Trailer) { $msg = "$Message`n`n$Trailer" }
    Invoke-Git commit -q -m $msg | Out-Null
    Invoke-Git push -q origin main | Out-Null
    Invoke-Git tag $tag | Out-Null
    Invoke-Git push -q origin $tag | Out-Null
    $notesFile = Join-Path ([IO.Path]::GetTempPath()) "LabBuilder-$tag-notes.md"
    Set-Content -LiteralPath $notesFile -Value $notes -Encoding UTF8
    try {
        & gh release create $tag $exe --repo $Repository --title "LabBuilder $version" --notes-file $notesFile --latest
        if ($LASTEXITCODE -ne 0) { throw "gh release create failed ($LASTEXITCODE)." }
    } finally { Remove-Item -LiteralPath $notesFile -Force -ErrorAction SilentlyContinue }
    Write-Host "Published https://github.com/$Repository/releases/tag/$tag" -ForegroundColor Green
} else {
    Invoke-Git reset -q | Out-Null
    Write-Host "WhatIf: would commit '$Message', push main, tag $tag and release with SHA-256 $hash"
}
