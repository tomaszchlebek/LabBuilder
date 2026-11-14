#Requires -Version 5.1
<#
.SYNOPSIS
    Builds installer\bin\LabBuilderSetup.exe (ADR 0011) with the inbox .NET Framework 4.8 C# compiler - no SDK, no NuGet.

.DESCRIPTION
    1. Stages the application payload (src\LabBuilder, scripts, config example, docs, README, CHANGELOG) and zips it
       with forward-slash entry names.
    2. Generates AssemblyInfo with the LabBuilder module version.
    3. Compiles installer\src\*.cs with %windir%\Microsoft.NET\Framework64\v4.0.30319\csc.exe (C# 5), embedding the
       payload and app.manifest (requireAdministrator).
    Prints the SHA-256 of the exe.

.EXAMPLE
    .\installer\build.ps1
#>
[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Stop'
$installer = $PSScriptRoot
$repo = Split-Path -Parent $installer
if (-not $OutDir) { $OutDir = Join-Path $installer 'bin' }
$obj = Join-Path $installer 'obj'

$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw ".NET Framework 4.x C# compiler not found: $csc" }

if (Test-Path -LiteralPath $obj) { Remove-Item -LiteralPath $obj -Recurse -Force }
New-Item -ItemType Directory -Path $obj, $OutDir -Force | Out-Null

$version = (Import-PowerShellDataFile -LiteralPath (Join-Path $repo 'src\LabBuilder\LabBuilder.psd1')).ModuleVersion
Write-Host "LabBuilder version $version"

# --- 1. Payload ---
$items = @(
    @{ From = 'src\LabBuilder';                   Recurse = $true }
    @{ From = 'scripts';                          Recurse = $true }
    @{ From = 'config\lab.config.example.psd1';   Recurse = $false }
    @{ From = 'docs';                             Recurse = $true }
    @{ From = 'README.md';                        Recurse = $false }
    @{ From = 'CHANGELOG.md';                     Recurse = $false }
)
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zipPath = Join-Path $obj 'payload.zip'
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
$count = 0
try {
    foreach ($i in $items) {
        $src = Join-Path $repo $i.From
        if (-not (Test-Path -LiteralPath $src)) { throw "Payload item missing: $src" }
        $files = @()
        if ((Get-Item -LiteralPath $src).PSIsContainer) { $files = @(Get-ChildItem -LiteralPath $src -Recurse -File) } else { $files = @(Get-Item -LiteralPath $src) }
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($repo.Length).TrimStart('\').Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel, [System.IO.Compression.CompressionLevel]::Optimal)
            $count++
        }
    }
} finally { $zip.Dispose() }
Write-Host ("Payload: {0} files, {1:N0} KB" -f $count, ((Get-Item $zipPath).Length / 1KB))

# --- 2. Assembly info ---
$asmInfo = Join-Path $obj 'AssemblyInfo.cs'
@"
using System.Reflection;
[assembly: AssemblyTitle("LabBuilder Setup")]
[assembly: AssemblyDescription("Wizard that installs LabBuilder and builds an isolated Hyper-V TEST environment.")]
[assembly: AssemblyProduct("LabBuilder")]
[assembly: AssemblyVersion("$version.0")]
[assembly: AssemblyFileVersion("$version.0")]
[assembly: AssemblyInformationalVersion("$version")]
"@ | Set-Content -LiteralPath $asmInfo -Encoding ASCII

# --- 3. Compile ---
$exe = Join-Path $OutDir 'LabBuilderSetup.exe'
$refs = @('System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.ServiceProcess.dll',
          'System.Web.Extensions.dll', 'System.IO.Compression.dll', 'System.IO.Compression.FileSystem.dll', 'Microsoft.VisualBasic.dll')
$sources = @(Get-ChildItem -LiteralPath (Join-Path $installer 'src') -Filter '*.cs' | ForEach-Object FullName) + $asmInfo
$cscArgs = @('/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/warn:4', '/langversion:5',
             "/out:$exe", ('/win32manifest:' + (Join-Path $installer 'app.manifest')),
             "/resource:$zipPath,LabBuilderSetup.payload.zip") + ($refs | ForEach-Object { "/reference:$_" }) + $sources
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE" }

$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
Write-Host ("Built {0} ({1:N0} KB)" -f $exe, ((Get-Item $exe).Length / 1KB))
Write-Host "SHA-256 $hash"
