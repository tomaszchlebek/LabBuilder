# Changelog

All notable changes to this project are documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
