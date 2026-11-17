# Architecture — Build TEST environment

## 1. Overview

```
 Dedicated Hyper-V host
 ├─ %ProgramData%\LabBuilder\settings.json   App / Labs / Library folders, registered 1.0-1.3 labs (ADR 0015)
 ├─ LabBuilderSetup.exe (wizard, elevated): Folders -> Start (new | edit | delete | library) -> lab pages -> build
 │        │ writes <Labs>\<Lab>\lab.config.psd1 (tester choices; BaseConfig = <App>\config\lab.config.example.psd1)
 │        ▼
 │  <App>\scripts\Invoke-LabBuild.ps1 [-LabName]  ──▶ LabBuilder module (phases)
 │  <App>\scripts\Get-LabInventory.ps1 (labs + library JSON), Remove-Lab.ps1 -LabName
 │
 ├─ <Labs>\<Lab>\          one folder per lab: lab.config.psd1, lab.json, state.json, VMs\, Logs\, Reports\, output\ (credentials)
 │
 ├─ <Library>\ISO          image library, SHARED BY ALL LABS (ADR 0013): evaluation ISOs + iso-manifest.json (SHA-256), SQL\
 ├─ <Library>\BaseImages   <OS>.vhdx per OS (Server2025/2022/2019, Win11LTSC, Win10; 32 GB, read-only) + .json (version, language, ISO SHA-256)
 ├─ <LabRoot>\VMs\<VM>      per-VM DYNAMIC VHDX (copy of the base of its OS, expanded to the tester's size)
 ├─ <LabRoot>\Logs|Reports  host log, validation reports, state.json
 ├─ <LabRoot>\lab.json      lab manifest (name, version, folders, switch, VMs + OS); VM notes "LabBuilder:<LabName> | ..."
 │
 └─ Hyper-V switch "LAB-Isolated"  (Private by default; Internal if the tester chooses)   <prefix>.0/24
      ├─ DC01 .10  AD DS + DNS (forest root) [+ ADCS | IIS | DHCP | FileServer]   Server 2025/2022/2019
      ├─ DC0n .1n  AD DS + DNS (additional DC, GC) [+ roles]           (1..5 DCs)
      ├─ SRVxx .2x member server [+ ADCS | IIS | DHCP | FileServer | SQL | extra features]   (0..10)
      └─ WSnn .101.. Windows 11 Enterprise LTSC or Windows 10 Enterprise (tester ISO), domain member   (0..20)

 Host ──PowerShell Direct (VMBus, no network)──▶ every VM
```

Decisions: execution [ADR 0007](adr/0007-run-directly-on-the-hyper-v-host.md), ISOs [0003](adr/0003-iso-source-and-verification.md),
base image [0004](adr/0004-vm-build-from-base-vhdx.md), dynamic disks [0008](adr/0008-per-vm-dynamic-disks.md),
network [0005](adr/0005-isolated-private-network.md), secrets [0006](adr/0006-lab-secrets-handling.md),
topology and roles [0009](adr/0009-tester-defined-topology-and-role-catalog.md), locale [0010](adr/0010-locale-from-hyper-v-host.md),
wizard [0011](adr/0011-wizard-installer-exe.md), SQL Server [0012](adr/0012-sql-server-express-role.md),
image library + OS choice + lab manifest [0013](adr/0013-shared-image-library-and-os-choice.md),
parallel build + differencing disks + progress [0014](adr/0014-parallel-build-differencing-disks-progress.md),
lab manager [0015](adr/0015-lab-manager-folders-and-start-page.md), role-ready images [0016](adr/0016-role-ready-base-images.md), AVMA activation [0017](adr/0017-avma-server-activation.md).

## 2. Components

| Path | Purpose |
|------|---------|
| `installer/src/*.cs`, `installer/app.manifest` | Wizard (.NET Framework 4.8 WinForms, C# 5): pages, prerequisite check, psd1 writer/reader, process runner, embedded payload |
| `installer/build.ps1` | Zips the payload, compiles `LabBuilderSetup.exe` with inbox `csc.exe` (icon + ITOM mark from `installer/branding`) |
| `installer/branding/`, `installer/src/Brand.cs` | ITOM Solutions mark, icon and colours (same as the IT Portal branding) |
| `scripts/Publish-LabRelease.ps1` | Maintainer release: checks, tests, exe build, commit, tag, GitHub release |
| `scripts/Invoke-LabBuild.ps1` | Entry point: config, secrets, account plan, phases, summary |
| `scripts/Test-LabConfigFile.ps1` | Validation + resolved host locale (wizard uses it) |
| `scripts/Get-LabIso.ps1`, `scripts/Remove-Lab.ps1` | Pre-download, teardown (`-LabName`: delete a lab from the inventory) |
| `scripts/Get-LabInventory.ps1` | Lab manager back end: host settings, labs, image library as JSON; save folders, register 1.0-1.3 labs, restore/rebuild a lost config (ADR 0015) |
| `src/LabBuilder/Public/LabManager.ps1` | Host settings, `Get-LabInventory`, `Get-LabLibraryInventory`, `Get-LabOutputPath`, `Restore-LabLegacyConfig`, `New-LabConfigFromInventory`, `Remove-LabFromInventory` |
| `src/LabBuilder/Public/RoleImages.ps1` | Role-ready base images `<OS>-Roles.vhdx` for DCs (AD DS + DNS enabled offline with DISM, no sysprep, feature set in the sidecar), fallback, removal of unconfigured AD CS before promotion (ADR 0016) |
| `src/LabBuilder/Public/Activation.ps1` | AVMA: host check, offline edition conversion of Windows Server base images (Evaluation -> Standard, sidecar `Edition`), AVMA key + `slmgr /ato` in every server VM (ADR 0017) |
| `installer/src/LabManagerPages.cs` | Wizard pages Folders, Start, Delete lab, Image library; edit/new mode logic |
| `config/lab.config.example.psd1` | Schema v2 defaults (topology, roles, ISO links) |
| `src/LabBuilder/Public/Config.ps1` | Load (BaseConfig layering, overrides), validate, topology → VM definitions |
| `src/LabBuilder/Public/Secrets.ps1` | Passwords, account plan (domain admins + test users), file ACL, unattend encoding |
| `src/LabBuilder/Public/Iso.ps1`, `Private/Download.ps1` | Download, import, manifest, verification |
| `src/LabBuilder/Public/HostSetup.ps1` | Preflight, base VHDX per OS in the library (+ image language, ISO hash, 1.0/1.1 adoption), switch |
| `src/LabBuilder/Public/Library.ps1` | Image library root, host-wide named-mutex lock per item, 1.0/1.1 media migration, tester-supplied ISO import, `lab.json` manifest, VM note tag (ADR 0013) |
| `src/LabBuilder/Private/Parallel.ps1` | `Invoke-LabParallel` (runspace pool, module-bound script blocks, live relay of host output/warnings, per-item logs, error summary), throttle and on/off from `Build.*` (ADR 0014) |
| `src/LabBuilder/Public/VM.ps1`, `Private/VMHelpers.ps1` | Dynamic disk copy/resize/partition extend, unattend + locale, VM creation; PowerShell Direct helpers |
| `src/LabBuilder/Public/Unattend.ps1` | unattend rendering, `Resolve-LabLocale` |
| `src/LabBuilder/Public/Roles.ps1` | Forest + additional DCs, AD content, member servers, role catalog, workstations |
| `src/LabBuilder/Public/SqlServer.ps1` | Role SQL: media download/import with Microsoft signature check, unattended SQL Setup, port/firewall/logins/test database (ADR 0012) |
| `src/LabBuilder/Public/Validation.ps1` | Post-build checks and report |
| `src/LabBuilder/Public/Phase.ps1` | Phase dispatcher, state, teardown |
| `tests/LabBuilder.Tests.ps1` | Pester unit tests |

## 3. Build phases

| # | Phase | What it does | Idempotency check |
|---|-------|--------------|-------------------|
| 1 | `Preflight` | Elevation, OS ≥ 17763, Hyper-V, DISM/Storage, `bcdboot`, vTPM cmdlets, free disk (lab + library drive), free RAM (warn); creates lab and library folders | read-only |
| 2 | `Iso` | Move 1.0/1.1 media from `<LabRoot>\ISO` into the library; import `-IsoSource`; download missing ISOs of the OSes in use; copy the tester's Windows 10 ISO; verify; with role SQL: SQL Express offline package via the Microsoft web installer (signature-checked) into `<Library>\ISO\SQL` — each item under a host-wide lock | manifest; `sql-media.json` + signature |
| 3 | `BaseImages` | Per OS in use: adopt a 1.0/1.1 base of this lab, else keep the library base, else build a 32 GB GPT base VHDX from `install.wim`; record version, language, ISO SHA-256; rebuild if the ISO changed — under a host-wide lock | base exists + ISO hash |
| 4 | `Network` | Private/Internal switch | switch exists with type |
| 5 | `DomainControllers` | Create all DC VMs **in parallel** → forest root (`Install-ADDSForest`) → OUs `Lab\{Admins,Users,Groups,Servers,Workstations}`, groups, domain admins (RID 512), test users → additional DCs (`Install-ADDSDomainController`) → DNS client order → DC roles (CA first) | DomainRole ≥ 4; AD lookups; CA `Active` value |
| 6 | `MemberServers` | Create all **in parallel** → CA server(s) first, then **all other servers in parallel**: IP/DNS → join `OU=Servers` → roles ADCS → DHCP → FileServer → IIS (+HTTPS) → SQL → extra features | PartOfDomain; per-role checks; SQL service exists |
| 7 | `Workstations` | Create all **in parallel** → **all in parallel**: IP/DNS → join `OU=Workstations` → optional testers in local Administrators → `gpupdate` | PartOfDomain; membership |
| 8 | `Validate` | Host: switch type, VM state, vCPU/RAM, **dynamic disk size**, adapters; **OS of every VM** (catalog `CaptionPattern`); DCs: domain, all DCs present, services, replication; accounts (+Domain Admins), groups, DNS; roles; workstations (LTSC, membership, local admins); SQL servers (service, TCP, firewall, edition, auth mode, sysadmins, test database); client: HTTP/HTTPS per IIS, file share read, SQL over TCP (Windows auth, sa in Mixed mode), LDAP bind of a test user and a domain admin | read-only |

## 4. Role catalog

| Role | Max | Deployed | Validated |
|------|-----|----------|-----------|
| AD DS + DNS | every DC | forest root / additional DC | services, DC list, replication |
| `ADCS` | 1 | Enterprise Root CA, RSA 4096/SHA-256 | CertSvc, `certutil -ping`, AD publication |
| `IIS` | any | features, `/lab-health.html`, `WebServer` cert + HTTPS (if CA) | W3SVC, cert issuer, GET from client |
| `DHCP` | 1 | authorised, scope `<prefix>.<start-end>`, DNS options | service, authorisation, scope active |
| `FileServer` | any | `\\<server>\<share>` Change: first group, Full: Domain Admins | share exists, readable from client |
| `SQL` | any member server (not DCs) | SQL Server 2025 Express engine, unattended; instance, static TCP port + firewall, Windows/Mixed auth, sysadmin groups, test database with `db_owner` groups and `dbo.LabCheck`, collation (ADR 0012) | service, TCP listener, edition, auth mode, sysadmins, database + row, remote query from client |
| extra features | any | `Install-WindowsFeature` | install success |

## 5. Identity and credentials

| Account | Where | Used for |
|---------|-------|----------|
| `<VM>\Administrator` / `<VM>\LabAdmin` | servers / workstations (Windows 10/11) before join | PowerShell Direct during setup |
| `<NETBIOS>\Administrator` | domain | promotion, roles, joins, validation |
| `adm.<first>.<last>` × N | `OU=Admins`, Domain Admins | dedicated admin accounts for testers |
| `<first>.<last>` × N | `OU=Users`, first group + random | test users |

| `sa` (SQL login) | SQL servers, Mixed mode only | SQL authentication tests |

All generated passwords: `output\<LabName>\lab-accounts.csv` and (SQL Mixed mode) `lab-sql.csv` (ACL: current user + SYSTEM); lab admin: DPAPI `lab-admin.cred.xml`.
The wizard passes an entered admin password to the build via **stdin** only (ADR 0011).

## 6. Requirements traceability

| Requirement | Implemented in |
|-------------|----------------|
| FR-1..FR-4 | `Save-LabIso`, `Import-LabIso`, `Resolve-LabDownloadUrl`, `Get-LabIso.ps1` |
| FR-5 | `New-LabNetwork`, wizard Network page |
| FR-6, FR-7, FR-8 | `Install-LabDomainController`, `Install-LabServerRole`, `New-LabAccountPlan` |
| FR-9, FR-10 | `Install-LabMemberServer`, `Install-LabServerRole` |
| FR-11 | `Install-LabWorkstation` |
| FR-12 | `Test-LabEnvironment` |
| FR-13 | `Invoke-LabBuild.ps1` output folder |
| FR-14 | idempotent phases, `-Phase`, wizard re-run |
| FR-15 | `Remove-Lab.ps1` |
| FR-16 | ADR 0007, preflight |
| FR-17 | `Resolve-LabLocale`, base image language |
| FR-18, FR-19 | `installer/` wizard, `Test-LabConfigFile.ps1`, BaseConfig layering |
| FR-20 | `SqlServer.ps1` (`Save-LabSqlMedia`, `Install-LabSqlServer`), `Test-LabSqlConfig`, SQL checks in `Test-LabEnvironment`, wizard page SQL Server |
| FR-21 | `Library.ps1` (`Get-LabLibraryRoot`, `Invoke-LabLibraryLock`, `Move-LabLegacyMedia`, `Import-LabSuppliedIso`), `Save-LabIso`, `New-LabBaseImage` |
| FR-22 | OS catalog `Iso.Images`, `Get-LabVmDefinition` (Image, Kind), `Test-LabConfig`, OS check in `Test-LabEnvironment`, wizard OS columns / workstation OS |
| FR-23 | `Write-LabManifest` (after every phase), `Get-LabVmNote` in `New-LabVM` |
| FR-24 | `Invoke-LabParallel`; parallel phases Iso, BaseImages, `New-LabVMSet`, `Initialize-LabMemberServer`, `Initialize-LabWorkstation`; locks VhdMount / CertTemplate / log writes |
| FR-25 | `Disks.Type`, `New-LabVM` (differencing branch), `Get-LabBaseImageUser` (protection in base rebuild and `Remove-LabEnvironment`), validation disk check |
| FR-26 | `Write-LabProgress` (`progress.jsonl`, `##LBP` lines), wizard Build page VM list |
| FR-27..FR-30 | `LabManager.ps1`, `Get-LabInventory.ps1`, `Invoke-LabBuild.ps1 -LabName`, `Remove-Lab.ps1 -LabName`, `LabManagerPages.cs`, `Paths.OutputPath` |
| FR-31 | `RoleImages.ps1` (`New-LabRoleBaseImageItem`, `Get-LabVmBaseImageKey`), phase BaseImages, `Install-LabDomainController` (other VMs during the promotion) |
| dynamic disks (IN-6/7/12) | `New-LabVM` (copy + `Resize-VHD` + `Resize-Partition`), validation |
