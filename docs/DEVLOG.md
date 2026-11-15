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
