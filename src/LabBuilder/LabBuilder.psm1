# LabBuilder - builds an isolated AD/CA/IIS/Windows 11 lab on Hyper-V.
# Public functions are in Public\, internal helpers in Private\. ASCII only (Windows PowerShell 5.1).

$script:ModuleRoot   = $PSScriptRoot
$script:TemplateRoot = Join-Path $PSScriptRoot 'Templates'
$script:LabLogFile   = $null

$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($private + $public)) {
    . $file.FullName
}

# The manifest (FunctionsToExport) decides what is public; import the .psd1, not this file.
Export-ModuleMember -Function *
