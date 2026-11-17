# Development Log — Build TEST environment

Chronological record of every step and major change. Newest entry at the bottom.

## Entry template

```
## YYYY-MM-DD — <Step title>

**What:** <what was done>
**Why:** <reason / requirement / decision link>
**Files:** <files created or changed>
**Verification:** <tests run, manual checks, results>
**Next:** <follow-up steps>
```

---

## 2026-11-14 — Project created, documentation conventions established

**What:** Created project folder `Build TEST environment`, initialised git (branch `main`, no commits). Added `CLAUDE.md`
(documentation discipline + PowerShell conventions: 5.1 target, ASCII-only scripts, idempotent phases, Pester 3.4 syntax),
`.gitignore` (output, credentials, ISO/VHDX, local config), `.editorconfig`, ADR template and
[ADR 0001](adr/0001-record-decisions-and-development-log.md).
**Why:** Requester asked for a new project and, mid-way, to "use application development best practice, record and document all steps" — same discipline as the IT Notifications project.
**Files:** `CLAUDE.md`, `.gitignore`, `.editorconfig`, `docs/adr/0000-template.md`, `docs/adr/0001-…`
**Verification:** Folder layout and `git status` checked.
**Next:** Capture requirements.

## 2026-11-14 — Requirements v0.1 and initial decisions

**What:** Wrote `docs/REQUIREMENTS.md` v0.1 from the brief: inputs (host, FQDN, NetBIOS), FR-1…FR-15, NFR-1…NFR-6, scope, open questions.
Checked the Microsoft Evaluation Center pages for current ISO links and resolved them:
Server 2025 → `26100.32230.260111-0550…SERVER_EVAL_x64FRE_en-us.iso` (8,152,356,864 bytes);
Windows 11 Enterprise → `26300.9457.260913-1737…CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso` (8,225,329,152 bytes),
both on `software-static.download.prss.microsoft.com`. Recorded ADRs:
[0002](adr/0002-execution-model-winrm-and-powershell-direct.md) remote WinRM orchestration (later superseded),
[0003](adr/0003-iso-source-and-verification.md) ISO source/verification,
[0004](adr/0004-vm-build-from-base-vhdx.md) base VHDX + differencing disks + unattend (avoids Gen2 "press any key" / ADK),
[0005](adr/0005-isolated-private-network.md) Private switch,
[0006](adr/0006-lab-secrets-handling.md) secrets.
**Why:** Requirements before implementation (CLAUDE.md). Evaluation Center chosen because consumer Windows 11 ISOs sit behind an anti-automation page.
**Files:** `docs/REQUIREMENTS.md`, `docs/adr/0002…0006`
**Verification:** Links resolved with `curl -sIL`; ADR links checked.
**Next:** Config model and module.

## 2026-11-14 — Clarification: ISOs downloaded first on the deployment machine

**What:** Requester: "ISOs can be downloaded first to this or any workstation test deployments will run in future".
ISO handling designed as a reusable local cache with a manifest (size, SHA-256) plus a standalone pre-download script `scripts/Get-LabIso.ps1`.
**Why:** FR-2.
**Files:** `docs/REQUIREMENTS.md` (FR-2), `docs/adr/0003-…`
**Verification:** —
**Next:** Implement module.

## 2026-11-14 — LabBuilder module, config and templates

**What:** Implemented `src/LabBuilder` (Windows PowerShell 5.1+, inbox modules only):
- `Config.ps1` — `Import-LabConfig` (psd1 + dotted overrides, JSON round-trip), `Test-LabConfig` (scopes Iso/Host/Full: FQDN, NetBIOS ≤ 15 and ≠ computer names, names, octets, images, groups, URLs), `Get-LabVmDefinition`, `Get-LabDomainDN`, `Resolve-LabConfigPath`.
- `Secrets.ps1` — crypto-RNG `New-LabPassword` (no look-alikes), `Test-LabPasswordComplexity`, `New-LabAccountPlan` (3 random users; all in first group, every group ≥ 1 member), `ConvertTo-UnattendPassword`, `Protect-LabFile` (icacls).
- `Iso.ps1` / `Private/Download.ps1` — manual redirect following with HTTPS + Microsoft-host checks and final-host allow-list, resumable `curl.exe` download to `.partial`, size + SHA-256 check, `iso-manifest.json`, `Import-LabIso`.
- `HostSetup.ps1` — preflight checks, base VHDX build (GPT: ESP/MSR/Windows, `Expand-WindowsImage`, `bcdboot /f UEFI`, ESP type set after, diskpart fallback), Private switch.
- `VM.ps1` / `Private/VMHelpers.ps1` — differencing disk, unattend injection, Gen2 + Secure Boot, vTPM for Windows 11; PowerShell Direct wait/run/retry, graceful restart, static IP, domain join, unattend removal.
- `Roles.ps1` — DC (forest + DNS, Enterprise Root CA RSA 4096/SHA-256, OUs, groups, users), IIS (features, health page, WebServer cert + HTTPS binding), workstations.
- `Validation.ps1` — host isolation/VM checks, DC/CA/AD content/DNS, IIS, per-workstation membership + HTTP/HTTPS GET + LDAP bind of a test user; Markdown + JSON report.
- `Phase.ps1` — phase dispatcher, `state.json`, `Remove-LabEnvironment` (only config-named VMs, `ShouldProcess`).
- Templates `unattend-server.xml`, `unattend-client.xml` (local `LabAdmin`, online-account screens hidden).
- `config/lab.config.example.psd1` — all settings with comments.
**Why:** FR-1…FR-15; decisions ADR 0003–0006.
**Files:** `src/LabBuilder/**`, `config/lab.config.example.psd1`
**Verification:** see test entry below.
**Next:** Entry scripts.

## 2026-11-14 — Clarification: run directly on any Hyper-V host (ADR 0007)

**What:** Requester: "This application will be run directly from any Hyper-V host". Dropped the remote WinRM orchestration
and the workstation→host ISO copy: the build now runs in an elevated console on the host itself; ISOs download into
`<LabRoot>\ISO` on the host; pre-downloaded ISOs from any machine are imported with `-IsoSource` (re-hashed).
Recorded as [ADR 0007](adr/0007-run-directly-on-the-hyper-v-host.md); ADR 0002 marked *Superseded*; ADR 0003 amended
(location section); ADR 0004–0006 references updated; requirements v0.2 (IN-1, FR-2, new FR-16). Config: removed
`HyperVHost` and `Iso.DownloadOn`; `Publish-LabIsoToHost` replaced by `Import-LabIso`.
**Why:** Requester clarification; simpler, fewer failure points (no WinRM, double-hop, 16 GB copies over WinRM).
**Files:** `docs/adr/0002…0007`, `docs/REQUIREMENTS.md`, `config/lab.config.example.psd1`, `src/LabBuilder/Public/{Config,Iso,Phase,HostSetup}.ps1`, `LabBuilder.psd1`
**Verification:** grep for `WinRM|HyperVHost|DownloadOn|Publish-Lab` in code: none left.
**Next:** Entry scripts, tests.

## 2026-11-14 — Entry scripts

**What:** `scripts/Invoke-LabBuild.ps1` (requires elevation; inputs `-DomainFqdn`, `-DomainNetbios`, optional `-LabRoot`,
`-LabAdminCredential`, `-IsoSource`, `-Phase`; DPAPI admin credential, account-plan CSV, per-phase error with resume command,
`lab-summary.md`, exit code 2 if validation fails), `scripts/Get-LabIso.ps1` (no elevation/Hyper-V), `scripts/Remove-Lab.ps1`
(confirm / `-WhatIf`, `-IncludeBaseImages`, `-IncludeIso`, `-RemoveOutput`).
Logging changed so several log files receive every line (build log in `output\` + host log in `<LabRoot>\Logs`) — found in review:
the phase dispatcher would otherwise have redirected the build log after phase 1.
**Why:** FR-13, FR-14, FR-15, FR-16; NFR-4.
**Files:** `scripts/*.ps1`, `src/LabBuilder/Public/Write-LabLog.ps1`
**Verification:** below.
**Next:** Tests and docs.

## 2026-11-14 — Tests and static checks

**What:** `tests/LabBuilder.Tests.ps1` — 31 Pester tests (inbox Pester 3.4 syntax): config load/overrides/JSON round-trip,
validation rules, VM definitions, DN, password generator (length, categories, no look-alikes), complexity, account plan
(unique, UPN, group coverage, CSV round-trip), unattend encoding, server/client unattend rendering (XML well-formed, escaping,
no plaintext password, LabAdmin account), download host allow-list (look-alike hosts refused), single-entry manifest read-back.
**Why:** CLAUDE.md — tests for logic that runs without Hyper-V.
**Files:** `tests/LabBuilder.Tests.ps1`, `src/LabBuilder/Public/Config.ps1` (fix)
**Verification:**
- First run: 23 passed / 8 failed — `Test-LabConfig` returned its error list wrapped in an extra array (`return , $x` + caller `@()`). Fixed; re-run **31 passed / 0 failed**.
- PowerShell parser over all 19 `.ps1/.psm1/.psd1` files: 0 errors; ASCII-only check: 0 violations; both unattend templates parse as XML; module imports (25 commands).
- Live check of `Resolve-LabDownloadUrl` against both configured links (HEAD only): Server `go.microsoft.com → aka.ms → software-static.download.prss.microsoft.com`, Client `go.microsoft.com → software-static.download.prss.microsoft.com`; sizes match the Evaluation Center files.
- Logging smoke test: two log files both receive the line.
- **Not yet verified:** an end-to-end build on a real Hyper-V host (this dev session is not elevated); Hyper-V/AD/CA/IIS code paths are untested until the first lab run.
**Next:** First real lab run on a Hyper-V host; record result here (RUNBOOK §8).

## 2026-11-14 — Documentation

**What:** `docs/ARCHITECTURE.md` (layout diagram, components, phases with idempotency checks, identities, traceability),
`docs/RUNBOOK.md` (prerequisites, build, pre-download, ISO link maintenance, outputs, using the lab, troubleshooting, teardown,
recording runs), `README.md`, `CHANGELOG.md` `[Unreleased]`.
**Why:** CLAUDE.md rule 4.
**Files:** `docs/ARCHITECTURE.md`, `docs/RUNBOOK.md`, `README.md`, `CHANGELOG.md`, `docs/DEVLOG.md`
**Verification:** Links between documents checked against the file layout.
**Next:** Initial commit (on request); first lab run; answer open questions in REQUIREMENTS §7.

## 2026-11-14 — Requester answers and new scope (requirements v0.3, ADRs 0008–0011)

**What:** Recorded the requester's answers — (1) Windows Server 2025 Standard OK, (2) Windows 11 **Enterprise LTSC**,
(3) VM language/time zone from the Hyper-V host, (4) test users local admin: tester decides at install,
(5) Private vs Internal network: tester decides — and the new scope: tester decides server roles per server, number of DCs
and their vCPU/RAM/disk (always dynamic), number of dedicated domain admins and test users, number and generic size of
workstations, and a **Windows `.exe` installer** collecting all inputs. Requirements v0.3 (IN-1…IN-13, FR-17…FR-19, NFR-7).
New ADRs: [0008](adr/0008-per-vm-dynamic-disks.md) per-VM dynamic disks (amends 0004),
[0009](adr/0009-tester-defined-topology-and-role-catalog.md) topology + role catalog,
[0010](adr/0010-locale-from-hyper-v-host.md) locale from host, [0011](adr/0011-wizard-installer-exe.md) wizard exe.
ADR 0003 amended for LTSC (link `linkid=2289029` resolves to `26100.1742.240906-0331…CLIENT_LTSC_EVAL_x64FRE_en-us.iso`, 5,112,850,432 bytes).
**Why:** Requester decisions.
**Files:** `docs/REQUIREMENTS.md`, `docs/adr/0003`, `0004`, `0008`–`0011`
**Verification:** LTSC link resolved with `curl -sIL`; inbox `csc.exe` 4.8.9221 present (C# 5).
**Next:** Config schema v2.

## 2026-11-14 — Config schema v2, accounts, locale, dynamic disks

**What:**
- `config/lab.config.example.psd1` v2: `DomainControllers[]`, `MemberServers[]` (Roles, AdditionalFeatures, sizes),
  `Workstations{Count, NamePrefix, FirstHostOctet, sizes}`, `Accounts{DomainAdminCount, TestUserCount, TestUsersAreLocalAdmins}`,
  `Roles{IIS, DHCP, FileServer}`, empty `Locale` (= host), LTSC image, 32 GB base, `MinFreeGB` 150.
- `Config.ps1`: topology → VM definitions (Index, Roles, DiskSizeBytes); `Test-LabConfig` rules for counts, sizes (servers ≥ 40 GB,
  workstations ≥ 64 GB / 4 GB RAM / 2 vCPU), roles (catalog, ADCS ≤ 1, DHCP ≤ 1, HTTPS needs CA, DHCP range vs static IPs), `.local` refused,
  SchemaVersion 2; `BaseConfig` layering (deep merge) for wizard configs.
- `Secrets.ps1`: `New-LabAccountPlan -DomainAdminCount -TestUserCount` with `Type` column.
- `Unattend.ps1`: `Resolve-LabLocale` (host time zone, system/user locale, keyboard; UI language from image).
- `HostSetup.ps1`: base image records version + language; **fixed** temp name `*.vhdx.building` (rejected by `New-VHD`) → `*.building.vhdx`.
- `VM.ps1`: per-VM dynamic copy + `Set-VHD -ResetDiskIdentifier` + `Resize-VHD` + offline `Resize-Partition`; host locale in unattend.
**Why:** ADR 0008–0010.
**Files:** `config/lab.config.example.psd1`, `src/LabBuilder/Public/{Config,Secrets,Unattend,HostSetup,VM}.ps1`
**Verification:** see test entry below.
**Next:** Roles and phases.

## 2026-11-14 — Multiple DCs, member servers with role catalog, workstations, validation

**What:** `Roles.ps1` rewritten: forest root DC → AD content (OU=Admins added; Domain Admins via RID 512) → additional DCs
(`Install-ADDSDomainController`, DNS, GC) → DNS client order → DC roles; `Install-LabMemberServer` (CA server first);
`Install-LabServerRole` (ADCS, DHCP with authorisation + scope + options, FileServer with share/NTFS rights, IIS + HTTPS,
extra features); workstations with optional local-admin group and 0-count support. Phases renamed `DomainControllers`/`MemberServers`
(old names accepted). `Validation.ps1` rewritten for any topology: VM vCPU/RAM, dynamic disk type/size, all DCs + replication, roles,
admin membership, LTSC caption, local admins, HTTP/HTTPS per IIS server, share read, LDAP bind of a test user and a domain admin.
Review found that in-VM check blocks had code before `param()` — fixed with a helper that inserts the prologue after `param()`,
and a unit test now compiles every block. `Invoke-LabBuild.ps1`: optional domain parameters, `-AdminPasswordFromStdin`,
account-plan top-up, richer summary. New `scripts/Test-LabConfigFile.ps1`.
**Why:** ADR 0009; FR-6…FR-12.
**Files:** `src/LabBuilder/Public/{Roles,Validation,Phase}.ps1`, `LabBuilder.psd1` (0.2.0), `scripts/Invoke-LabBuild.ps1`, `scripts/Test-LabConfigFile.ps1`
**Verification:** Pester **47/47** (config v2, BaseConfig layering, topology, all validation rules, account plan, locale, unattend, check blocks, manifest, required images).
**Next:** Wizard exe.

## 2026-11-14 — LabBuilderSetup.exe wizard

**What:** `installer/` — WinForms wizard in C# 5 for .NET Framework 4.8 (`Program.cs`, `WizardForm.cs`, `LabModel.cs`,
`PsRunner.cs`, `Payload.cs`, `app.manifest` requireAdministrator) and `installer/build.ps1` (payload zip with forward-slash
entries, AssemblyInfo from module version, inbox `csc.exe`). Pages: Welcome/prerequisites, Install & lab, Domain (+password),
Network (Private/Internal), Domain controllers (count + grid: name, IP, vCPU, RAM, disk, role checkboxes, features),
Member servers (count + grid, IIS HTTPS, DHCP range, share), Accounts (admins, users, password length, local admin yes/no, groups),
Workstations (count, prefix, first IP, vCPU/RAM/disk), ISOs, Summary (resources vs host, host locale, script validation),
Build (phase list + live log, open output/summary/report). Load/Save configuration via PowerShell (`Import-LabConfig | ConvertTo-Json`).
**Why:** FR-18, FR-19; ADR 0011.
**Files:** `installer/**`, `.gitignore` (`installer/bin`, `installer/obj`)
**Verification:**
- Build: compiled without warnings; `installer\bin\LabBuilderSetup.exe` 162 KB, payload 39 files.
- Wizard model test (exe loaded by reflection, 22 checks, all pass): default config validates; complex config (3 DCs, 3 member servers with mixed roles + features, 10 workstations, Internal switch, local admins, quoted description) validates and maps to 16 VMs with the right sizes/IPs; JSON → `FromConfig` → `ToPsd1` round trip identical; invalid config (HTTPS without CA) reported by `Test-LabConfigFile.ps1`; payload contains scripts/module/example and no tester config or output.
  (First run had 1 failure caused by the test itself using a group name with an apostrophe, which the rules correctly reject.)
- UI: every page rendered to PNG and inspected; fixed button order (Back/Next/Cancel), `&` mnemonics, last-row label drift, clipped radio texts, grid column widths. Build page checked with simulated output (phase status parsing, failure state).
- **Not verified:** running the exe elevated end to end (this session is not elevated) and any real Hyper-V build.
**Next:** First real run of the wizard on a Hyper-V host; record it here.

## 2026-11-14 — Documentation for 0.2.0

**What:** README (wizard-first), ARCHITECTURE (new diagram, components, phases, role catalog, identities, traceability incl. FR-17…19),
RUNBOOK (wizard pages table, scripts alternative, LTSC links, Internal switch use, troubleshooting), CHANGELOG `[Unreleased] — 0.2.0`,
CLAUDE.md (C# 5 rules, rebuild exe after payload changes, schema-change checklist). Exe rebuilt so the embedded docs match.
**Why:** CLAUDE.md rule 4.
**Files:** `README.md`, `docs/ARCHITECTURE.md`, `docs/RUNBOOK.md`, `CHANGELOG.md`, `CLAUDE.md`, `docs/DEVLOG.md`
**Verification:** Links checked against the file layout; final rebuild + tests below.
**Next:** Commit on request; first lab run.

## 2026-11-14 — First lab run (tester): HTTPS certificate denied; wizard grid columns cut

**Lab run (partial, reported by the tester):** wizard 0.2.0 on a Hyper-V host, default topology (DC01 with ADCS, IIS01, workstations).
Phases up to DomainControllers succeeded; MemberServers: IIS01 domain-joined and IIS installed, then the HTTPS step failed 5/5 with
`CertEnroll::CX509Enrollment::Enroll ... 0x80094012 CERTSRV_E_TEMPLATE_DENIED`; build exited with code 1. ISO builds/hashes and
host OS not reported. Also: on the tester's display (scaling above 100 %) the server grid headers were cut ("Computer", "RAM").

**Cause 1 (certificate):** `Get-Certificate -CertStoreLocation Cert:\LocalMachine\My` enrols as the computer account (`IIS01$`).
The built-in **WebServer** template grants Enroll only to Domain Admins and Enterprise Admins, so the CA denies the request.
**Fix:** new `Grant-LabCertificateTemplateEnroll` (Roles.ps1), called before the HTTPS request for every IIS server: on the forest
root DC it adds an Allow ExtendedRight ACE for the Certificate-Enrollment right (`0e10c968-78fb-11d2-90d4-00c04f79dc55`) for that
computer's SID on `CN=<template>,CN=Certificate Templates,CN=Public Key Services,CN=Services,<config NC>` (only that computer,
not Domain Computers — least privilege); idempotent (checks the ACE by SID first); when it adds the ACE it restarts CertSvc on the
CA server(s) so the change is used immediately. Language-independent (SID + right GUID, no names).

**Cause 2 (grid):** column widths were fixed pixel values; WinForms scales fonts but not DataGridView column widths, so at
125–200 % display scaling the headers no longer fit. **Fix:** columns auto-size to header/cell text (`AllCells`) with minimum
widths measured with `TextRenderer` (DPI-aware), sorting off (no glyph space), grid anchored left/right to fill the page, header
height auto, features column fills the rest (header "Extra Windows features (comma separated)").

**Files:** `src/LabBuilder/Public/Roles.ps1`, `installer/src/WizardForm.cs`, `CHANGELOG.md`, `docs/RUNBOOK.md`, `docs/DEVLOG.md`; exe rebuilt.
**Verification:**
- Pester 47/47 pass; Roles.ps1 parses; ASCII check clean; wizard model checks 22/22 pass.
- Grid rendered to PNG at 100 % and simulated 150 % (font 13.5 pt, form 1500x1020): all headers fully visible, no horizontal scrollbar.
- **Not verified:** the certificate fix on a real lab (needs the tester's re-run).
**Resume the failed lab:** run the new wizard with the same configuration (Load configuration → `<install>\config\lab.config.psd1`),
or after reinstalling: `.\scripts\Invoke-LabBuild.ps1 -ConfigPath <install>\config\lab.config.psd1 -Phase MemberServers,Workstations,Validate`.
**Next:** Tester re-run; record host OS, ISO hashes and validation result here.

## 2026-11-14 — Lab run 2/3 (tester): template lookup failed; phase list Status column cut

**Lab run (tester, tester's Hyper-V host, two attempts 15:22 and 15:31):** Preflight → DomainControllers skipped as done (idempotency works),
IIS01 already joined, IIS installed; the new Enroll step failed 3/3 on TESTLAB-DC01:
`Certificate template 'WebServer' not found in AD (is the Enterprise CA installed?)`. CA `TEST-ROOT-CA` exists. Grid column fix confirmed by the tester's screenshots.
**Cause:** the existence check used `Get-ADObject -Filter "distinguishedName -eq '...'"`, which searches only the *domain*
partition; certificate templates are in the *configuration* partition, so the template was never found.
**Fix:** look the template up by DN (`Get-ADObject -Identity <dn>`), which works across partitions; the error now prints the DN searched.
Also: the build page's phase list showed "done (0.0 m..." — ListView column widths are pixels and not DPI-scaled; new `Px()` helper
scales the phase list and prerequisite list columns to the display DPI (Status column wider).
**Files:** `src/LabBuilder/Public/Roles.ps1`, `installer/src/WizardForm.cs`, `CHANGELOG.md`, `docs/DEVLOG.md`; exe rebuilt.
**Verification:** Pester, parse, ASCII and wizard model checks below. **Not verified:** the Enroll step on a real DC (tester re-run).
**Next:** Tester re-run (Load configuration → Install & build); record the result.

## 2026-11-14 — Lab run 3 (tester): build completed; Welcome page layout at high DPI

**Lab run (tester, tester's Hyper-V host, Windows Server 2025 Datacenter, 191 GB RAM):** after the template-lookup fix the build ran to the end —
tester reports "everything else went perfectly fine" (HTTPS certificate issued, workstations built, validation passed).
ISO hashes not reported (see `<LabRoot>\ISO\iso-manifest.json` on the host).
**Issue:** on the tester's high-DPI display the Welcome page's prerequisite list was too small (rows and Detail cut, horizontal
scrollbar) and the "Load configuration..." button showed only "Load" (text wrapped inside a fixed-width button).
**Fix:** all bottom buttons `AutoSize` (GrowOnly) in auto-sizing flow panels; prerequisite list anchored left/right, taller, and its
Detail column fills the remaining width on resize.
**Files:** `installer/src/WizardForm.cs`, `CHANGELOG.md`, `docs/DEVLOG.md`; exe rebuilt.
**Verification:** wizard model checks 22/22; Welcome page rendered at 100 % and simulated 150 %: all rows and details visible, button texts complete.
**Next:** Further work announced by the tester; commit on request.

## 2026-11-14 — Release 1.0.0 (first public release)

**What:** Version set to **1.0.0** (LabBuilder.psd1; the wizard/exe version is generated from it); CHANGELOG `[Unreleased] — 0.2.0`
released as `1.0.0` (includes all 0.2.0 work and the lab-run fixes); README points to GitHub Releases for the exe; tester host name
removed from the DEVLOG. Repository published publicly on GitHub (`tomaszchlebek/LabBuilder`), tag `v1.0.0`, release with
`LabBuilderSetup.exe` attached.
**Why:** Requester asked to publish the app as version 1 in a public GitHub repository.
**Files:** `src/LabBuilder/LabBuilder.psd1`, `CHANGELOG.md`, `README.md`, `docs/DEVLOG.md`
**Verification:** Pester and wizard checks re-run before the commit (results in the release step); exe rebuilt as 1.0.0.
**Licence:** MIT, added right after the release at the requester's choice (next entry).
**Next:** Further work from the tester.
## 2026-11-14 — MIT licence

**What:** Added `LICENSE` (MIT, copyright 2026 tomaszchlebek) and a License section in the README (notes that Windows evaluation
media keep Microsoft's own terms); CHANGELOG `[Unreleased]`.
**Why:** Requester chose MIT so others may reuse the public code.
**Files:** `LICENSE`, `README.md`, `CHANGELOG.md`, `docs/DEVLOG.md`
**Verification:** GitHub licence detection checked after the push. The v1.0.0 exe is unchanged (docs only); the next build embeds the new README.
**Next:** Further work from the tester.

## 2026-11-14 — Release 1.1.0: SQL Server Express member servers (FR-20)

**Request:** "new version 1.1.0 - add functionality to deploy member server with automatic unattended SQL Express server - ask tester for SQL options to deploy".
**Research:** Microsoft's SQL Server downloads page links Express "Download now" to `go.microsoft.com/fwlink/p/?linkid=2216019` →
`aka.ms/sql2025express` → `download.microsoft.com/.../SQL2025-SSEI-Expr.exe` (4,606,792 bytes, valid Authenticode signature
Microsoft Corporation, version 17.0.1000.9). The old SQL Server 2022 Express direct link returns HTTP 404. Decision: SQL Server 2025 Express (ADR 0012).
**What:**
- Config `Roles.SQL` (example config; schema stays v2, new keys come from BaseConfig) + `Test-LabSqlConfig` (member servers only, instance,
  port, Windows/Mixed, groups must be lab groups, database name, collation, timeout); role catalog gets `SQL`.
- `Public/SqlServer.ps1`: `Save-LabSqlMedia` (web installer via the redirect allow-list, signature check, `/ACTION=Download /MEDIATYPE=Core /QUIET`,
  package signature check, `sql-media.json`), `Import-LabSqlMedia`, `Install-LabSqlServer` (copy over PowerShell Direct session, extract, Setup from a
  deleted `.ini`, 3010 → restart, Summary.txt in errors; every run: static TCP port, firewall, Browser, sysadmin logins, test DB + db_owner + `dbo.LabCheck`).
- Phase Iso fetches SQL media when a server has role SQL; MemberServers runs the SQL role after IIS; `Invoke-LabBuild.ps1` generates the `sa`
  password once into `lab-sql.csv` (ACL-protected; not in `lab-accounts.csv`, whose rows all become AD users) and adds SQL to `lab-summary.md`.
- Validation: in-server SQL checks and client-side TCP + Windows-auth query + `sa` login (Mixed).
- `Get-LabIso.ps1 -IncludeSql`.
- Wizard: role columns per grid (DC grid without SQL), SQL column on member servers, new page "SQL Server" (after Accounts so groups are known),
  summary lines, load/save of all SQL options; `LabModel.cs` reads/writes `Roles.SQL`.
- Version 1.1.0; docs: REQUIREMENTS v0.4 (IN-14, FR-20), ADR 0012, ARCHITECTURE, RUNBOOK, README, CHANGELOG.
**Files:** `config/lab.config.example.psd1`, `src/LabBuilder/Public/{Config,Roles,Phase,Validation,SqlServer}.ps1`, `src/LabBuilder/LabBuilder.psd1`,
`scripts/{Invoke-LabBuild,Get-LabIso}.ps1`, `installer/src/{LabModel,WizardForm}.cs`, `tests/LabBuilder.Tests.ps1`, docs.
**Verification:**
- Pester 52/52 (new: SQL config rules, SQL on DC rejected, service names, signature check accepts a Microsoft binary and rejects an unsigned file; check-block count 8).
- Wizard model checks 28/28 (new: SQL server + Mixed + groups validates with the script rules, settings land in `Roles.SQL`, base download settings kept, round trip, payload has `SqlServer.ps1`).
- Self-review: the validation's "LabCheck row" check counted a wrapped empty result as 1 row (PowerShell array unrolling, reproduced); now uses COUNT(*).
- Parser + ASCII checks clean; exe built (1.1.0); DC, member server and SQL pages rendered and inspected (member grid narrowed: header "SQL", smaller features minimum).
- **Not verified:** running the SQL web installer's download mode (blocked by this development environment's safety policy) and any SQL
  Setup in a VM — first exercised on the tester's Hyper-V host. The download step reports how to place the package by hand if it fails.
**Next:** Tester build with a SQL member server; record media version/SHA-256 (`ISO\SQL\sql-media.json`) and validation result; publish 1.1.0 on request.

## 2026-11-15 — Tester lab run with SQL Server (1.1.0)

**What:** The tester built a lab with the 1.1.0 wizard including a SQL Server Express member server on their Hyper-V host and reported "tested - all good".
**Result:** The previously unverified steps worked on a real host: web installer download mode, offline package, unattended SQL Setup in the VM,
post-install configuration and the SQL validation checks. FR-20 is verified by the tester's run.
**Files:** `docs/DEVLOG.md`, `docs/adr/0012-sql-server-express-role.md` (consequence updated)
**Next:** Publish 1.1.0 (commit, tag `v1.1.0`, GitHub release with the exe) on the requester's go-ahead.

## 2026-11-15 — Publish release 1.1.0

**What:** Committed the 1.1.0 work (SQL Server Express role, wizard page, validation, docs), pushed to `origin/main`, tagged `v1.1.0` and
created the GitHub release with `LabBuilderSetup.exe` (SHA-256 930BD376...71AD05F5) attached.
**Why:** Requester approved publishing after the successful tester run.
**Files:** all 1.1.0 files (see the 1.1.0 entry), `docs/DEVLOG.md`
**Verification:** release page and asset checked with `gh release view v1.1.0`.
**Next:** Further work from the tester.

## 2026-11-15 — Roadmap for 1.1.1 to 3.0.0

**Request:** Plan the requester's idea list (branding, maximised window, OS choice, host compatibility, shared base images,
parallel build, lab discovery/delete, Exchange, IT Portal injection, VyOS + VyManager, web interface), reorganised to minimise work;
update GitHub with every version.
**What:** `docs/ROADMAP.md` — merged 1.1.1+1.1.2 and 1.1.3+1.1.5, moved host compatibility after the parallel engine (test hosts built
by LabBuilder itself), IT Portal before Exchange, old 1.4.0 dropped (done in 1.1.0); shared groundwork list; decisions D1-D4.
**Research:** Evaluation Center still offers Server 2019 and 2022; the Windows 10 Enterprise evaluation page redirects to the
end-of-support post (no Windows 10 eval); no "Exchange 2025" exists (successor is Subscription Edition); Exchange 2019 ended support
14 Oct 2025 and its evaluation page returns 404; VyManager is a community Docker Compose app needing the VyOS API.
**Files:** `docs/ROADMAP.md`, `docs/DEVLOG.md`
**Verification:** n/a (plan only).
**Next:** Requester decisions recorded (next entry), then start 1.1.1.

## 2026-11-15 — Roadmap decisions D1-D4

**What:** Requester answered the open roadmap questions: D1 Windows 10 from a tester-supplied ISO; D2 Exchange 2019 CU15 **and**
Subscription Edition (trial); D3 web UI public on the internet with sign-in + MFA (hardening list added to 3.0.0); D4 publish each
version after the tester host run.
**Files:** `docs/ROADMAP.md`, `docs/DEVLOG.md`
**Next:** Start 1.1.1 (branding + resizable wizard).

## 2026-11-15 — Release 1.1.1: branded, resizable wizard (+ release script)

**Request:** Roadmap 1.1.1 (old 1.1.1 + 1.1.2): brand the exe with www.itomsol.com (appearance/logo from the website or the IT Portal
project); run the application maximised and allow resizing.
**What:**
- Branding from the IT Portal project (its ADR 0014; mark = itomsol.com favicon): `installer/branding/` (mark SVG/PNG, icon),
  `installer/src/Brand.cs` (ink `#111A24`, lime `#C6F277`); side panel in ink with mark, "LabBuilder / by ITOM Solutions",
  lime current step, footer link www.itomsol.com + tagline + version; lime accent line under the page header; exe icon
  (`/win32icon`), embedded mark, assembly company/copyright. `build.ps1` fails if branding files are missing.
- Window: opens maximised, Sizable + maximise box; notes wrap to the page width (capped for readability); step labels sized by DPI and
  follow the panel width (they were created after form scaling with fixed pixels).
- `scripts/Publish-LabRelease.ps1`: version/tag/CHANGELOG checks, refuses secret/output files, Pester, exe build + version check,
  commit/push/tag, `gh release create` with CHANGELOG notes (absolute links) + SHA-256; `-WhatIf` dry run.
- Version 1.1.1; CHANGELOG, README, ARCHITECTURE, RUNBOOK updated.
**Files:** `installer/src/{WizardForm,Brand}.cs`, `installer/build.ps1`, `installer/branding/*`, `scripts/Publish-LabRelease.ps1`,
`src/LabBuilder/LabBuilder.psd1`, `CHANGELOG.md`, `README.md`, `docs/{ARCHITECTURE,RUNBOOK,ROADMAP,DEVLOG}.md`
**Verification:** Pester 52/52; wizard model checks pass (0 failures); `Publish-LabRelease.ps1 -WhatIf` dry run OK (first runs found: git CRLF warnings on stderr were fatal in PS 5.1, -WhatIf leaked into Pester/build, a stale index.lock from the interrupted run - all fixed; index is reset on failure); parse + ASCII clean; exe 1.1.1 (ProductVersion 1.1.1, company ITOM Solutions);
pages rendered at 1600x950 and 900x600 and inspected (first render showed a stray scrollbar in the step list - fixed).
**Not verified:** maximised start and icon on the tester's high-DPI host (render harness runs in a non-maximised window).
**Next:** Tester run of the exe; then publish 1.1.1 with `Publish-LabRelease.ps1`.

## 2026-11-15 — 1.1.1 fix: side panel brand clipped at high DPI

**Problem (tester screenshot, high-DPI host):** "LabBuilder" wrapped to "LabBuilde / r", "by ITOM Solutions" wrapped, the subtitle was cut to
"Hyper-V TEST". **Cause:** the form sets `AutoScaleMode.Font` without `AutoScaleDimensions`, so WinForms never scales pixel sizes,
while fonts follow the display scaling; the 200 px panel stayed 200 px with 150 % text.
**Fix:** side panel width and brand block are computed from measured text (`TextRenderer.MeasureText`) and `Px()` (mark, gaps,
padding); brand block laid out explicitly (no wrapping table cell); page header height measured from its fonts.
**Verification:** rendered at 100 % (clean); width check with fonts scaled 1.5x/2.0x: panel 300/413 px holds the widest text
(tagline 252/357 px) - fits. Not verifiable here: a real 150 % display (tester re-run).

## 2026-11-15 — 1.1.1: default 1 workstation, SQL page only when needed

**Request (tester, with screenshots):** "number of test stations default to 1"; "show this SQL configuration page only if tester choose
to install SQL server". The tester's screenshots also show the fixed side panel at high DPI.
**What:** Default workstation count 3 → 1 (example config, `LabModel.cs`, test, RUNBOOK/README RAM estimate ~12 GB, wizard memory check
threshold 12 GB). Wizard pages can be hidden (`Page.Hidden`): the SQL Server page is skipped by Next/Back and left out of the step list
unless a member server has role SQL (its options stay saved; `Test-LabSqlConfig` ignores them without SQL servers).
**Files:** `config/lab.config.example.psd1`, `installer/src/{LabModel,WizardForm}.cs`, `tests/LabBuilder.Tests.ps1`, `README.md`,
`docs/RUNBOOK.md`, `CHANGELOG.md`
**Verification:** navigation test (reflection): without SQL Accounts → Workstations and back, step list without "SQL Server"; with SQL
on IIS01 Accounts → SQL Server → Workstations, step listed. Pester 52/52 (duplicate-IP test moved from WS02 to WS01); wizard model checks 0 failures.

## 2026-11-15 — Publish release 1.1.1

**What:** Requester approved publishing 1.1.1 (branding, maximised/resizable wizard, high-DPI side panel fix, default 1 workstation,
SQL page only when needed, release script, roadmap). Published with `scripts/Publish-LabRelease.ps1` (first real use): tests,
exe build, commit, push, tag `v1.1.1`, GitHub release with `LabBuilderSetup.exe`.
**Verification:** `gh release view v1.1.1`: latest release, asset LabBuilderSetup.exe (238 KB, SHA-256 7CC3B8A7...4878), commit 76720ca. The notes started with a UTF-8 BOM (PS 5.1 `Set-Content -Encoding UTF8`) - stripped on GitHub with `gh release edit`; the script now writes the notes without BOM (fix goes out with the next release).
**Next:** 1.2.0 - shared image library and OS choice (docs/ROADMAP.md).

## 2026-11-15 — Release 1.2.0: OS choice per VM, shared image library, lab manifest

**Request:** Roadmap 1.2.0 (old 1.1.3 + 1.1.5): choose the OS of servers (Server 2019/2022/2025) and workstations (Windows 10/11);
create base images once and use them for any future lab. Plus the lab manifest/VM tags planned as groundwork for 1.4.0.
**Research:** Evaluation Center (2026-11-15): Server 2022 `go.microsoft.com/fwlink/p/?LinkID=2195280` → `SERVER_EVAL_x64FRE_en-us.iso`
(5,044,094,976 bytes), Server 2019 `LinkID=2195167` → `17763.3650...SERVER_EVAL_x64FRE_en-us.iso` (5,652,088,832 bytes), both on the
allow-listed `software-static.download.prss.microsoft.com`; Server 2025 8,152,356,864 bytes, Windows 11 LTSC 5,112,850,432 bytes.
Windows 10 Enterprise evaluation is gone (decision D1: tester-supplied ISO).
**Decision:** [ADR 0013](adr/0013-shared-image-library-and-os-choice.md); REQUIREMENTS v0.5 (IN-15, FR-21..FR-23; FR-1/2/11/15 amended).
**What:**
- Config: OS catalog `Iso.Images` (`Server2025/2022/2019`, `Win11LTSC`, `Win10` with `Supplied`, `SourcePath`), `Kind`, `CaptionPattern`,
  `Iso.DefaultServerImage`, `Image` per server, `Workstations.Image`, `Paths.LibraryRoot`; validation of keys, kinds per role, Win10 ISO path,
  library outside the lab folder, legacy `Server`/`Client` catalog → clear error. VM definitions carry `Image` + `Kind`.
- `Public/Library.ps1`: library root, `Invoke-LabLibraryLock` (named mutex `Global\LabBuilder-Library-<item>`, abandoned = acquired),
  manifest entry update under its own lock, `Move-LabLegacyMedia` (1.0/1.1 ISOs + SQL media into the library), `Import-LabSuppliedIso`
  (copy + hash + source record, re-import when the source changes), `Write-LabManifest` (`lab.json` after every phase), `Get-LabVmNote`.
- ISO phase/`Save-LabIso`/`Import-LabIso`/`Confirm-LabHostIso` and SQL media use `<Library>\ISO`; per-image locks. Base images
  `<Library>\BaseImages\<Key>.vhdx`: adopt a 1.0/1.1 base of the lab, rebuild when the ISO hash changed, build under lock.
- VMs: unattend/local admin/vTPM by `Kind`; notes `LabBuilder:<Lab> | <role> <name> <ip> | <OS>` (existing VMs get tagged).
- Validation: OS check for every VM (catalog `CaptionPattern`); workstation LTSC check replaced. Summary lists OS per VM + library.
- `Remove-Lab.ps1 -IncludeLibrary` (aliases kept) deletes only this lab's library items, `$PSCmdlet` captured so `-WhatIf` holds inside lock
  blocks; `Get-LabIso.ps1 -Image <keys>` (default: the OSes the config uses).
- Wizard: library folder (follows the lab drive until changed), OS combo column in both server grids, workstation OS + Windows 10 ISO
  browse (file must exist), ISO page lists the needed ISOs, summary with OS; `LabModel.cs` reads/writes all new keys.
- Version 1.2.0; README, RUNBOOK (library section, links, troubleshooting, teardown), ARCHITECTURE, ROADMAP, CHANGELOG.
**Not done (moved):** the generic media downloader planned in the roadmap for 1.2.0 moves to 1.5.0 (no new media type needed it yet).
**Files:** `config/lab.config.example.psd1`, `src/LabBuilder/Public/{Library,Config,Iso,HostSetup,VM,Phase,Validation,SqlServer,Roles}.ps1`,
`src/LabBuilder/Private/VMHelpers.ps1`, `src/LabBuilder/Templates/unattend-client.xml`, `src/LabBuilder/LabBuilder.psd1`,
`scripts/{Invoke-LabBuild,Get-LabIso,Remove-Lab}.ps1`, `installer/src/{LabModel,WizardForm}.cs`, `tests/{LabBuilder,Library}.Tests.ps1`, docs.
**Verification:**
- Pester 65/65 (13 new in `tests/Library.Tests.ps1`: catalog, OS per VM + kind rules, Win10 ISO rule, legacy catalog error, library
  default/inside-lab rule, base path, required images, nested locks, VM note, `lab.json` (no secrets, CreatedUtc kept), supplied ISO
  import/re-import, 1.0/1.1 ISO migration); 5 old tests moved to the new keys; check-block count 9.
- Lock across two processes: B waited for A and continued; A killed while holding → B acquired (abandoned mutex).
- Wizard model checks: 0 failures (new: OS per server, Win10 + ISO path, library folder, round trip); pages rendered (Install, DCs,
  Members with OS column, Workstations with Windows 10, ISOs) and inspected — duplicated "your ISO" text fixed.
- Parse + ASCII checks clean (found and fixed a literal U+25B6 character in WizardForm.cs that came in with 1.1.1; now the `▶` escape); exe built 1.2.0.
- **Not verified:** a real build with Server 2019/2022 and Windows 10 VMs, the 1.1 → 1.2 media migration on a real lab folder, and base
  images built from the 2019/2022 ISOs (tester host run).
**Next:** Tester host run (ideally: existing 1.1 lab folder to see the migration, one Server 2022 + one Server 2019 server, Win10 if an
ISO is at hand); then publish 1.2.0. Note for 1.3.0: the roadmap's optional differencing disks conflict with ADR 0008 (plain dynamic disks
required) — to be decided with the requester before 1.3.0.

## 2026-11-15 — 1.2.0 tester run 1: lab-name conflict caught too late → host conflict check

**Lab run:** host ITOMHV01, LabBuilder 1.2.0 wizard, lab name `TESTLAB` (the existing 1.1 lab's name) with a new domain `one.lab`.
Stopped before Preflight: `output\TESTLAB\lab-accounts.csv belongs to another domain (UPN suffix)` (exit 1). Nothing was changed on the host.
**Cause:** the guard is right (same VM names `TESTLAB-*`, same credentials folder), but it only ran inside the build and its message did not
say what to do. Two more collisions of a second lab were not detected at all: the same lab folder (`state.json`/`lab.json` are per folder)
and the same switch (`LAB-Isolated`, same 10.10.10.x addresses).
**Fix:** `Test-LabHostConflict` (Library.ps1): same lab name with another domain (output\<Lab>\lab-accounts.csv UPN suffix), lab folder of
another lab (lab.json name/domain, else 1.1 state.json name), switch already connecting VMs not named `<Lab>-*`. Runs in
`Test-LabConfigFile.ps1 -OutputRoot` (wizard Summary page - the build cannot start) and in `Invoke-LabBuild.ps1` before anything is
written; message: choose another lab name, folder and switch/subnet (the library is shared) or remove the old lab. The build's own
account-plan guard got the same wording. Wizard validation box height now measured from the wrapped text (long messages, high DPI).
**Files:** `src/LabBuilder/Public/Library.ps1`, `src/LabBuilder/LabBuilder.psd1`, `scripts/{Test-LabConfigFile,Invoke-LabBuild}.ps1`,
`installer/src/WizardForm.cs`, `tests/Library.Tests.ps1`, `CHANGELOG.md`, `docs/RUNBOOK.md`
**Verification:** Pester 68/68 (3 new: no conflict, tester case + same-domain re-run OK, lab folder of another lab via state.json/lab.json);
`Test-LabConfigFile.ps1 -OutputRoot` on a simulation of the tester case prints the new ERROR line and exits 1. Switch check not testable
here (needs elevated Hyper-V) - covered by the tester's next run.
**Next:** tester re-run, either the existing lab unchanged (domain kept; add a Server 2022/2019 server - tests the migration) or a second
lab with a new name, folder and switch/subnet.

## 2026-11-15 — 1.2.0 tester run 2: feature install failed on a fresh DC (0x80071A2D) → servicing retry

**Lab run:** ITOMHV01, wizard 1.2.0, lab TESTLAB / domain one.lab (the old lab had been removed). Preflight 0.1 min, Iso 8.9 min,
**BaseImages 13.5 min - all four base images built in the new library** (`D:\LabBuilder-Library\BaseImages`): Server2025, Server2022
(10.0.20348.587), Server2019 (10.0.17763.3650), Win11LTSC (10.0.26100.1742), ~3 min each; Network created `LAB-Isolated`; DC01 created
from `Server2025.vhdx`, booted and got its IP. **Failed:** `Install-WindowsFeature AD-Domain-Services` inside DC01 (6 min after first
boot): "The request to list features available on the specified server failed ... transaction that is no longer active. Error: 0x80071a2d".
**Cause:** Windows component servicing (CBS) in the freshly specialised VM was still busy; the error is transient (clears after a restart).
Not related to the 1.2.0 library changes (same base-image method as 1.1), just never hit before.
**Fix:** `Install-LabWindowsFeature` (VMHelpers.ps1): installs features in a VM; on servicing errors (`Test-LabServicingError`:
0x80071A2D, 0x800F0922, 0x80070BC9, "list features available", "no longer active", pending restart) it restarts the VM and retries
(4 attempts). All feature installs now use it: AD DS on the forest root and additional DCs, AD CS, DHCP, File Server, IIS, extra features
(the in-VM blocks no longer install features themselves).
**Files:** `src/LabBuilder/Private/VMHelpers.ps1`, `src/LabBuilder/Public/Roles.ps1`, `tests/Library.Tests.ps1`, `CHANGELOG.md`, `docs/RUNBOOK.md`
**Verification:** Pester 69/69 (new: the tester's exact message is classified transient; invalid feature name and 0x800F081F are fatal);
parse clean. The retry itself needs a real VM - tester re-run (resume: the wizard with the same settings continues at DomainControllers).

## 2026-11-15 — 1.2.0 tester run 3: AD "ready" too early on the new forest → stricter readiness

**Lab run:** resumed at DomainControllers. The servicing fix was not needed this time (AD DS installed first try); forest `one.lab`
created in ~10 min, DC01 restarted, "Active Directory answers" after 4 s - then the account step failed 3 times in 70 s:
"Unable to find a default server with Active Directory Web Services running" (`Get-ADDomain` without `-Server`).
**Cause:** `Wait-LabADReady` asked ADWS on DC01 directly (`-Server DC01`), which answers before the DC locator can *discover* a DC with
ADWS (what every later AD cmdlet without `-Server` uses) on a brand-new forest.
**Fix:** readiness = local `Get-ADDomain -Server` + `Get-ADDomainController -Discover -Service ADWS -ForceDiscover` + default
`Get-ADDomain`, all matching the FQDN, **twice in a row** (20 s apart); account step retries 5 × 30 s. `ADPS_LoadDefaultDrive = 0`
and `-WarningAction SilentlyContinue` where the AD module is loaded (no "Error initializing default drive" noise).
**Files:** `src/LabBuilder/Public/{Roles,Validation}.ps1`, `CHANGELOG.md`
**Verification:** Pester 69/69 (check blocks still compile); parse clean. Needs the tester's re-run (resume continues at DomainControllers;
the forest exists, so it goes straight to the readiness wait).

## 2026-11-15 — 1.2.0 tester run 4: regression "Cannot find drive AD" (my run-3 change) → fixed + guard test

**Lab run:** resumed; the readiness fix worked (accounts, groups, users created; member servers started). WEB01 got IIS; then
"granting Enroll on template 'WebServer'" failed 3x: `Cannot find drive. A drive with the name 'AD' does not exist` (`Get-Acl AD:\...`).
**Cause:** run-3 change set `ADPS_LoadDefaultDrive = 0` wherever the AD module is loaded (to silence warnings) - including
`Grant-LabCertificateTemplateEnroll`, which edits the template ACL through the `AD:` drive. My regression, not a host issue.
**Fix:** that block loads the module with the drive (warnings suppressed only). New Pester guard: no script block in the module may use
`AD:\` and disable the drive - verified it fails (naming Roles.ps1 line 36) when the bug is re-introduced, passes when fixed.
**Files:** `src/LabBuilder/Public/Roles.ps1`, `tests/Library.Tests.ps1`, `CHANGELOG.md`
**Verification:** Pester 70/70; guard proven against the regression; exe rebuilt. Resume continues at MemberServers.

## 2026-11-15 — 1.2.0 tester run 5: lab complete ("all good") → publish 1.2.0

**Lab run:** ITOMHV01, exe from `\itomhv01\downloads` (SHA-256 E1C4CFB7...), resumed at MemberServers: member servers (WEB01 with IIS +
HTTPS certificate), workstations and validation finished; tester reported "all good". Over runs 2-5 the 1.2.0 features were exercised on
the host: library `D:\LabBuilder-Library` with base images Server2025, Server2022 (10.0.20348.587), Server2019 (10.0.17763.3650) and
Win11LTSC (10.0.26100.1742) built once and reused on resume ("Base image ... in library"), forest one.lab on Server 2025.
**Not exercised on the host:** the 1.1 → 1.2 media migration (the old lab had been removed before run 2), Windows 10 workstations
(no ISO), the host conflict switch check.
**Next:** publish 1.2.0 (requester decision D4: publish after the host run passes); then 1.3.0 - ask the requester about the roadmap's
optional differencing disks vs ADR 0008 first.

## 2026-11-15 — Roadmap decision D5: differencing disks as an option (1.3.0)

**Decision (requester):** "Offer as option" - 1.3.0 keeps plain dynamic VM disks (ADR 0008) as the default and offers differencing disks on
the library base images as a per-lab choice. Consequence to handle in 1.3.0: such labs depend on their library base images, so
`-IncludeLibrary` / 1.4.0 lab deletion must not delete a base image another lab's differencing disks use. ADR to be written with 1.3.0.
**Also:** the 1.2.0 release exe was copied to `\itomhv01\downloads` after the wizard was closed on the host (SHA-256 matches).
**Files:** `docs/ROADMAP.md` (D5, 1.3.0 section), `docs/DEVLOG.md`

## 2026-11-15 — Release 1.3.0: parallel build, differencing-disk option, live VM progress

**Request:** Roadmap 1.3.0 (old 1.1.6): "speed up the process ... by running tasks in parallel when possible, like duplicating base images
and creating VMs - extract / copy once and use many times"; decision D5: differencing disks offered as an option.
**Decision:** [ADR 0014](adr/0014-parallel-build-differencing-disks-progress.md); REQUIREMENTS v0.6 (IN-16, FR-24..FR-26, NFR-6).
**What:**
- `Private/Parallel.ps1`: `Invoke-LabParallel` - runspace pool (PS 5.1), each worker imports the module and runs the script block bound to
  it (`NewBoundScriptBlock`), log prefix `[<item>]`, per-item log `Logs\vm-<item>.log`; the parent relays Information (Write-Host) and
  Warning streams live (console, transcript, wizard); all items finish, failures summarised (`N of M ... failed: ...`); `-Sequential`
  fallback. `Test-LabParallelEnabled`, `Get-LabThrottleLimit` (auto = half the logical CPUs, 2..8).
- Parallel: phase Iso (per ISO, max 4), BaseImages (per OS, max 2), `New-LabVMSet` (all VMs of a phase), member servers (ADCS servers
  first one by one, then the rest), workstations (`Initialize-LabMemberServer` / `Initialize-LabWorkstation` extracted). Forest root and
  additional DCs unchanged (sequential).
- Locks: `Write-LabLog` file writes (mutex), `VhdMount` (unattend injection - one mounted disk at a time), `CertTemplate` (template ACL
  read-modify-write + CertSvc restart), unique ESP diskpart temp file; `Invoke-LabLibraryLock -Quiet` for these short internal locks.
- Differencing option: `Disks.Type`, `New-LabVM` (New-VHD -Differencing + Resize-VHD), `Get-LabBaseImageUser` (parent chains of all VM
  disks) protects bases in the ISO-change rebuild and in `Remove-LabEnvironment -IncludeLibrary`; validation accepts Differencing with an
  existing parent; `lab.json` DiskType.
- Progress: `Write-LabProgress` (progress.jsonl + `##LBP` line), `Get-LabPhaseOfRole`; events from VM creation, DC promotion/roles,
  member servers, workstations. Wizard: Build options (parallel, disk type) on *Install & lab*, summary line, Build page VM list
  (`OnProgressEvent`, malformed lines ignored); `LabModel.cs` reads/writes `Build.Parallel` and `Disks.Type`.
- Example config `Disks`, `Build`; `Test-LabConfig` checks them. Version 1.3.0; README, RUNBOOK (8a, troubleshooting), ARCHITECTURE, ROADMAP.
**Files:** `src/LabBuilder/Private/Parallel.ps1` (new), `src/LabBuilder/Public/{Write-LabLog,VM,Roles,HostSetup,Phase,Library,Config,Validation}.ps1`,
`src/LabBuilder/LabBuilder.psd1`, `config/lab.config.example.psd1`, `installer/src/{LabModel,WizardForm}.cs`, `tests/Parallel.Tests.ps1` (new), docs.
**Verification:**
- Engine trial: 4 x 2 s items in 3.4 s, prefixed live lines, private helper available in workers, one failure reported while the others
  finished, sequential mode.
- Pester 79/79 (9 new: concurrency + module binding, failure summary, sequential order, 200 log lines from 4 workers complete/unmixed +
  per-VM log, build/disk option defaults and validation, lab.json DiskType, progress.jsonl, role → phase).
- Wizard model checks 0 failures (new: build options in config + round trip); pages rendered: Install & lab with Build options, Build page
  with simulated progress events (ready green, failed red, malformed line ignored).
- **Not verified (needs the host):** real parallel VM creation/joins/roles on Hyper-V, PowerShell Direct from several runspaces at once,
  differencing disks end to end, CPU/disk load on ITOMHV01.
**Next:** tester host run (new lab or the existing one: both parallel and differencing are worth one run); publish 1.3.0 when it passes.

## 2026-11-15 — Redesign request: lab manager (designed, planned as 1.4.0)

**Request (during the 1.3.0 host test):** wizard asks *create a new lab or edit an existing lab*; first run sets **App folder, Labs folder,
Library folder**; the wizard scans the Library folder for imported ISOs and base images; every new lab gets its own subfolder in the
Labs folder.
**Finding:** all labs share one `<App>\config\lab.config.psd1` - building DIFFLAB overwrote TESTLAB's settings (TESTLAB cannot be
re-loaded unless it was saved with *Save configuration...*); credentials live in `<App>\output\<Lab>`, lab folders anywhere on the host.
**Design:** [ADR 0015](adr/0015-lab-manager-folders-and-start-page.md) (Accepted with decisions D6 1.4.0 after 1.3.0, D7 old labs registered in place, D8 default folders C:\LabBuilder, <data>:\LabBuilder-Labs, <data>:\LabBuilder-Library): host settings in `%ProgramData%\LabBuilder\settings.json`,
first-run *Folders* page, start page (new / edit / delete / image library), `<LabsFolder>\<LabName>\` with its own config + VMs + logs +
output, library inventory, lab discovery incl. registered 1.0-1.3 labs and orphaned tagged VMs, delete flow, reconstruction of a lost
config from `lab.json` + Hyper-V. Merged with roadmap 1.4.0 (discover/delete), which needs the same inventory.
**Not started in code:** the 1.3.0 build under test stays unchanged so test fixes are not mixed with the redesign; implementation after
1.3.0 is published.
**Files:** `docs/adr/0015-lab-manager-folders-and-start-page.md`, `docs/ROADMAP.md`, `docs/DEVLOG.md`

## 2026-11-15 — Request: faster DC promotion and CA → planned as 1.4.1 (not coded)

**Request:** "Promoting domain controller takes too much time same as adding certificate authority - can you speed up for example by
creating base image"; then "think about it and add to future changes".
**Analysis:** a pre-promoted forest image is not reusable (each lab has its own domain name, domain SID, krbtgt and passwords). What can be
saved: the AD DS / AD CS feature installs (minutes per DC/CA, plus the first-boot servicing failures seen in run 2) via **role-ready base
images** (features pre-installed, sysprep `/generalize /oobe /mode:vm`, fallback to the plain base), and the member-server/workstation
OOBE time by **creating those VMs while the forest is promoted** (two parallel tasks in phase DomainControllers).
**Result:** added to the roadmap as **1.4.1** (after the 1.4.0 lab manager) with the plan, expected gain and the ADR still to write.
No code changed - the 1.3.0 build under test is unchanged.
**Files:** `docs/ROADMAP.md`, `docs/DEVLOG.md`

## 2026-11-15 — 1.3.0 tester run (DIFFLAB, parallel + differencing): "all good" → publish 1.3.0

**Lab run:** ITOMHV01, exe 1.3.0 from `\itomhv01\downloads`, second lab **DIFFLAB** next to TESTLAB: own lab folder, switch and subnet,
build options *parallel* + *differencing disks* on the library base images (`D:\LabBuilder-Library`). Tester reported "all good" (build
and validation completed). Exercised for the first time on the host: parallel VM creation/configuration (runspace engine, PowerShell Direct
from several runspaces), differencing disks end to end incl. the validation disk check, the live VM list, two labs on one host with the
host conflict check passing.
**Not exercised:** `Build.Parallel = $false`, base-image protection when an ISO changes, `Remove-Lab -IncludeLibrary` with differencing users.
**Next:** publish 1.3.0 (D4); then 1.4.0 Lab manager (ADR 0015), then 1.4.1 faster DC/CA.

## 2026-11-15 — Release 1.4.0: lab manager (redesign) with discovery and deletion

**Request:** the requester's redesign (start page new/edit lab, first-run App/Labs/Library folders, library scan, each lab in its own
subfolder) merged with roadmap 1.4.0 (discover and delete labs) - decisions D6-D8, [ADR 0015](adr/0015-lab-manager-folders-and-start-page.md).
REQUIREMENTS v0.7 (FR-27..FR-30).
**What:**
- Module `Public/LabManager.ps1`: host settings (`%ProgramData%\LabBuilder\settings.json`), `Get-LabOutputPath` (config `Paths.OutputPath`;
  new labs `<LabRoot>\output`, older labs `<App>\output\<Lab>`), `Get-LabInventory` (Labs folder, registered labs, labs discovered from tagged
  VMs - lab folder = parent of `VMs`; VM states, size, disk type, last phase), `Register-LabExternal`, `Get-LabLibraryInventory` (per OS ISO +
  base image + differencing users, unknown ISOs, servers first), `Restore-LabLegacyConfig` (newest matching old shared config or `.bak-<time>`
  copy -> `<LabRoot>\lab.config.psd1`, BaseConfig absolute), `New-LabConfigFromInventory` (fallback rebuild from lab.json + Hyper-V),
  `Remove-LabFromInventory` (only the lab's own VMs/files/folder/credentials; never library files; foreign files keep the folder).
- Scripts: `Get-LabInventory.ps1` (JSON back end; `-SaveSettings`, `-RegisterDiscovered` incl. restoring old configs, `-ReconstructConfig`),
  `Invoke-LabBuild.ps1 -LabName`, `Remove-Lab.ps1 -LabName [-Force]`; output folder via `Get-LabOutputPath`; conflict check also reads the lab's
  own output folder.
- Wizard (`WizardForm` partial + `LabManagerPages.cs`): pages Folders (first run / Change folders), Start (new / edit / delete / library + lab
  list + library summary), Delete lab (preview, typed name, live log via `Remove-Lab.ps1 -LabName -Force`), Image library; *Install & lab* ->
  *Lab* (paths read-only from settings, folder follows the name, name must be new and its folder empty); Edit loads the lab's config, locks
  name/domain/network/disk type (NetBIOS editable after a rebuild); the lab's config is written to its lab folder (no shared
  `config\lab.config.psd1`); summary shows the action; Load/Save hidden on manager pages. `LabModel`: `ToPsd1(baseConfig)`, OutputPath, Mode.
- Example config `Paths.OutputPath`; validation. Version 1.4.0; README, RUNBOOK, ARCHITECTURE, ROADMAP, CHANGELOG.
**Files:** `src/LabBuilder/Public/{LabManager,Library,Config}.ps1`, `src/LabBuilder/LabBuilder.psd1`, `scripts/{Get-LabInventory,Invoke-LabBuild,Remove-Lab}.ps1`,
`config/lab.config.example.psd1`, `installer/src/{LabManagerPages,WizardForm,LabModel}.cs`, `tests/LabManager.Tests.ps1` (new), docs.
**Verification:**
- Pester 88/88 (9 new: settings first run + round trip, output path + validation, conflict in own output folder, inventory of Labs folder +
  external lab, register once, restore from the newest matching backup (roles kept, other lab's current file ignored), rebuild a valid config
  from lab.json, library inventory incl. older-ISO base and unknown ISO, delete files-only with library kept and foreign files keeping the folder).
- `Get-LabInventory.ps1` on this PC: first-run defaults, `-SaveSettings` writes settings, JSON output parsed.
- Wizard model checks 0 failures (new: own config with absolute BaseConfig validates, OutputPath in config + round trip). Pages rendered:
  Folders, Start (empty host), Image library, Delete (preview from real JSON, button enabled only after typing the name), Lab (folder follows
  the name); navigation New -> Lab, Library -> Image library, Delete -> Delete lab.
- **Not verified (needs the host):** discovery/registration of TESTLAB and DIFFLAB, restoring their configs from the `.bak` files, Edit of an
  existing lab end to end, deleting a lab with real VMs/switch, a new lab inside the Labs folder.
**Next:** tester host run, then publish 1.4.0; then 1.4.1 (faster DC/CA).

## 2026-11-15 — 1.4.0 tester run (lab manager): "all good" → publish 1.4.0

**Lab run:** ITOMHV01, exe 1.4.0 from `\itomhv01\downloads`; tester reported "all good" after the suggested test (first-run folders,
start page with the existing labs, image library view, edit, delete). First host run of: settings file, discovery/registration of the
1.0-1.3 labs (TESTLAB, DIFFLAB), config restore/rebuild, Edit and Delete with real VMs, library inventory.
**Next:** publish 1.4.0 (D4); then 1.4.1 faster DC/CA (roadmap).

## 2026-11-15 — Release 1.4.1: faster domain controllers and CA

**Request:** roadmap 1.4.1 (requester: DC promotion and CA take too long - "for example by creating base image").
**Research:** Microsoft's "Sysprep Support for Server Roles" lists AD CS and AD DS as **not supported** with sysprep -> the planned
booted + sysprepped role image was replaced by an **offline** role image (DISM, never booted, no sysprep). A pre-promoted forest stays
impossible (domain identity per lab). [ADR 0016](adr/0016-role-ready-base-images.md); REQUIREMENTS v0.8 (FR-31).
**What:**
- `Public/RoleImages.ps1`: `New-LabRoleBaseImageItem` (copy plain base -> mount under the VhdMount lock -> `Get-WindowsOptionalFeature -Path`
  -> enable the AD DS / DNS / AD CS (+ tools) features that exist with `Enable-WindowsOptionalFeature -All -LimitAccess` -> dismount ->
  read-only + sidecar with ParentCreatedUtc; kept when current, rebuilt when the plain base changed unless differencing users; any error =
  warning + cleanup + plain base), `Get-LabRoleImageKey`, `Get-LabVmBaseImageKey`, `Test-LabRoleImagesEnabled`.
- Phase BaseImages builds the role images after the plain bases (parallel, lock `Base-<OS>-Roles`); `New-LabVM` picks the role image for DCs
  and AD CS servers; the online `Install-LabWindowsFeature` stays as the safety net.
- `Install-LabDomainController` = two parallel tasks: `Install-LabDomainControllerCore` (unchanged chain) and, after the DC VMs exist, creation
  of all member-server and workstation VMs (with parallel build + RoleImages on).
- `-IncludeLibrary` removes role images too; library inventory + wizard library view list them ("made from the plain base image", current/older
  base); `OsCatalog.Display` for `<OS>-Roles`. Config/wizard option `Build.RoleImages` (Build options checkbox, summary line, LabModel).
- Version 1.4.1; RUNBOOK 8b, ARCHITECTURE, ROADMAP (deviation noted), CHANGELOG.
**Files:** `src/LabBuilder/Public/{RoleImages,HostSetup,VM,Phase,Roles,LabManager}.ps1`, `src/LabBuilder/LabBuilder.psd1`, `config/lab.config.example.psd1`,
`installer/src/{LabModel,WizardForm,LabManagerPages}.cs`, `tests/RoleImages.Tests.ps1` (new), docs.
**Verification:** Pester 94/94 (6 new: role image needed for DC/ADCS OS only + option off, base choice incl. fallback when the role image is
missing, skip without plain base, keep a current role image, rebuild-from-older-base failing cleanly without Hyper-V (no role image, no temp
file, DC falls back), library view lists role images). The test also showed `Mount-VHD` failing non-terminating -> now `-ErrorAction Stop`.
Exe built 1.4.1.
**Not verified (needs the host):** the offline DISM enablement of AD DS/AD CS and the first boot of a DC/CA from the role image, the measured
time saved, VM creation during the promotion on Hyper-V.
**Next:** tester host run (a new small lab: 1 DC with ADCS + 1-2 members + 1 workstation, compare the DomainControllers phase time); publish.

## 2026-11-17 — Analysis of the 1.4.0 host run "five" (logs in `Reports 140`, git-ignored)

**Lab run (2026-11-15, ITOMHV01 Server 2025 Datacenter, 124.8 GB RAM free, LabBuilder 1.4.0):** lab `five` / five.lab in
`D:\LabBuilder-Labs\five`, differencing disks, parallel on: DC01 (2025, ADCS), DC02 (2025), WEB01 (2019, IIS+HTTPS), FS01 (2022, File Server),
DB01 (2025, SQL Express), WS01-03 (Win11 LTSC). **Validation 107/107 passed. Total 1 h 14 min.**
**Timeline:** Preflight+Iso+BaseImages+Network 18 s (library reused). DomainControllers **47.2 min** (64 %): DC01 first boot 3.6 min, forest
promotion incl. AD DS feature 12.3 min, restart 1.5 min, AD readiness wait 5.5 min, accounts 12 s, DC02 promotion 9.1 min + 1.7 min,
DNS order 0.7 min, **CA on DC01 11.3 min** (after DC02, sequential). MemberServers **20.0 min** (only created at 20:55): FS01 3.8 min, WEB01
6.2 min, **DB01 19.7 min = SQL media copy into the VM 5.5 min (714 MB, ~2 MB/s via PowerShell Direct) + SQL Setup 8.5 min**. Workstations
4.9 min (first boot ~3 min). Validate 1.6 min.
**Findings:**
1. Phases are hard barriers: member servers and workstations wait 23 min after the domain is usable (20:32) for DC02 + CA. Only IIS HTTPS
   needs the CA; nothing needs DC02.
2. The CA install runs after DC02's promotion although it is on another VM (~9 min could overlap).
3. The SQL media copy over PowerShell Direct is slow; it could be written into the VM disk while it is mounted for unattend.xml.
4. Workstations wait for the SQL server (no dependency).
5. 1.4.1 (built, not yet tested) covers role images (AD DS/AD CS feature time) and VM creation during the promotion; findings 1-4 are not
   covered yet.
6. Cosmetic: the preflight curl line always says "falls back to Invoke-WebRequest" even when curl.exe is found; the CA step has no sub-step
   timings (11.3 min not broken down).
**Next:** decide with the requester whether 1.4.1 also gets the pipelining (start servers/workstations when the domain is ready, CA in
parallel with additional DCs, SQL media injected offline) before its host test.

## 2026-11-17 — 1.4.1 host run "six": promotion refused (AD CS in the role image) → fixed

**Lab run (ITOMHV01, 1.4.1 first build):** lab `six` - DC01 Server 2022 (ADCS), DC02 Server 2025, WEB01/DB01/FILE01 Server 2025,
WS01-03 Win11 LTSC, differencing disks, parallel + role images. BaseImages 6.4 min: **role images built offline** - Server2022-Roles
1.4 min, Server2025-Roles 6.4 min (features enabled: AD DS, DNS, AD CS + tools). DC01 created from Server2022-Roles, **ready in
1.6 min** (3.6 min from the plain base in run `five`); `[other VMs]` created all 6 other VMs in 30 s during the promotion. **Failed**
at 06:52:38: `Install-ADDSForest` - "Verification of prerequisites for Domain Controller promotion failed. **Certificate Server is
installed.**"
**Cause:** my design error - AD CS binaries block a DC promotion (and a CA must not change domain membership after AD CS is installed).
**Second finding:** `vm-FILE01.log` also contained WS03's lines - the runspace pool reuses a worker whose module still had the previous
item's per-VM log file in its list.
**Fix:**
- Role image = AD DS + DNS only, **DCs only**; sidecar `FeatureSet = 'ADDS-DNS/2'`; `Test-LabRoleImageCurrent` - images with another set
  (the 1.4.1 test images) are never used for new VMs and are rebuilt when no differencing disk uses them (lab `six`'s DCs still do).
- `Remove-LabUnconfiguredCa` before every promotion (root + additional DCs): uninstalls ADCS-Cert-Authority / AD-Certificate when no CA is
  configured, restarts the VM -> lab `six` can be resumed.
- `Invoke-LabParallel` worker clears the module's log list before each item.
- Wizard option text "Faster domain controllers"; library view "role-ready for DCs (AD DS, DNS)"; ADR 0016 revision, REQUIREMENTS FR-31,
  RUNBOOK 8b, ARCHITECTURE, CHANGELOG (1.4.1 dated 2026-11-17, Fixed section).
**Verification:** Pester 96/96 (new/changed: no AD CS pattern in the role image; role image only for DC OSes; outdated feature set not
used; CA member server on the plain base; feature-set-aware "current" in the library view - this test caught a missed edit; per-item log
with 6 items on 2 workers - fails with the old code, passes now).
**Not verified (needs the host):** resuming lab `six` (AD CS removal + restart, then promotion), DC promotion from the AD DS + DNS role
image, the rebuilt role images.

## 2026-11-17 — Lab "six" resumed: fast forest, then adprep failure → DC OS order check

**Lab run (ITOMHV01, 1.4.1 fixed build, resume 07:25-07:44):** BaseImages kept the old role images (differencing disks of six-DC01/DC02
use them, warning shown). `six-DC01: unconfigured AD CS binaries removed`, restart, then **forest created in ~2 min** (07:26:32 -> 07:28:26;
12.3 min in run `five`), AD ready in 26 s, accounts created. DC02: AD CS removal 5.4 min, then **promotion failed 3 times** in adprep:
"Verification of prerequisites for Active Directory preparation failed. Unable to check the specified user's group membership ... Access
is denied. Adprep was unable to bind to any Domain Controller (DC) over Remote Procedure Call (RPC)". Phase DomainControllers failed at
07:44:00. Per-VM logs of the new run are clean (the log-reuse fix works).
**Cause:** DC02 runs Server 2025, the forest root DC01 Server 2022 - a newer DC needs adprep (schema 2025) against the root, which fails
from the new DC in this setup. Not caused by the role image or the AD CS removal.
**Fix:** `Test-LabConfig` - an additional DC may not run a newer Windows Server than DC 1 ("Put the newest Windows Server on DC 1 (the
forest root) or use the same OS on all DCs"); wizard DC page note; CHANGELOG 1.4.1 Fixed, RUNBOOK 8b, ADR 0016 revision note.
**Verification:** Pester 97/97 (new: newer DC rejected; older or same OS accepted). Exe rebuilt and copied to \itomhv01\downloads
(SHA-256 verified).
**Next:** lab `six` cannot be fixed by editing (its VMs exist): delete it and rebuild with the newest OS on DC01 (or the same OS on both
DCs). Then the full 1.4.1 host run; publish after it passes (D4). Possible roadmap item: explicit adprep support for mixed-version DCs.

## 2026-11-17 — 1.4.1 host run "seven": PASSED (107/107, 54.8 min); Win11 LTSC evaluation expired

**Lab run (ITOMHV01, 1.4.1 build with the DC OS check; logs read directly over the Hyper-V connector):** lab `seven` - DC01 Server 2025
(ADCS), DC02 Server 2022, IIS01 (IIS), SRV02 (FileServer), SRV03 (SQL) Server 2025, WS01-03 Win11 LTSC, dynamic disks, parallel + role
images. 08:05:05 -> 08:59:52 = **54.8 min** (run `five`: 1h14m). **Validation 107 passed, 0 failed.**
ISOs (iso-manifest.json): Server2025 26100.32230.260111 (SHA-256 7B0525...BFD51), Server2022 SHA-256 3E4FA6...55325, Win11 LTSC
26100.1742.240906 (SHA-256 67CEC5...DA68).
Timings:
- BaseImages 6.1 min: old role images (with AD CS) rebuilt as ADDS-DNS/2 - Server2022-Roles 1.2 min, Server2025-Roles 6.1 min.
- DomainControllers 33.2 min: DC01 ready 5.5 min after start (first boot of the copy), forest promotion 11.7 min (08:17:38 -> 08:29:21;
  `six` took ~2 min on resume, so the first-boot promotion still dominates), AD ready 38 s, accounts 8 s, DC02 promotion 2.2 min,
  **CA 9.0 min** (sequential, after DC02). The 6 other VMs were created and booted during the promotion (08:12-08:14).
- MemberServers 13.1 min (SQL media copy 3.2 min, SQL setup 7.7 min - critical path), Workstations 0.9 min, Validate 1.1 min.
**Finding - workstations switch themselves off:** WS01-03 shut down at 09:58:31, one hour after their last boot. Offline read of WS01's
System log: `wlms.exe` event 1074 "The license period for this installation of Windows has expired. The operating system is shutting
down."; SPP status 0xC004F009 (grace period expired). Same pattern in every earlier lab (TESTLAB2, two, five, six workstations: shutdown
~60 min after boot; servers never). Cause: the **Windows 11 Enterprise LTSC evaluation build 26100.1742 (Sept 2024) has passed its
built-in evaluation end date**; Microsoft's evaluation links (LTSC and Enterprise, fwlink 2289029/2289031) still serve that same build on
2026-11-17. Not a LabBuilder defect; the build cannot detect it today (validation passed because it ran within the first hour).
Not done: disabling WLMS or other licence workarounds (circumvention - out of scope).
**Next (decision for the requester):** (a) validation check "Windows licence not expired" on every VM (SoftwareLicensingProduct) with a
clear message; (b) let the tester supply their own licensed Windows 11 ISO (as for Windows 10, D1) plus an optional product key / KMS
host. Then publish 1.4.1 (D4: host run passed).

## 2026-11-17 — 1.4.1 published

Requester: "Publish 1.4.1 now" (host run `seven` passed, D4). `scripts\Publish-LabRelease.ps1`: Pester 97/97, exe rebuilt (SHA-256
A1B9E97E9D16F0501FEF53A757AC71200A36893947E78F5122F55A9A5446428F), commit 21a5f5e, tag and release
https://github.com/tomaszchlebek/LabBuilder/releases/tag/v1.4.1 (asset digest matches). ROADMAP: current release 1.4.1; the expired
Win11 LTSC evaluation and adprep support listed as unscheduled findings. Copy to \itomhv01\downloads failed: the file is open on the
host (the wizard is running) - the share still holds this morning's build (same code, older embedded docs).
**Next:** requester decides on the Windows licence handling (validation check / tester-supplied Windows 11 ISO + key).

## 2026-11-17 — 1.4.2: validation check "Windows licence not expired"

**Why:** host run `seven` - Microsoft's Windows 11 LTSC evaluation ISO 26100.1742 is expired; workstations shut down (wlms.exe) one
hour after every boot, yet validation passed because it ran within that hour. Requester chose: validation check only (no
tester-supplied Windows 11 ISO, no licence workaround).
**What:**
- `Private\Licence.ps1` `Get-LabLicenceVerdict` (pure; injected as text into the in-VM block): evaluation = description
  `TIMEBASED_EVAL` or WLMS service present; evaluation passes only with status licensed/grace and time left (detail "evaluation, N
  day(s) left (until date)"), else fails "evaluation EXPIRED ... shuts this VM down every hour". Non-evaluation: "licensed" or "not
  activated ... keeps running" (pass).
- `Test-LabEnvironment`: the OS check of every VM also queries `SoftwareLicensingProduct` (Windows application ID, installed key) and
  adds "Windows licence not expired"; an unreadable state fails with the error text.
- Version 1.4.2; CHANGELOG [1.4.2]; REQUIREMENTS FR-12; RUNBOOK troubleshooting row; ROADMAP status.
**Verification:** Pester 104/104 (new tests/Licence.Tests.ps1: expired eval fails, eval with no time fails, running eval shows days,
WLMS alone = eval, licensed / unactivated non-eval pass, function self-contained, injected into the OS check). Real CIM query run on
ITOMHV01 via the connector: Server 2025 Datacenter VOLUME_MAK, status 1 -> "licensed". The query was not run inside a lab VM (the
connector account cannot use the lab admin credential, and must not); the expired case is backed by WS01's offline event log
(SPP 0xC004F009, wlms event 1074). Exe 1.4.2.0 built and copied to \itomhv01\downloads (SHA-256 2C9193...0171 verified).
**Next:** host test - start seven-WS01..03 and run `-Phase Validate` on lab `seven` (expected: "Windows licence not expired" fails on
the workstations, passes on the servers with days left); then publish 1.4.2 (D4).

## 2026-11-17 — 1.4.2 host test on lab "seven": licence check works; servers have only 10 days

**Lab run (ITOMHV01, 1.4.2 exe, tester re-ran MemberServers/Workstations/Validate on lab `seven` with WS01-03 started; 11:03):**
validation **112 passed, 3 failed** - the 3 failures are exactly the expected ones: "Windows licence not expired" on WS01-03
("evaluation EXPIRED (notification) ..."). All other checks passed, the 8 new licence checks ran in every VM (PowerShell Direct).
**Finding:** every server (Server 2025 and 2022 evaluation, installed today) reports "evaluation, 9 day(s) left (until 2026-11-27)".
A Windows Server evaluation starts with a 10-day period and gets its 180 days only after online activation; the lab is isolated
(Private switch), so it never activates. Consequence: after ~10 days the lab servers will also shut down every hour. Earlier labs
(built 2026-11-14/15) will reach that point around 2026-11-24/25.
**Next (requester):** handle the 10-day limit (e.g. validation warning with the end date in the lab summary, documented `slmgr /rearm`
or a temporary activation route) or publish 1.4.2 as is; D4: host test for 1.4.2 passed.

## 2026-11-17 — 1.4.2 published; AVMA investigated

**Published:** requester "publish" after the 1.4.2 host test. Pester 104/104, commit 8d444bf, tag + release
https://github.com/tomaszchlebek/LabBuilder/releases/tag/v1.4.2 (asset digest = local exe SHA-256 27582B...1020), exe copied to
\itomhv01\downloads (hash verified). First attempt stopped before committing: double quotes in `-Message` break the native git
argument line in Windows PowerShell 5.1 - use single quotes inside commit messages.
**AVMA (requester question "can you use AVMA to license VMs?"), from Microsoft Learn (automatic-vm-activation, upgrade-conversion-
options) and the host:**
- Host fits: ITOMHV01 is Windows Server 2025 **Datacenter**, activated (VOLUME_MAK, status 1). A 2025 Datacenter host activates
  Server 2025/2022/2019/2016/2012 R2 guests (all editions), **without network** (KVP / Data Exchange integration service - enabled on
  every lab `seven` VM). Generic per-version AVMA keys are public on Microsoft Learn; `slmgr /ipk` or the unattend file.
- Blocker: lab VMs run the **Evaluation** edition; an AVMA key needs the retail edition first: `DISM /online /Set-Edition:ServerStandard
  /ProductKey:<key> /AcceptEula` (check `/Get-TargetEditions`; eval Datacenter -> Datacenter only). **A domain controller cannot be
  converted** - so the conversion must happen before promotion, best once per library base image (all VMs, DCs and role images
  inherit it).
- Not for workstations: AVMA covers Windows Server only; Windows client evaluation cannot be converted -> workstations still need a
  licensed ISO + key/KMS (not chosen by the requester).
- Licensing: AVMA is proof of purchase - valid because the host's Datacenter licence covers unlimited Windows Server VMs on it.
**Next:** requester decides whether to implement (proposal: base-image conversion to retail Standard/Datacenter + AVMA key,
validation then shows "licensed"; existing labs: member servers convertible in place, DCs need a rebuild).

## 2026-11-17 — 1.4.3: AVMA activation of Windows Server VMs (ADR 0017)

**Requester:** "Yes, build AVMA". Driver: run `seven` servers have only 10 days (evaluation, no online activation in the isolated lab).
**Host experiments first (ITOMHV01 via the connector, throwaway copies in D:\LabBuilder-Library\avma-test, removed afterwards):**
- Server 2025 base copy: offline `DISM /Image /Get-TargetEditions` = ServerTurbine, ServerStandard, ServerDatacenter;
  `/Set-Edition:ServerStandard /ProductKey:<2025 Standard AVMA key> /AcceptEula` -> exit 0 in 70 s, edition ServerStandard. Throwaway
  VM (no NIC, random one-off password): "Windows Server 2025 Standard", channel VIRTUAL_MACHINE_ACTIVATION, status 5 for 3 min (no
  automatic activation); `slmgr /ato` -> "Product activated successfully", status 1, grace 10080 min; guest event 12309 and host
  event 12310 hr=0x00000000.
- Server 2022 base copy: offline conversion with its AVMA key -> ServerStandard, 33 s.
- Server 2019 base copy: offline conversion with the AVMA key -> **DISM 1168 "product key could not be validated"**; offline
  `/Set-ProductKey` with the AVMA key -> 1168 too. With the KMS client setup key: converted; throwaway VM: `slmgr /ipk <AVMA>` +
  `/ato` -> activated (status 1, AVMA channel).
- All throwaway VMs and files removed (checked).
**Implementation:**
- `Public\Activation.ps1`: catalog (per server OS: build, edition, conversion key, AVMA key - Microsoft's public generic keys),
  `Test-LabAvmaEnabled` (`Build.Avma`, default on), `Get-LabAvmaHostVerdict` (pure: Datacenter, activated, host build >= guest),
  `Get-LabAvmaHostSupport`, `Update-LabBaseImageEdition` (copy -> mount under the VhdMount lock -> DISM offline Set-Edition -> replace
  base, sidecar Edition/Activation/new CreatedUtc; skip + WARN for differencing users, unsupported host, DISM errors),
  `Get-LabImageEdition`, `Enable-LabVMActivation` (in VM: skip evaluation / already AVMA-activated, `slmgr /ipk` + up to 4x `/ato`;
  never throws).
- HostSetup: conversion right after each base image (same lock), before the role images (which rebuild from the new CreatedUtc).
- Roles: `Enable-LabVMActivation` after the network setup of the root DC, additional DCs (before promotion) and member servers.
- Licence verdict: "licensed (AVMA, renewed by the host)". Wizard: Build options checkbox, summary line; LabModel `Build.Avma`;
  example config. Version 1.4.3.
- Docs: ADR 0017, REQUIREMENTS FR-32, CHANGELOG [1.4.3], RUNBOOK 8c, ARCHITECTURE, ROADMAP.
**Verification:** Pester 113/113 (new tests/Activation.Tests.ps1: catalog covers every server OS and no client, role key mapping,
2019 uses a different conversion key, host verdicts, option default/off, AVMA licence detail, call sites in Roles/HostSetup and order
before role images, converted base and client OS skipped). ASCII check of src clean. Exe 1.4.3.0 built and copied to
\itomhv01\downloads (hash verified).
**Not verified yet (needs a lab build):** the full path inside LabBuilder - conversion of the real library bases (Server2025,
Server2022; lab `seven` uses dynamic copies, so no differencing users block it), role image rebuild, activation of DCs before
promotion and of member servers, validation "licensed (AVMA)".
**Next:** tester builds a new lab with 1.4.3 (servers on 2025/2022, any workstations); then publish 1.4.3 (D4).

## 2026-11-17 — 1.4.3 host run "nine": AVMA works on 2025, 2022 and 2019

**Lab run (ITOMHV01, 1.4.3 exe; logs read via the Hyper-V connector):** lab `nine` - DC01 Server 2025 (ADCS), DC02 Server 2022,
IIS01 Server 2025 (IIS), SRV02 Server 2022, SRV03 Server 2019, no workstations; previous lab `seven` deleted by the tester first.
14:01:31 -> 14:40:13 = 38.7 min. **Validation 79 passed, 1 failed.**
- BaseImages 9.3 min: the library bases were **converted offline** - Server2022 64 s, Server2025 2.6 min, Server2019 5.1 min (2019 waited
  for a parallel slot); sidecars now `Edition = ServerStandard, Activation = AVMA`; both role images rebuilt from the converted bases
  ("made from an older ... base - rebuilding").
- **Every server activated with AVMA** after its network setup (DC01 and DC02 before promotion, then IIS01/SRV02/SRV03); validation:
  "Windows licence not expired - licensed (AVMA, renewed by the host)" on all 5, captions "Windows Server 20xx Standard".
- DomainControllers 20.0 min (forest promotion 14:15:39 -> ~14:22, DC02 promotion ~3.5 min, CA 3.2 min), MemberServers 8.2 min.
**Findings:**
1. DC01 "AD replication without failures": 1 failure, validation 13 min after DC02's promotion; the report gave only the count (DC02:
   0 failures, HTTPS / LDAP / SQL client checks across both DCs passed). Probably transient after the promotion - not verifiable from
   here (the lab domain is not reachable by the connectors). Change: the check now names partner, error, count and first failure time.
2. IIS01 certificate request failed 4 times (0x80094004 CERTSRV_E_PROPERTY_EMPTY, then 0x800b0109 untrusted root) and succeeded on the
   5th try (~3 min): the CA was installed only 5 min earlier, so the lab root was not yet trusted on IIS01. Recovered by the existing
   retry; possible improvement: `gpupdate /force` + `certutil -pulse` on the server before the request.
3. Cosmetic: the OS check label still said "Evaluation" - now without it.
**Verification of the changes:** Pester 113/113; exe rebuilt and copied to \itomhv01\downloads.
**Next:** tester re-runs `-Phase Validate` on lab `nine` to see whether the replication failure cleared (and its partner/error if not);
then publish 1.4.3 (D4).

## 2026-11-17 — Lab "nine" re-validated: 80/80; 1.4.3 published

**Lab run (ITOMHV01, tester re-ran `-Phase Validate` on lab `nine`, 17:03):** **80 passed, 0 failed.** DC01 and DC02 "AD replication
without failures: 0 failure(s)" - the 14:40 failure was transient after DC02's promotion. OS labels without "Evaluation"
(Windows Server 2025/2022/2019 Standard), all 5 servers "licensed (AVMA, renewed by the host)".
**Published** (D4, host test passed): see the release entry in git/GitHub (v1.4.3); ROADMAP current release 1.4.3.
