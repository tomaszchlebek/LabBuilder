# ADR 0007: Run directly on the Hyper-V host; PowerShell Direct into VMs

- **Status:** Accepted (supersedes [ADR 0002](0002-execution-model-winrm-and-powershell-direct.md))
- **Date:** 2026-11-14

## Context
ADR 0002 planned an orchestrator on a tester workstation that drives a remote host over WinRM. The requester then clarified:
*"This application will be run directly from any Hyper-V host"*, and earlier that ISOs are downloaded first to the machine
the test deployments run on. The lab network is isolated (ADR 0005), so even the host cannot reach the VMs over IP.

## Decision
- The tester copies (or clones) the project to the **dedicated Hyper-V host** and runs `scripts\Invoke-LabBuild.ps1` in an
  **elevated** Windows PowerShell 5.1 (or 7) console there. No WinRM, no remote sessions, no credentials for the host.
- The build runs **phase by phase** in-process: `Preflight, Iso, BaseImages, Network, DomainController, IisServer, Workstations, Validate`.
  Each phase is **idempotent** (check, then act), so a failed build is resumed by re-running it; `-Phase` runs selected phases.
  `<LabRoot>\state.json` records completed phases.
- Inside VMs, all configuration uses **PowerShell Direct** (`Invoke-Command -VMName`) over VMBus — no network needed.
  Config and account plan go into VMs as JSON strings; credentials as `PSCredential`.
- Reboots are graceful `Stop-VM` / `Start-VM` from the host, then the build waits until PowerShell Direct answers.
- ISOs are downloaded on the host into `<LabRoot>\ISO` (phase `Iso`), or pre-downloaded anywhere with `scripts\Get-LabIso.ps1`
  and imported with `-IsoSource` (ADR 0003).
- Output (credentials, logs, summary, validation report) is written next to the project on the host in `output\<LabName>\`.

## Alternatives considered
- **Remote orchestration over WinRM (ADR 0002)** — not needed when the tester works on the host; adds WinRM setup,
  double-hop and large file copies over WinRM.
- **AutomatedLab / Lability** — third-party modules (NFR-1), much larger than this need.

## Consequences
- Requires a Windows 10/11 Pro/Enterprise or Windows Server 2019+ host with the Hyper-V role and PowerShell module.
- The tester needs local administrator rights on the host and a console session there (RDP or local).
- Simpler and fewer failure points: no WinRM, no copy of the module to the host.
