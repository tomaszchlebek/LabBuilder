# Lab configuration (schema v2, ADR 0009) - written by LabBuilderSetup.exe, or copy to config\lab.config.psd1 and edit.
# The build runs directly on the Hyper-V host (ADR 0007).
# Values passed on the command line (-DomainFqdn, -DomainNetbios, -LabRoot) override this file.
# All disks are dynamically expanding VHDX (ADR 0008). ASCII only (Windows PowerShell 5.1).
@{
    SchemaVersion = 2
    LabName = 'TESTLAB'                     # prefix of VM names on the host: <LabName>-<ComputerName>

    Paths = @{
        LabRoot     = 'D:\HyperVLab'        # this lab on the Hyper-V host: VMs, Logs, Reports, lab.json
        LibraryRoot = ''                    # image library shared by ALL labs (ISO, BaseImages); '' = <LabRoot drive>:\LabBuilder-Library
        MinFreeGB   = 150                   # free space required on the LabRoot drive
    }

    Domain = @{
        Fqdn            = ''                # e.g. lab.test (wizard / -DomainFqdn)
        NetBiosName     = ''                # e.g. LABTEST (wizard / -DomainNetbios)
        DomainMode      = 'WinThreshold'    # functional level (WinThreshold = 2016)
        ForestMode      = 'WinThreshold'
        OuRoot          = 'Lab'             # OU=Lab with Admins, Users, Groups, Servers, Workstations below it
        CACommonName    = ''                # '' = <NetBiosName>-ROOT-CA
        CAValidityYears = 10
    }

    Network = @{
        SwitchName   = 'LAB-Isolated'
        SwitchType   = 'Private'            # Private = fully isolated; Internal = the host can reach the VMs (tester decides)
        Prefix       = '10.10.10'           # first three octets of the /24 lab network
        PrefixLength = 24
    }

    # Empty = taken from the Hyper-V host at build time (ADR 0010). UILanguage empty = language of the Windows image.
    Locale = @{
        UILanguage   = ''
        InputLocale  = ''
        SystemLocale = ''
        UserLocale   = ''
        TimeZone     = ''
    }

    # OS catalog (ADR 0013). Each VM uses one key: domain controllers / member servers 'Image' (default DefaultServerImage),
    # all workstations Workstations.Image. ISOs and base images go into the shared image library (Paths.LibraryRoot).
    Iso = @{
        AllowedDownloadHosts = @(
            'software-static.download.prss.microsoft.com'
            'software-download.microsoft.com'
            'download.microsoft.com'
        )
        DefaultServerImage = 'Server2025'
        Images = @{
            Server2025 = @{
                Kind             = 'Server'
                Description      = 'Windows Server 2025 Evaluation (en-US)'
                SourcePage       = 'https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025'
                Url              = 'https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us'
                FileName         = 'WindowsServer2025-Eval-x64-en-us.iso'
                ExpectedSha256   = ''       # optional; set to pin an exact build
                ImageNamePattern = '*Standard*Desktop*'
                CaptionPattern   = '*Windows Server 2025*'
            }
            Server2022 = @{
                Kind             = 'Server'
                Description      = 'Windows Server 2022 Evaluation (en-US)'
                SourcePage       = 'https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022'
                Url              = 'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US'
                FileName         = 'WindowsServer2022-Eval-x64-en-us.iso'
                ExpectedSha256   = ''
                ImageNamePattern = '*Standard*Desktop*'
                CaptionPattern   = '*Windows Server 2022*'
            }
            Server2019 = @{
                Kind             = 'Server'
                Description      = 'Windows Server 2019 Evaluation (en-US)'
                SourcePage       = 'https://www.microsoft.com/en-us/evalcenter/download-windows-server-2019'
                Url              = 'https://go.microsoft.com/fwlink/p/?LinkID=2195167&clcid=0x409&culture=en-us&country=US'
                FileName         = 'WindowsServer2019-Eval-x64-en-us.iso'
                ExpectedSha256   = ''
                ImageNamePattern = '*Standard*Desktop*'
                CaptionPattern   = '*Windows Server 2019*'
            }
            Win11LTSC = @{
                Kind             = 'Client'
                Description      = 'Windows 11 Enterprise LTSC Evaluation (en-US)'
                SourcePage       = 'https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise'
                Url              = 'https://go.microsoft.com/fwlink/?linkid=2289029&clcid=0x409&culture=en-us&country=us'
                FileName         = 'Windows11-EnterpriseLTSC-Eval-x64-en-us.iso'
                ExpectedSha256   = ''
                ImageNamePattern = 'Windows 11 Enterprise LTSC*'
                CaptionPattern   = '*Windows 11*LTSC*'
            }
            # No Microsoft evaluation exists any more (Windows 10 end of support Oct 2025): the tester supplies the ISO
            # (e.g. Windows 10 Enterprise LTSC 2021); SourcePath = that file on the host. Copied into the library.
            Win10 = @{
                Kind             = 'Client'
                Description      = 'Windows 10 Enterprise (ISO supplied by the tester)'
                Supplied         = $true
                SourcePath       = ''
                FileName         = 'Windows10-supplied.iso'
                ExpectedSha256   = ''
                ImageNamePattern = 'Windows 10 Enterprise*'
                CaptionPattern   = '*Windows 10 Enterprise*'
            }
        }
    }

    BaseDiskSizeBytes = 32GB                # base image; each VM gets a dynamic copy expanded to DiskSizeBytes

    # 1..5 domain controllers. The first creates the forest; the others join it. Roles: ADCS, IIS, DHCP, FileServer.
    # Optional per server: Image = 'Server2025' | 'Server2022' | 'Server2019' (default Iso.DefaultServerImage).
    DomainControllers = @(
        @{ Name = 'DC01'; HostOctet = 10; ProcessorCount = 2; MemoryBytes = 4GB; DiskSizeBytes = 80GB; Roles = @('ADCS'); AdditionalFeatures = @() }
    )

    # 0..10 domain-joined member servers. Roles: ADCS (max 1 in the lab), IIS, DHCP (max 1), FileServer,
    # SQL (SQL Server Express, member servers only - not supported on domain controllers; settings in Roles.SQL).
    # AdditionalFeatures: any Install-WindowsFeature names.
    MemberServers = @(
        @{ Name = 'IIS01'; HostOctet = 20; ProcessorCount = 2; MemoryBytes = 4GB; DiskSizeBytes = 80GB; Roles = @('IIS'); AdditionalFeatures = @() }
    )

    # 0..20 workstations named <NamePrefix>01, 02, ... with IPs from FirstHostOctet. Image: Win11LTSC or Win10 (tester ISO).
    Workstations = @{
        Image          = 'Win11LTSC'
        Count          = 1
        NamePrefix     = 'WS'
        FirstHostOctet = 101
        ProcessorCount = 2
        MemoryBytes    = 4GB
        DiskSizeBytes  = 80GB
    }

    Accounts = @{
        DomainAdminCount        = 1         # dedicated domain admin accounts adm.<first>.<last> (0..10)
        TestUserCount           = 3         # random domain test users (0..100)
        PasswordLength          = 16
        UpnSuffix               = ''        # '' = domain FQDN
        TestUsersAreLocalAdmins = $false    # $true = first group (testers) in local Administrators on workstations
    }

    # Security groups; every test user is a member of the first one.
    Groups = @(
        @{ Name = 'SG-Lab-Testers';   Description = 'All lab test users' }
        @{ Name = 'SG-Lab-WebAdmins'; Description = 'IIS content administrators' }
        @{ Name = 'SG-Lab-Finance';   Description = 'Sample department group' }
        @{ Name = 'SG-Lab-HR';        Description = 'Sample department group' }
    )

    # Settings of the role catalog (ADR 0009).
    Roles = @{
        IIS = @{
            Features            = @('Web-Server', 'Web-Mgmt-Console', 'Web-Windows-Auth', 'Web-Http-Redirect')
            EnableHttps         = $true     # certificate from the lab CA (needs an ADCS server)
            CertificateTemplate = 'WebServer'
        }
        DHCP = @{
            RangeStartOctet = 200
            RangeEndOctet   = 250
        }
        FileServer = @{
            ShareName = 'LabShare'
            Path      = 'C:\Shares\LabShare'
        }
        # SQL Server Express, unattended (ADR 0012). Media: the official web installer is downloaded on the host
        # (phase Iso) and fetches the offline package SQLEXPR_x64_ENU.exe into <Library>\ISO\SQL; both must be
        # Authenticode-signed by Microsoft. The lab VMs never need internet access.
        SQL = @{
            Description        = 'SQL Server 2025 Express (en-US)'
            SourcePage         = 'https://www.microsoft.com/en-us/sql-server/sql-server-downloads'
            BootstrapperUrl    = 'https://go.microsoft.com/fwlink/p/?linkid=2216019&clcid=0x409&culture=en-us&country=us'
            MediaType          = 'Core'            # web installer /MEDIATYPE (Core = database engine package)
            PackagePattern     = 'SQLEXPR*.exe'    # offline package produced by the web installer
            InstanceName       = 'SQLEXPRESS'      # MSSQLSERVER = default instance
            TcpPort            = 1433              # static TCP port, firewall rule added
            AuthenticationMode = 'Windows'         # Windows | Mixed (sa enabled, generated password in lab-sql.csv)
            SysadminGroups     = @()               # lab groups made sysadmin; Domain Admins always are
            DatabaseName       = 'LabDB'           # test database to create; '' = none
            DbOwnerGroups      = @('SG-Lab-Testers')   # lab groups made db_owner of DatabaseName
            Collation          = ''                # '' = SQL Setup default for the server locale
            SetupTimeoutMinutes = 45
        }
    }

    Timeouts = @{
        VmReadyMinutes = 30
        AdReadyMinutes = 20
    }
}
