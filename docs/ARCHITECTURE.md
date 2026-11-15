# Architecture — Build TEST environment

## 1. Overview

```
 Dedicated Hyper-V host
 ├─ LabBuilderSetup.exe (wizard, elevated) ──writes──▶ <install>\config\lab.config.psd1
 │        │ runs                                            (tester choices; BaseConfig = example)
 │        ▼
 │  <install>\scripts\Invoke-LabBuild.ps1  ──▶ LabBuilder module (phases)
 │
 ├─ <LabRoot>\ISO           evaluation ISOs + iso-manifest.json (SHA-256)
 ├─ <LabRoot>\BaseImages    <Lab>-Server-base.vhdx, <Lab>-Client-base.vhdx (32 GB, read-only) + .json (version, language)
 ├─ <LabRoot>\VMs\<VM>      per-VM DYNAMIC VHDX (copy of base, expanded to the tester's size)
 ├─ <LabRoot>\Logs|Reports  host log, validation reports, state.json
 │
 └─ Hyper-V switch "LAB-Isolated"  (Private by default; Internal if the tester chooses)   <prefix>.0/24
      ├─ DC01 .10  AD DS + DNS (forest root) [+ ADCS | IIS | DHCP | FileServer]
      ├─ DC0n .1n  AD DS + DNS (additional DC, GC) [+ roles]           (1..5 DCs)
      ├─ SRVxx .2x member server [+ ADCS | IIS | DHCP | FileServer | SQL | extra features]   (0..10)
      └─ WSnn .101.. Windows 11 Enterprise LTSC, domain member         (0..20)

 Host ──PowerShell Direct (VMBus, no network)──▶ every VM
```

Decisions: execution [ADR 0007](adr/0007-run-directly-on-the-hyper-v-host.md), ISOs [0003](adr/0003-iso-source-and-verification.md),
base image [0004](adr/0004-vm-build-from-base-vhdx.md), dynamic disks [0008](adr/0008-per-vm-dynamic-disks.md),
network [0005](adr/0005-isolated-private-network.md), secrets [0006](adr/0006-lab-secrets-handling.md),
topology and roles [0009](adr/0009-tester-defined-topology-and-role-catalog.md), locale [0010](adr/0010-locale-from-hyper-v-host.md),
wizard [0011](adr/0011-wizard-installer-exe.md).

## 2. Components

| Path | Purpose |
|------|---------|
| `installer/src/*.cs`, `installer/app.manifest` | Wizard (.NET Framework 4.8 WinForms, C# 5): pages, prerequisite check, psd1 writer/reader, process runner, embedded payload |
| `installer/build.ps1` | Zips the payload, compiles `LabBuilderSetup.exe` with inbox `csc.exe` (icon + ITOM mark from `installer/branding`) |
| `installer/branding/`, `installer/src/Brand.cs` | ITOM Solutions mark, icon and colours (same as the IT Portal branding) |
| `scripts/Publish-LabRelease.ps1` | Maintainer release: checks, tests, exe build, commit, tag, GitHub release |
| `scripts/Invoke-LabBuild.ps1` | Entry point: config, secrets, account plan, phases, summary |
| `scripts/Test-LabConfigFile.ps1` | Validation + resolved host locale (wizard uses it) |
| `scripts/Get-LabIso.ps1`, `scripts/Remove-Lab.ps1` | Pre-download, teardown |
| `config/lab.config.example.psd1` | Schema v2 defaults (topology, roles, ISO links) |
| `src/LabBuilder/Public/Config.ps1` | Load (BaseConfig layering, overrides), validate, topology → VM definitions |
| `src/LabBuilder/Public/Secrets.ps1` | Passwords, account plan (domain admins + test users), file ACL, unattend encoding |
| `src/LabBuilder/Public/Iso.ps1`, `Private/Download.ps1` | Download, import, manifest, verification |
| `src/LabBuilder/Public/HostSetup.ps1` | Preflight, base VHDX (+ image language), switch |
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
| 1 | `Preflight` | Elevation, OS ≥ 17763, Hyper-V, DISM/Storage, `bcdboot`, vTPM cmdlets, free disk, free RAM (warn) | read-only |
| 2 | `Iso` | Import `-IsoSource`; download missing ISOs (only images in use); verify; with role SQL: SQL Express offline package via the Microsoft web installer (signature-checked) into `ISO\SQL` | manifest; `sql-media.json` + signature |
| 3 | `BaseImages` | 32 GB GPT base VHDX from `install.wim`; record version + language | base exists |
| 4 | `Network` | Private/Internal switch | switch exists with type |
| 5 | `DomainControllers` | Create all DC VMs → forest root (`Install-ADDSForest`) → OUs `Lab\{Admins,Users,Groups,Servers,Workstations}`, groups, domain admins (RID 512), test users → additional DCs (`Install-ADDSDomainController`) → DNS client order → DC roles (CA first) | DomainRole ≥ 4; AD lookups; CA `Active` value |
| 6 | `MemberServers` | Create all → per server (CA server first): IP/DNS → join `OU=Servers` → roles ADCS → DHCP → FileServer → IIS (+HTTPS) → SQL → extra features | PartOfDomain; per-role checks; SQL service exists |
| 7 | `Workstations` | Create all → IP/DNS → join `OU=Workstations` → optional testers in local Administrators → `gpupdate` | PartOfDomain; membership |
| 8 | `Validate` | Host: switch type, VM state, vCPU/RAM, **dynamic disk size**, adapters; DCs: domain, all DCs present, services, replication; accounts (+Domain Admins), groups, DNS; roles; workstations (LTSC, membership, local admins); SQL servers (service, TCP, firewall, edition, auth mode, sysadmins, test database); client: HTTP/HTTPS per IIS, file share read, SQL over TCP (Windows auth, sa in Mixed mode), LDAP bind of a test user and a domain admin | read-only |

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
| `<VM>\Administrator` / `<VM>\LabAdmin` | servers / Windows 11 before join | PowerShell Direct during setup |
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
| dynamic disks (IN-6/7/12) | `New-LabVM` (copy + `Resize-VHD` + `Resize-Partition`), validation |
