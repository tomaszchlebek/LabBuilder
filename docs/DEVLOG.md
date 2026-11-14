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
**Not decided:** no LICENSE file — without one the public code is "all rights reserved"; add a licence if others may reuse it.
**Next:** Further work from the tester.