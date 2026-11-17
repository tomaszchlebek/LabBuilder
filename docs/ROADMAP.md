# Roadmap — LabBuilder after 1.1.0

- **Date:** 2026-11-17 · **Status:** in progress — 1.1.1 to 1.4.1 released · **Current release:** 1.4.1

The requester's list was reordered and merged so that shared groundwork is built **once** and every later version reuses
it. Each version ships the usual way: requirements → code + tests → docs/DEVLOG/CHANGELOG/ADR → exe rebuild → tester
host run → **commit, tag and GitHub release** (requester: "update github repository every time app changes version").

## 1. Version plan

| New | Was | Content | Why here |
|-----|-----|---------|----------|
| **1.1.1** ✔ | 1.1.1 + 1.1.2 | Wizard: ITOM Solutions branding, opens maximised, freely resizable; release script (released 2026-11-15) | Same file (`WizardForm.cs`), one layout pass; branding assets already exist in the IT Portal project |
| **1.2.0** ✔ | 1.1.5 + 1.1.3 | Shared **image library** (ISOs + base images once for all labs) **and OS choice** per VM; lab manifest/tags (released 2026-11-15, ADR 0013; generic media downloader moved to 1.5.0) | Both rewrite the same image catalog and BaseImages phase; tags make 1.4.0 cheap |
| **1.3.0** ✔ | 1.1.6 | **Parallel build** (downloads, base images, disk copies, member servers, workstations) + progress events + differencing-disk option (released 2026-11-15, ADR 0014) | Needs the final image pipeline from 1.2.0; events reused by wizard and web UI |
| **1.3.1** | 1.1.4 | **Host compatibility** Server 2019 / 2022 / 2025 with Hyper-V; nested-virtualization option | Test hosts are built *by LabBuilder itself* (needs OS choice); tests the final parallel engine once |
| **1.4.1** | new (2026-11-15) | **Faster domain controllers and CA**: role-ready base images (AD DS + DNS enabled offline for DCs, no sysprep - ADR 0016) + member servers/workstations created while the forest is promoted; released 2026-11-17 after host run seven | Needs the 1.3.0 engine and the library; small, self-contained after the 1.4.0 rework |
| **1.4.0** ✔ | 1.2.0 + redesign | **Lab manager**: first-run App/Labs/Library folders, start page *new / edit / delete lab*, one folder per lab under the Labs folder, library inventory, **discover** and **delete** labs (ADR 0015, decisions D6-D8; released 2026-11-15) | Uses the manifest/tags from 1.2.0; the requester's redesign (2026-11-15) is the same inventory |
| **1.5.0** | 1.5.0 | **IT Portal injection**: import a portal package (any version), deploy to a chosen IIS member server, agent MSI to all domain computers by GPO | Reuses IIS, SQL Express (1.1.0) and lab CA certificates — mostly integration work |
| **1.6.0** | 1.3.0 | **Exchange Server 2019 CU15 or Subscription Edition** (trial) member servers | Heaviest role; reuses media downloader (1.2.0), OS choice, parallel engine |
| ~~1.4.0~~ | 1.4.0 | SQL Express — **done in 1.1.0**, skipped | — |
| **2.0.0** | 2.0.0 | **VyOS firewall VM + VyManager**: WAN on external switch, LAN on the lab switch, NAT + default firewall → lab gets internet | First Linux guests; changes the isolation model (ADR 0005) |
| **3.0.0** | 3.0.0 | **Secured web interface** `labbuilder.itomsol.com` (Docker on itomweb) managing itomhv01 | Needs headless engine, progress events (1.3.0) and discovery (1.4.0) |

IT Portal (old 1.5.0) moves before Exchange (old 1.3.0): it reuses roles that already exist, so it is quicker; Exchange
is the largest single role and profits from everything before it.

## 2. Shared groundwork (built once, reused)

| Item | Built in | Reused by |
|------|----------|-----------|
| Release script `scripts/Publish-LabRelease.ps1` (version bump check, tests, exe build, tag, `gh release`) | 1.1.1 | every version |
| Branding assets (`installer/branding`, from IT Portal ADR 0014: mark `#C6F277`/`#111A24`, Segoe UI, wordmark "**ITOM** Solutions") | 1.1.1 | 3.0.0 web UI |
| **Image library** `<LibraryRoot>\{ISO,BaseImages}` outside any lab (+ `Packages` in 1.5.0), host-wide lock per item | 1.2.0 ✔ | all labs, 1.4.0 (never deleted with a lab) |
| **Generic media downloader** (allow-listed URL, signature or hash check, manifest) — generalised from `Save-LabSqlMedia` | 1.5.0 (first new user) | IT Portal packages, Exchange prereqs, VyOS |
| **Lab manifest** `<LabRoot>\lab.json` + VM Notes tag `LabBuilder:<Lab>` | 1.2.0 ✔ | 1.4.0 discovery, 3.0.0 |
| **Progress events** (JSON lines per phase/VM) + per-VM logs | 1.3.0 ✔ | wizard progress, 3.0.0 |
| Nested virtualization option per VM | 1.3.1 | host test matrix, future Hyper-V-in-lab |

## 3. Versions in detail

### 1.1.1 — Branded, resizable wizard
- Header band with the ITOM mark + wordmark and tagline ("Better operations. Better outcomes." — itomsol.com),
  exe icon (`csc /win32icon`), colours as named constants; assets copied from `IT Notifications/branding/default`.
- `WindowState = Maximized`, `FormBorderStyle = Sizable`, sensible `MinimumSize`; pages moved to anchored
  `TableLayoutPanel`s so grids and lists grow with the window (also fixes remaining high-DPI edge cases).
- `Publish-LabRelease.ps1` to make every later release one command.

### 1.2.0 — Image library and OS choice
- **Library root** (default `D:\LabBuilder\Library`, wizard field) holds ISOs and base images for all labs; existing
  `<LabRoot>\ISO` and `BaseImages` are imported once (no re-download).
- **OS catalog:** Windows Server 2019, 2022, 2025 (Evaluation, Standard/Datacenter, Desktop Experience) — all still on
  the Evaluation Center; Windows 11 Enterprise LTSC. Each DC/server/workstation row gets an **OS column** (default per tier).
- **Windows 10:** Microsoft no longer offers a Windows 10 Enterprise evaluation (the Evaluation Center page redirects to the
  Windows 10 end-of-support post; support ended October 2025). Decision D1: Windows 10 is in the OS list but only from a
  **tester-supplied ISO** (wizard browses for it; edition checked from `install.wim`).
- Per-OS details: vTPM/Secure Boot template per OS, unattend differences, feature names (e.g. Server 2019 roles),
  domain/forest functional level = lowest DC OS.
- Validation of mixes (e.g. ADCS/Exchange OS limits) in `Test-LabConfig`; ADR for the library and catalog.

### 1.3.0 — Parallel build
- PS 5.1-safe throttled runspace pool (no `ForEach-Object -Parallel`), throttle from host cores/RAM/disk.
- In parallel: ISO downloads; base images for different OSes; VM disk copies + VM creation; after the root DC and CA:
  additional DCs (one at a time per site rule kept), member-server roles, all workstations (join, gpupdate).
- Order constraints kept: forest root → CA → servers needing certificates.
- Optional **differencing disks** from the library base (fast, small) next to the default full dynamic copies (ADR 0008) — tester choice per lab (decision D5); a lab using them must keep its base images, so library deletion (`-IncludeLibrary`, 1.4.0) has to refuse while such a lab exists.
- Progress events + per-VM log files; the wizard shows one row per VM.

### 1.3.1 — Host compatibility (Server 2019 / 2022 / 2025)
- Test matrix built with LabBuilder: nested Hyper-V hosts on itomhv01 (new *nested virtualization* option).
- Known checks: Server 2019 ships .NET 4.7.2 (wizard targets 4.8 — compile against 4.x APIs or require 4.8);
  VM configuration version limits; vTPM/guarded-fabric cmdlets per host; which guest OS each host supports
  (to verify against Microsoft's supported-guest lists); Preflight reports a clear blocker instead of failing late.

### 1.4.0 — Lab manager (redesign) with discovery and deletion — design: [ADR 0015](adr/0015-lab-manager-folders-and-start-page.md)
- **First run:** *Folders* page sets **App folder**, **Labs folder**, **Library folder** -> `%ProgramData%\LabBuilder\settings.json`.
- **Start page:** *Create a new lab* / *Edit an existing lab* / *Delete a lab* / *Image library*.
- **One folder per lab:** `<LabsFolder>\<LabName>\` with its own `lab.config.psd1`, VMs, logs, reports, `output\` (credentials) -
  no more shared `config\lab.config.psd1` (a second lab overwrote the first one's settings in the 1.3.0 test).
- **Library scan:** ISOs + base images per OS (build, date, used by which labs), unknown ISO files offered for import; OS lists show
  "in library" / "download ~X GB".
- **Edit:** loads the lab's config; name/domain read-only; add servers/workstations/roles; build resumes/extends.
- Discovery: `lab.json` in the Labs folder + registered 1.0-1.3 labs + VMs tagged `LabBuilder:` (orphans).
- Delete = stop + remove VMs, checkpoints, disks, lab folder (incl. credentials), switch (only if no other lab uses it);
  **never** the shared library. Confirmation by typing the lab name; `Remove-Lab.ps1 -LabName` for scripts.
- Existing labs stay in place (registered); a lost config is reconstructed from `lab.json` + Hyper-V and confirmed by the tester.

### 1.4.1 — Faster domain controllers and certificate authority (requester, 2026-11-15)
> **Built 2026-11-15 - [ADR 0016](adr/0016-role-ready-base-images.md).** Change to the plan below: Microsoft does not support sysprep
> with AD DS / AD CS installed, so the role image is made **offline with DISM** (copy of the plain base, features enabled, never booted,
> no sysprep) instead of a booted + sysprepped VM. Point 2 implemented as planned; point 3 (CA in parallel with additional DCs) not done.

Observed in the 1.2.0/1.3.0 host runs: forest promotion ~10 min incl. the AD DS feature install, the first boot as DC + AD readiness
~2-3 min, AD CS feature install + CA setup a few minutes more; fresh VMs sometimes hit "Windows servicing busy" (0x80071A2D) on the
first feature install. Plan:
1. **Role-ready base images** in the library, built once per server OS and reused by every lab: `<Library>\BaseImages\<OS>-Roles.vhdx`.
   Build: copy of the plain base -> temporary VM (no network, local admin with a random password) -> `Install-WindowsFeature
   AD-Domain-Services, DNS, ADCS-Cert-Authority -IncludeManagementTools` (servicing retry) -> remove the unattend file -> `sysprep
   /generalize /oobe /shutdown /mode:vm` (faster first boot on Hyper-V) -> remove the VM, keep the disk read-only + sidecar (parent OS,
   parent ISO SHA-256, features, language). Under the library lock; rebuilt when the plain base changes (unless differencing disks use
   it, ADR 0014). DCs and servers with role ADCS start from it; the feature install becomes a no-op (seconds instead of minutes) and
   cannot hit first-boot servicing. **Fallback:** if sysprep or the build fails, a warning and the plain base as today.
2. **Create the other VMs during the promotion:** phase DomainControllers runs two parallel tasks - the forest/DC chain and the creation
   of all member servers and workstations - so their OOBE has finished when the domain is ready (saves ~5 min per phase start).
3. Optional, to measure: run the CA setup on DC01 in parallel with additional DC promotions.
- **Not possible:** a pre-promoted forest image - every lab has its own domain name and must have its own domain SID, krbtgt key and
  passwords; a cached forest would be one fixed domain shared by all labs (rejected).
- Expected gain: ~5-8 min per DC/CA plus ~5 min overlap per lab; the first lab per OS pays ~10-15 min once for the role image.
- Needs an ADR (sysprep of a server with AD DS / AD CS binaries installed but not configured; `/mode:vm` only on the same host).

### 1.5.0 — IT Portal injection
- **Import IT Portal package…** in the wizard: `ITPortalServerSetup.exe` (+ agent MSI inside) stored as
  `Library\Packages\ITPortal\<version>\` with a manifest (file version, SHA-256, signature if signed). Any newer version
  can be imported later; the lab picks one.
- Member-server role **ITPortal** (requires IIS; SQL local via the SQL role or another lab SQL server):
  silent `ITPortalServerSetup.exe /quiet /sql:<server\instance>` with an **enterprise-CA certificate** from the lab CA.
- GPO for servers + workstations: agent install + portal URL registry preference. Software-installation policy has no
  PowerShell cmdlet, so the proposed method is a GPO startup task running `msiexec` from the distribution share
  (idempotent) — ADR needed.
- Validation: portal HTTPS 200, agent installed/running on each domain computer, agents registered in the portal.
- Upgrade: import a new version → re-run phase → server setup upgrade + GPO points at the new MSI.
- Needs from the IT Portal project: a documented silent-install contract (certificate thumbprint parameter, exit codes).
  The two projects stay separate; LabBuilder only consumes the published package.

### 1.6.0 — Exchange Server 2019 and Subscription Edition
- **Exchange "2025" does not exist:** the successor of 2019 is Exchange Server Subscription Edition (SE). Exchange 2019
  support ended 14 Oct 2025; an unlicensed install runs as a 180-day trial. Decision D2: the tester chooses **Exchange 2019
  CU15 or Exchange SE** (SE is code-equivalent to 2019 CU15, so one install path with two media entries). Media from the
  Microsoft Download Center where still offered, else a tester-supplied ISO.
- Prerequisites downloaded on the host and signature-checked: VC++ 2012/2013 runtimes, IIS URL Rewrite, UCMA 4.0 (on the ISO),
  .NET 4.8.1 where not inbox. `/PrepareSchema`, `/PrepareAD`, Mailbox role, lab-CA certificate, Autodiscover DNS.
- Sizing defaults: 4 vCPU, 16 GB RAM, 150 GB disk; long install (≈1–2 h) with timeout and resume.
- Mailboxes for test users and domain admins; validation: services, OWA/EWS HTTPS, mailbox per user, test mail flow.

### 2.0.0 — VyOS firewall + VyManager (lab internet)
- VyOS VM: eth0 = host **external** switch (WAN, DHCP from the network), eth1 = the lab switch (LAN, lab gateway);
  default rules: LAN → WAN allowed, WAN → LAN dropped, source NAT masquerade, DNS forwarders on the DCs → VyOS.
- VyOS rolling/Stream images are free; LTS images need a subscription. No Windows-style unattended setup: spike to choose
  between a cloud-init capable image and a scripted `install image` over a serial (named-pipe) console.
- VyManager runs on Docker Compose (needs VyOS HTTPS API) → a small Linux VM (cloud image + cloud-init NoCloud seed).
- Internet becomes **optional** per lab (ADR 0005 superseded); gateway set on all lab VMs; validation: outbound HTTPS from a workstation, WAN → LAN blocked.

### 3.0.0 — Web interface `labbuilder.itomsol.com`
- Container on **itomweb** (Docker): ASP.NET Core UI + API (same stack as IT Portal), same pages as the wizard plus Manage labs.
- **Host agent** on **itomhv01** (Windows service) runs the unchanged PowerShell engine; it connects **outbound** to the web app
  (no WinRM opened to the container), mutual TLS, allow-listed commands only.
- Security (decision D3: **public**, sign-in + MFA): OIDC sign-in (e.g. Entra ID) with **MFA required**, roles
  (admin/tester/viewer), no anonymous endpoints except sign-in and health; TLS only (HSTS) behind a reverse proxy with
  rate limiting and lockout; short sessions, anti-forgery tokens, strict CSP; destructive actions (delete lab) need
  re-authentication; audit log of every action; secrets never shown or logged; host agent connects outbound only, so
  itomhv01 exposes no port. Threat review (ADR) and an external scan before go-live.
- Live progress from the 1.3.0 events; lab list from 1.4.0. The exe stays available.

## 4. Requester decisions (2026-11-15)

| # | Question | Decision |
|---|----------|----------|
| D1 | Windows 10 has no official evaluation download any more | **Tester-supplied ISO** (e.g. Windows 10 Enterprise LTSC 2021); no automatic download |
| D2 | "Exchange 2025" does not exist (only Subscription Edition) | **Exchange 2019 CU15 and Exchange SE**, both as unlicensed trials |
| D3 | Web UI exposure | **Public on the internet**, protected by sign-in with MFA (hardening below, 3.0.0) |
| D4 | Publishing | **After the tester host run passes** (as for 1.1.0) |
| D5 | Differencing disks (1.3.0) vs "all disks dynamic" (ADR 0008) | **Offer as an option** per lab: plain dynamic copies stay the default; differencing disks on the library base are a tester choice (faster, smaller, but VMs depend on the library files - ADR in 1.3.0) |
| D6 | Redesign (start page, folders, one folder per lab) | **1.4.0 Lab manager**, merged with discover/delete, after 1.3.0 (ADR 0015) |
| D7 | Existing 1.0-1.3 labs | **Registered in place**, nothing moved |
| D8 | Default folders | `C:\LabBuilder`, `<data drive>:\LabBuilder-Labs`, `<data drive>:\LabBuilder-Library` |

## 5. Risks
- Microsoft download links move or disappear (Windows 10, Exchange 2019 already) → every media item keeps a manual fallback.
- Parallel builds stress the host disk; throttling and an opt-out switch are part of 1.3.0.
- Exchange 2019 is out of support and SE runs only as a trial — fine for labs, but it must not be presented as production guidance.
- 2.0.0 and 3.0.0 bring Linux guests and an internet-facing service: separate threat review (ADR) before coding.

### Found in host run seven (2026-11-17) - not yet scheduled
- The Windows 11 LTSC evaluation ISO that Microsoft serves (26100.1742, Sept 2024) has expired: workstations shut down one hour after
  every boot. Candidates: a validation check "Windows licence not expired" on every VM; tester-supplied licensed Windows 11 ISO (as for
  Windows 10) with optional product key / KMS host.
- Explicit adprep support so an additional DC may run a newer Windows Server than the forest root (today refused by Test-LabConfig).
