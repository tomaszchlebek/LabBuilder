$script:ClientLocalAdminName = 'LabAdmin'

function New-LabUnattendXml {
    <#
    .SYNOPSIS
        Renders the server or client unattend.xml template for one VM (ADR 0004).
    .OUTPUTS
        The XML text. Passwords are in unattend encoding, never plaintext.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('Server', 'Client')][string]$Image,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][pscredential]$AdminCredential,
        [Parameter(Mandatory)]$Locale
    )

    $templateFile = Join-Path $script:TemplateRoot ('unattend-{0}.xml' -f $Image.ToLowerInvariant())
    $text = [System.IO.File]::ReadAllText($templateFile)
    $plain = $AdminCredential.GetNetworkCredential().Password

    $tokens = [ordered]@{
        '__COMPUTERNAME__'       = $ComputerName
        '__TIMEZONE__'           = [string]$Locale.TimeZone
        '__INPUTLOCALE__'        = [string]$Locale.InputLocale
        '__SYSTEMLOCALE__'       = [string]$Locale.SystemLocale
        '__UILANGUAGE__'         = [string]$Locale.UILanguage
        '__USERLOCALE__'         = [string]$Locale.UserLocale
        '__ADMINPASSWORD__'      = (ConvertTo-UnattendPassword -Password $plain -Kind AdministratorPassword)
        '__LOCALADMIN__'         = $script:ClientLocalAdminName
        '__LOCALADMINPASSWORD__' = (ConvertTo-UnattendPassword -Password $plain -Kind Password)
    }
    foreach ($k in $tokens.Keys) {
        $text = $text.Replace($k, [System.Security.SecurityElement]::Escape([string]$tokens[$k]))
    }
    if ($text -match '__[A-Z]+__') { throw "Unattend template $templateFile has an unknown token: $($Matches[0])" }

    [void][xml]$text   # throws if the result is not well-formed
    return $text
}

function Resolve-LabLocale {
    <#
    .SYNOPSIS
        Regional settings for the VMs (ADR 0010): config values, else the Hyper-V host's settings.
        UILanguage: config, else -ImageLanguage (language of the Windows image), else en-US.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [string]$ImageLanguage)

    $cfg = $Config.Locale
    $pick = { param($v, $fallback) if ($v) { [string]$v } else { [string]$fallback } }

    $hostTz = ''
    try { $hostTz = (Get-TimeZone).Id } catch { $hostTz = [TimeZoneInfo]::Local.Id }
    $hostSys = ''
    try { $hostSys = (Get-WinSystemLocale).Name } catch { }
    $hostUser = (Get-Culture).Name
    $hostInput = ''
    try {
        $lang = @(Get-WinUserLanguageList)[0]
        if ($lang) {
            if (@($lang.InputMethodTips).Count -gt 0 -and $lang.InputMethodTips[0]) { $hostInput = [string]$lang.InputMethodTips[0] }
            elseif ($lang.LanguageTag) { $hostInput = [string]$lang.LanguageTag }
        }
    } catch { }
    if (-not $hostSys) { $hostSys = $hostUser }
    if (-not $hostInput) { $hostInput = $hostUser }
    $ui = 'en-US'
    if ($ImageLanguage) { $ui = $ImageLanguage }

    return [pscustomobject]@{
        UILanguage   = (& $pick $cfg.UILanguage $ui)
        InputLocale  = (& $pick $cfg.InputLocale $hostInput)
        SystemLocale = (& $pick $cfg.SystemLocale $hostSys)
        UserLocale   = (& $pick $cfg.UserLocale $hostUser)
        TimeZone     = (& $pick $cfg.TimeZone $hostTz)
    }
}

function Get-LabLocalAdminName {
    # Local admin user PowerShell Direct uses before domain join: Administrator on servers, LabAdmin on Windows 11.
    param([Parameter(Mandatory)][ValidateSet('Server', 'Client')][string]$Image)
    if ($Image -eq 'Client') { return $script:ClientLocalAdminName }
    return 'Administrator'
}
