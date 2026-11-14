# ADR 0002: Execution model — workstation orchestrator, WinRM to host, PowerShell Direct into VMs

- **Status:** Superseded by [ADR 0007](0007-run-directly-on-the-hyper-v-host.md)
- **Date:** 2026-11-14

> Superseded the same day, before any code was released: the requester clarified that the application is run
> **directly on any Hyper-V host**, so the WinRM/remote part below was dropped. PowerShell Direct into VMs is kept (ADR 0007).

## Context
The tester supplies a dedicated Hyper-V host and its connection details, and starts the build from their own workstation
(this PC or another one later). The lab network must be isolated (ADR 0005), so the host and the workstation cannot reach the VMs over IP.

## Decision
- **Orchestrator** `scripts/Invoke-LabBuild.ps1` runs on the tester workstation in Windows PowerShell 5.1.
  It validates inputs, downloads ISOs (ADR 0003), generates secrets (ADR 0006) and runs the build **phase by phase**.
- It connects to the host with **WinRM** (`New-PSSession`, Kerberos/Negotiate, optional HTTPS), copies the `LabBuilder`
  module to `<LabRoot>\LabBuilder` on the host, and runs one `Invoke-Command` per phase.
  If the host is `localhost`, the phases run in-process (no WinRM).
- Inside VMs, all configuration uses **PowerShell Direct** (`Invoke-Command -VMName`) over VMBus — no network needed.
- Config and the account plan go over the wire as **JSON strings** (no serialization-depth surprises); credentials as `PSCredential`.
- Phases: `Preflight, Iso, BaseImages, Network, DomainController, IisServer, Workstations, Validate`.
  Each phase is **idempotent** (check, then act), so a failed build is resumed by re-running it; `-Phase` runs selected phases.
- Reboots are graceful `Stop-VM` / `Start-VM` from the host, then the build waits until PowerShell Direct answers.

## Alternatives considered
- **Run everything on the host by hand (RDP)** — still supported (`-HyperVHost localhost`), but not the default; the brief has the tester provide connection details.
- **AutomatedLab / Lability** — capable, but third-party modules from the PowerShell Gallery (NFR-1) and much larger than this need.
- **WinRM into the VMs over the network** — needs a route from the host into the lab, which breaks isolation.
- **One long `Invoke-Command` for the whole build** — a dropped session would lose all progress; per-phase calls limit the damage.

## Consequences
- Needs WinRM enabled on the host and an account in the host's local Administrators group.
- PowerShell Direct needs a Windows 10/Server 2016+ host and guests — true for all supported versions.
- The tester workstation must stay connected during each phase; any phase can be re-run.
