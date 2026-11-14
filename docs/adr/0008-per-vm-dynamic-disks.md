# ADR 0008: Per-VM dynamic VHDX copied from the base image and sized by the tester

- **Status:** Accepted (supersedes the *differencing disk* part of [ADR 0004](0004-vm-build-from-base-vhdx.md))
- **Date:** 2026-11-14

## Context
The requester wants the tester to choose each VM's disk size, and disks must **always be dynamic**. ADR 0004 gave each VM a
differencing disk on a shared base, so every VM had the base's size and depended on the base file.

## Decision
- The base VHDX (from `install.wim`, ADR 0004) is built small: **32 GB dynamic**, read-only.
- For each VM the base is **copied** to `<LabRoot>\VMs\<VM>\<VM>-os.vhdx` (a **dynamically expanding** VHDX), the read-only
  flag is cleared, the disk identifier is reset (`Set-VHD -ResetDiskIdentifier`), and the disk is **expanded** with `Resize-VHD`
  to the tester's size. While the copy is mounted to inject `unattend.xml`, the Windows partition (last on the disk) is
  extended to the maximum with `Resize-Partition`, so no step inside the guest is needed.
- Minimum sizes: servers 40 GB, workstations 64 GB (Windows 11 requirement); maximum 2 TB.

## Alternatives considered
- Differencing disks + `Resize-VHD` — not a plain dynamic disk and depends on the base file (rejected by requirement).
- Applying `install.wim` to every VM disk — 5–10 min per VM instead of ~1 min copy.
- Fixed-size disks — rejected by requirement.

## Consequences
- More host disk space: each VM starts at ~10–14 GB instead of a few hundred MB.
- VMs are independent of the base image; base images can be rebuilt without breaking existing VMs.
- `MinFreeGB` default raised to 150.
