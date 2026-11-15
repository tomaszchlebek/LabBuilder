# Build TEST environment (LabBuilder)

Automated build of an **isolated lab test environment on Hyper-V**, run directly on the dedicated Hyper-V host,
driven by a Windows **setup wizard (`LabBuilderSetup.exe`)** where the tester chooses everything:

- **Active Directory forest** with **1–5 domain controllers** (your FQDN + NetBIOS name, DNS on every DC)
- **Member servers** (0–10) with the **roles you tick per server**: AD CS (Enterprise Root CA), IIS (HTTPS from the lab CA),
  DHCP, File Server, **SQL Server 2025 Express** (unattended, with your SQL options) — plus any extra Windows features
- **Operating system per server**: Windows Server **2025, 2022 or 2019** (evaluation)
- **Workstations** (0–20), domain-joined, vTPM + Secure Boot: **Windows 11 Enterprise LTSC**, or **Windows 10 Enterprise**
  from your own ISO (Microsoft no longer offers a Windows 10 evaluation)
- **Dedicated domain admin accounts** and **domain test users** (random names, generated passwords), security groups,
  optional local-admin rights for the testers
- vCPU, RAM and **dynamic** disk size per server and for the workstations
- **Isolated** (Private switch) or **host-reachable** (Internal switch) network — tester's choice
- VM regional settings and time zone **taken from the Hyper-V host**
- OS media **downloaded from the Microsoft Evaluation Center**, verified (HTTPS, Microsoft hosts only, size, SHA-256)
  and kept in a **shared image library** on the host: each ISO is downloaded and each base image built **once** and
  reused by every later lab
- Each lab records itself in `<lab folder>\lab.json` and tags its VMs (`LabBuilder:<LabName>` in the VM notes)
- **Parallel build** (VMs created and configured at the same time) with a live per-VM status list, and optional **differencing
  disks** (VM disks in seconds, a few hundred MB each)
- Post-build **validation report**

## Quick start

1. Download `LabBuilderSetup.exe` from the [latest release](https://github.com/tomaszchlebek/LabBuilder/releases/latest) (or build it: `installer\build.ps1`), copy it to the Hyper-V host and run it (it asks for administrator rights).
2. Answer the wizard pages: install folder → domain → network → domain controllers → member servers & roles →
   accounts → workstations → ISOs → summary.
3. Click **Install & build** and watch the progress. Credentials, summary and validation report are in
   `<install folder>\output\<LabName>\`.

Scripts can also be used directly (elevated PowerShell on the host):

```powershell
.\scripts\Invoke-LabBuild.ps1 -DomainFqdn lab.test -DomainNetbios LABTEST
```

Full instructions: [docs/RUNBOOK.md](docs/RUNBOOK.md).

| File | Purpose |
|------|---------|
| `installer\bin\LabBuilderSetup.exe` | Setup wizard (built by [`installer/build.ps1`](installer/build.ps1)) |
| [`scripts/Invoke-LabBuild.ps1`](scripts/Invoke-LabBuild.ps1) | Build / resume the lab — phases Preflight → Iso → BaseImages → Network → DomainControllers → MemberServers → Workstations → Validate |
| [`scripts/Get-LabIso.ps1`](scripts/Get-LabIso.ps1) | Pre-download and verify the ISOs on any machine |
| [`scripts/Test-LabConfigFile.ps1`](scripts/Test-LabConfigFile.ps1) | Validate a config file (used by the wizard) |
| [`scripts/Remove-Lab.ps1`](scripts/Remove-Lab.ps1) | Tear the lab down |
| [`config/lab.config.example.psd1`](config/lab.config.example.psd1) | All settings with defaults |

## Requirements

Hyper-V host: Windows Server 2019+ or Windows 10/11 Pro/Enterprise with Hyper-V and its PowerShell module,
Windows PowerShell 5.1, .NET Framework 4.8 (for the wizard), disk and RAM for the VMs you choose
(default lab: ~12 GB RAM, ~150 GB disk), internet access for the ISO download (or pre-downloaded ISOs).
No third-party software — neither to run nor to build.

## Development

```powershell
Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester .\tests   # unit tests, no Hyper-V needed
.\installer\build.ps1                                                  # builds installer\bin\LabBuilderSetup.exe with inbox csc.exe
.\scripts\Publish-LabRelease.ps1 -Message 'feat: ...' -WhatIf          # maintainers: dry run of a GitHub release
```

Planned versions: [docs/ROADMAP.md](docs/ROADMAP.md).

## Documentation

| Document | Content |
|----------|---------|
| [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) | Goal, tester inputs, functional and non-functional requirements |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layout, components, phases, roles, identities, traceability |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | How to install, build, use, troubleshoot and remove the lab |
| [docs/adr/](docs/adr/) | Architecture Decision Records 0001–0011 |
| [docs/DEVLOG.md](docs/DEVLOG.md) | Development log — every step |
| [CHANGELOG.md](CHANGELOG.md) | Changes per version |
| [CLAUDE.md](CLAUDE.md) | Working rules (documentation discipline, code conventions) |

## License

[MIT](LICENSE) - free to use, change and share, with no warranty. Windows evaluation media are subject to Microsoft's own licence terms.
