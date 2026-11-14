# ADR 0004: Build VMs from base VHDX images with differencing disks and unattend.xml

- **Status:** Accepted — disk handling amended by [ADR 0008](0008-per-vm-dynamic-disks.md) (per-VM dynamic copies instead of differencing disks)
- **Date:** 2026-11-14

## Context
Booting a Generation 2 VM from a Microsoft ISO stops at "Press any key to boot from CD or DVD", and changing that needs `oscdimg`
from the Windows ADK (not inbox, NFR-1). A full Windows Setup per VM is also slow (5 VMs).

## Decision
- Phase `BaseImages` mounts each ISO on the host, picks the image whose name matches `ImageNamePattern`
  (default Server: `*Standard*Desktop*`; client: `*Enterprise*`), and **applies it to a GPT base VHDX**
  (EFI + MSR + Windows partitions, `Expand-WindowsImage`, `bcdboot /f UEFI`). The image in `install.wim` is generalized,
  so the base disk boots straight into specialize/OOBE. The base VHDX is marked read-only.
- Each VM gets a **differencing disk** on its base. Before first boot the build mounts the child disk and writes
  `Windows\Panther\unattend.xml` (computer name, locale, time zone, admin password encoded in unattend format, Windows 11:
  local `LabAdmin` account and hidden online-account screens).
- VMs are Generation 2, Secure Boot (`MicrosoftWindows` template), static memory by default, no automatic checkpoints.
  Windows 11 VMs get a **vTPM** (local key protector) to meet Windows 11 requirements.
- IP address, DNS, domain join, roles are configured after first boot with PowerShell Direct (ADR 0007), not in unattend,
  so each step is checked and logged. `unattend.xml` is deleted from the VM afterwards (secrets).

## Alternatives considered
- ISO boot + autounattend — prompt on Gen2 / needs ADK; slow.
- Gen1 VMs (BIOS boot, no prompt) — no Secure Boot/TPM; Windows 11 needs both.
- Full copies instead of differencing disks — 5 × ~15 GB more disk and slower; differencing is fine for a disposable lab.
- Sysprep'd custom golden images — extra maintenance; the Microsoft image is already generalized.

## Consequences
- Base images must not be changed while VMs use them (read-only flag); delete VMs before rebuilding a base (`Remove-Lab.ps1 -IncludeBaseImages`).
- Fast: each VM is ready in a few minutes.
- `bcdboot` runs on the host; the host should be Windows Server 2019 / Windows 10 1809 or newer.
