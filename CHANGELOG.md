# Changelog

All notable changes to this project are documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.4.1] — 2026-11-17

### Added
- **Faster domain controllers** (FR-31, ADR 0016):
  - **Role-ready base images** `<Library>\BaseImages\<OS>-Roles.vhdx`: a copy of the plain base with **AD DS and DNS** enabled
    **offline** (DISM), built once per server OS used by a domain controller and shared by all labs. Never booted and **not
    sysprepped** - Microsoft does not support sysprep with AD DS / AD CS installed. Domain controllers start from it; the online
    AD DS install then takes seconds (and still adds anything missing). If the image cannot be built, a warning is logged and the
    plain base is used as before. **AD CS is not in the image** (a server with AD CS binaries cannot be promoted - found in the
    host test); the CA is installed online after the promotion as before.
  - **Member-server and workstation VMs are created while the forest is promoted**, so their first boot is done when the domain is ready.
  - Option `Build.RoleImages` (default on; wizard *Build options*: "Faster domain controllers").
- The image library view lists the role images (current, or made from an older base / older feature set, differencing users).

### Changed
- `Remove-Lab.ps1 -IncludeLibrary` also removes the role images of the lab's operating systems (unless differencing disks use them).

### Fixed
- Before a DC promotion, AD CS binaries without a configured CA are removed (VMs created from the first 1.4.1 test image could not be
  promoted: "Certificate Server is installed"); role images with that older feature set are rebuilt or, while in use, not used.
- Per-VM logs no longer mix VMs when the parallel engine reuses a worker (`vm-FILE01.log` contained WS03's lines).
- Config check: an additional domain controller may not run a newer Windows Server than DC 1 (the forest root). Promoting a Server 2025
  DC into a forest with a Server 2022 root failed in adprep ("Adprep was unable to bind to any Domain Controller over RPC"); the wizard
  now stops at the Summary page with "Put the newest Windows Server on DC 1", and the DC page says so.

## [1.4.0] — 2026-11-15

### Added
- **Lab manager** (FR-27..FR-30, ADR 0015, requester redesign):
  - **First run:** a *Folders* page sets the **App, Labs and Library folders** (`%ProgramData%\LabBuilder\settings.json`; defaults
    `C:\LabBuilder`, `<data drive>:\LabBuilder-Labs`, `<data drive>:\LabBuilder-Library`); *Change folders...* later.
  - **Start page:** *Create a new lab*, *Edit an existing lab*, *Delete a lab*, *Show the image library*, with the list of labs on
    the host (domain, VMs and how many run, disk type, last phase, size, folder).
  - **One folder per lab** `<Labs folder>\<LabName>\` with its own `lab.config.psd1`, VMs, logs, reports and `output\` (credentials) -
    labs no longer share `<App>\config\lab.config.psd1` (a second lab overwrote the first one's settings).
  - **Edit:** loads the lab's own config; name, domain, network and disk type are fixed; add servers, workstations and roles; build
    again (finished work is skipped). Removed rows are not deleted.
  - **Delete:** preview of everything that goes, confirmation by typing the lab name; VMs (from lab.json and every VM tagged
    `LabBuilder:<Lab>`), checkpoints, disks, switch if unused, the lab's files and folder, its credentials; never the image library.
  - **Image library view:** per OS the ISO (size, date) and base image (Windows build, date, built from the current ISO or not, VMs
    whose differencing disks use it) plus unknown ISO files in the library folder.
  - **Labs from 1.0-1.3** (e.g. in `D:\HyperVLab`) are found through their tagged VMs and **registered in place** (decision D7). Their
    config is **restored** from the old shared config or the wizard's `.bak-<time>` copies when one matches the lab's name and folder,
    otherwise **rebuilt** from `lab.json` + Hyper-V (names, OS, IPs, sizes) - roles and NetBIOS name are then confirmed in the wizard.
- `scripts/Get-LabInventory.ps1` (labs + library as JSON), `Invoke-LabBuild.ps1 -LabName`, `Remove-Lab.ps1 -LabName [-Force]`.
- Config `Paths.OutputPath` (credentials/summary/reports folder; '' = `<App>\output\<Lab>` as before).

### Changed
- Wizard page *Install & lab* is now *Lab* (lab name + build options; app, lab and library paths come from the host settings).
- The host conflict check also looks at the lab's own output folder.

## [1.3.0] — 2026-11-15

### Added
- **Parallel build** (FR-24, ADR 0014): ISO downloads, base images (per OS), creation of all VMs, member servers (after the CA
  server) and all workstations run in parallel - runspace-pool engine for Windows PowerShell 5.1 with live, VM-prefixed log lines,
  a per-VM log (`<LabRoot>\Logs\vm-<name>.log`), a host-sized throttle (`Build.ThrottleLimit`, 0 = auto) and an error summary of
  every failed VM (the others finish; a re-run resumes). Forest root and additional DCs stay sequential. `Build.Parallel = $false`
  or the wizard option builds one VM at a time.
- **Differencing disks as an option** (FR-25, decision D5): `Disks.Type = 'Differencing'` (wizard: Build options) creates each VM
  disk as a differencing VHDX on its library base image (seconds, small). Base images used by differencing disks are never rebuilt
  or deleted (`Remove-Lab.ps1 -IncludeLibrary` keeps them); validation accepts the disk type; `lab.json` records it. Default stays
  independent dynamic copies.
- **Live VM progress** (FR-26): progress events per VM and step in `<LabRoot>\Logs\progress.jsonl` and `##LBP` lines; the wizard's
  Build page shows a **Virtual machines** list (creating / starting / configuring / joining / roles / promoting / ready / failed).

### Changed
- Locks so parallel work cannot collide: log writes, one VHD mount at a time (copies of one base share the GPT disk GUID),
  certificate-template ACL change (concurrent IIS servers). Unique temp file for the ESP fallback when base images build in parallel.

## [1.2.0] — 2026-11-15

### Added
- **Operating system per VM** (FR-22, ADR 0013): each domain controller and member server runs **Windows Server 2025, 2022 or
  2019** (Evaluation Center ISOs, Standard Desktop Experience); workstations run **Windows 11 Enterprise LTSC** or **Windows 10
  Enterprise from an ISO the tester supplies** (Microsoft no longer offers a Windows 10 evaluation). Wizard: OS column in both
  server grids, OS choice + ISO browse on the Workstations page; the ISO page lists exactly the ISOs the lab needs.
- **Shared image library** (FR-21): `Paths.LibraryRoot` (default `<LabRoot drive>:\LabBuilder-Library`, wizard field) holds the
  ISOs and **one base image per OS** for all labs on the host; a base image is rebuilt only when its ISO changes; a host-wide
  lock per item stops two builds from downloading/building the same thing. Media of 1.0/1.1 labs (`<LabRoot>\ISO`,
  `<LabRoot>\BaseImages`) is moved into the library automatically — nothing is downloaded again.
- **Lab manifest** (FR-23): `<LabRoot>\lab.json` (name, version, folders, switch, domain, VMs with OS; no secrets), updated after
  every phase; every VM's notes start with `LabBuilder:<LabName>` (also added to VMs of existing labs) — groundwork for lab
  discovery (1.4.0).
- Validation checks the **OS of every VM**; the lab summary lists the OS per VM and the library folder.
- `Get-LabIso.ps1 -Image Server2025, Server2022, Server2019, Win11LTSC` (default: the OSes the config uses).
- **Host conflict check** (`Test-LabHostConflict`): the wizard's Summary page and `Invoke-LabBuild.ps1` stop **before any work**
  when another lab on the host already uses the same lab name with another domain, the same lab folder, or the same switch,
  with a message saying what to change (found in the tester's 1.2.0 run: same lab name, new domain).

### Fixed
- Windows feature installs (AD DS, AD CS, DHCP, File Server, IIS, extra features) survive a freshly deployed VM that is still
  servicing: on errors such as `0x80071A2D` ("transaction that is no longer active" / "request to list features ... failed")
  the VM is restarted and the install retried (up to 3 times) — seen on the forest root DC in the tester's 1.2.0 run.
- New forest: "Active Directory ready" now also requires DC discovery (`Get-ADDomainController -Discover -Service ADWS`, default
  `Get-ADDomain`) twice in a row, not only the local ADWS — the account step failed with "Unable to find a default server with
  Active Directory Web Services running" (tester run 3); that step also retries longer (5 × 30 s). AD module warnings about the
  default `AD:` drive are no longer printed (the drive stays on where it is used - the certificate template ACL step).

### Changed
- Config: `Iso.Images` is now the OS catalog (`Server2025`, `Server2022`, `Server2019`, `Win11LTSC`, `Win10`, each with `Kind`
  and `CaptionPattern`), `Iso.DefaultServerImage`, optional `Image` per server, `Workstations.Image`, `Paths.LibraryRoot`.
  Wizard configs (BaseConfig) keep working; a stand-alone config with the old `Server`/`Client` keys gets a clear error.
- `Remove-Lab.ps1`: `-IncludeLibrary` (aliases `-IncludeBaseImages`, `-IncludeIso`) deletes only the library items this lab
  uses; `lab.json` is removed with the lab.
- `scripts/Publish-LabRelease.ps1` writes the release notes without a UTF-8 BOM.

## [1.1.1] — 2026-11-15

### Added
- Wizard branding **ITOM Solutions** ([www.itomsol.com](https://www.itomsol.com)): ITOM mark and "by ITOM Solutions" in the
  side panel, brand colours (ink `#111A24`, lime `#C6F277`), accent line, website link, tagline and version; exe icon and
  file properties (company, copyright). Same mark and colours as the IT Portal product branding.
- `scripts/Publish-LabRelease.ps1` (maintainers): checks version/tag/CHANGELOG and staged files, runs the tests, builds the exe,
  commits, tags and creates the GitHub release (`-WhatIf` for a dry run).
- `docs/ROADMAP.md`: planned versions up to 3.0.0 and the requester's decisions.

### Changed
- The wizard opens **maximised** and stays freely resizable; notes wrap to the window width, grids and lists stretch, side panel,
  header and step list are sized from the measured text (no clipping at high display scaling). The **SQL Server** page is shown
  only when a member server has role SQL.
- Default lab: **1 workstation** (was 3); the RAM estimate is now ~12 GB.

## [1.1.0] — 2026-11-14

### Added
- **Role SQL — SQL Server 2025 Express, unattended** on member servers (FR-20, ADR 0012): media from Microsoft's web installer
  in download mode on the host (Authenticode signature checked, `ISO\SQL\sql-media.json`), copied into the VM over PowerShell
  Direct, Setup from a configuration file that is deleted afterwards (no password on a command line).
- Tester SQL options (wizard page **SQL Server**, config `Roles.SQL`): instance name, static TCP port, Windows or Mixed
  authentication (generated `sa` password in `output\<Lab>\lab-sql.csv`), sysadmin groups, test database with `db_owner`
  groups and table `dbo.LabCheck`, collation. Firewall rules and SQL Browser are configured automatically.
- SQL validation: service, TCP listener, firewall, Express edition, authentication mode, sysadmins, test database, and
  remote queries from the client (Windows authentication; `sa` in Mixed mode).
- `scripts\Get-LabIso.ps1 -IncludeSql` pre-downloads the SQL media; `-IsoSource` imports a `SQL` subfolder.
- MIT licence (`LICENSE`).

### Changed
- Wizard: SQL column in the member-server grid (not offered for domain controllers), new SQL Server page after Accounts,
  SQL lines in the summary.


## [1.0.0] — 2026-11-14

First public release (GitHub: tomaszchlebek/LabBuilder). Contains all work planned as 0.2.0 plus the fixes from the first real lab runs.

### Added
- **`LabBuilderSetup.exe`** setup wizard (.NET Framework 4.8 WinForms, ADR 0011): prerequisite check, all tester inputs,
  validation with the build rules, install, live build progress, load/save configuration; built by `installer/build.ps1`
  with the inbox `csc.exe`; the entered admin password goes to the build via stdin only.
- Tester-defined topology (config schema v2, ADR 0009): 1–5 domain controllers (additional DCs with DNS/GC),
  0–10 member servers, 0–20 workstations; vCPU/RAM/disk per server and for the workstations.
- Role catalog per server: ADCS (Enterprise Root CA), IIS (+HTTPS), DHCP (authorised scope), File Server (share), plus any extra Windows features.
- Dedicated domain admin accounts (`adm.<first>.<last>`, Domain Admins by RID 512) and configurable number of test users;
  option to make test users local administrators on the workstations.
- Network choice: Private (isolated) or Internal (host-reachable) switch.
- VM regional settings and time zone from the Hyper-V host; UI language from the Windows image (ADR 0010).
- `BaseConfig` layering in config files; `scripts/Test-LabConfigFile.ps1`; `-AdminPasswordFromStdin` for `Invoke-LabBuild.ps1`.
- Validation: all DCs present, replication, VM vCPU/RAM, dynamic disk size, role checks (CA, DHCP, share, IIS), domain-admin membership and logon, workstation local admins.

### Changed
- Windows 11 media: **Enterprise LTSC** evaluation (was Enterprise).
- VM disks: independent **dynamic** VHDX copies of a 32 GB base, expanded to the tester's size (ADR 0008; was differencing disks).
- Phases `DomainController`/`IisServer` renamed `DomainControllers`/`MemberServers` (old names still accepted).
- Account plan CSV has a `Type` column (DomainAdmin/TestUser); existing plans are topped up when counts grow.
- `MinFreeGB` default 150.

### Fixed
- IIS HTTPS certificate request failed with CERTSRV_E_TEMPLATE_DENIED (0x80094012): each IIS server's computer account now gets
  Enroll on the WebServer template (only that computer) and the CA service is restarted. The template is looked up by DN in the
  configuration partition.
- Wizard build page / prerequisite list: column widths now scale with the display DPI (Status was cut); the prerequisite list fills
  the page and the bottom buttons size to their text ("Load configuration..." showed as "Load" at high DPI).
- Wizard server grids: column headers were cut at display scaling above 100 %; columns now size to their text and the grid fills the page.
- Base image temp file `*.vhdx.building` was rejected by `New-VHD`; now `*.building.vhdx`.

## 0.1.0 — 2026-11-14 (not released)

### Added
- Project documentation framework: `CLAUDE.md` rules, DEVLOG, CHANGELOG, ADRs 0001–0007, requirements, architecture, runbook.
- `LabBuilder` PowerShell module (Windows PowerShell 5.1+, inbox tooling only) and `scripts/Invoke-LabBuild.ps1` running
  directly on the Hyper-V host in 8 idempotent, resumable phases.
- ISO download from the Microsoft Evaluation Center with redirect allow-list, resumable `curl.exe` download, size and
  SHA-256 verification, `iso-manifest.json`; `scripts/Get-LabIso.ps1`; `-IsoSource` import.
- Base VHDX build from `install.wim`, unattend.xml injection, Gen 2 + Secure Boot, vTPM for Windows 11; Private switch.
- DC with forest, DNS, Enterprise Root CA, OUs, 4 groups, 3 random users; domain-joined IIS server with HTTPS; 3 Windows 11 workstations.
- Validation report; lab summary; secrets in DPAPI file and ACL-restricted CSV; `scripts/Remove-Lab.ps1`; Pester tests.

### Changed
- Execution model: runs directly on the Hyper-V host (ADR 0007) instead of remote WinRM orchestration (ADR 0002, superseded).
