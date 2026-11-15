# ADR 0014: Parallel build, differencing disks as an option, live VM progress

- **Status:** Accepted (amends [ADR 0008](0008-per-vm-dynamic-disks.md): differencing disks become an opt-in alternative)
- **Date:** 2026-11-15

## Context
Release 1.3.0 (roadmap: old 1.1.6, "speed up the build by running tasks in parallel ... extract / copy once and use many times").
Until 1.2.0 everything after VM creation ran one VM at a time: downloads, base images, member-server configuration and workstation
joins. The tester's 1.2.0 run took ~9 min for 4 ISOs and ~13.5 min for 4 base images strictly in sequence; each extra server or
workstation added its full configuration time. Requester decision D5: differencing disks are offered **as an option**, plain dynamic
copies stay the default. The 3.0.0 web UI will need machine-readable progress.

Constraints: Windows PowerShell 5.1 (no `ForEach-Object -Parallel`), inbox tooling only, phases stay idempotent and resumable.

## Decision
1. **Engine `Invoke-LabParallel`** (Private/Parallel.ps1): a runspace pool in the build process. Each worker imports the LabBuilder module,
   uses the same log files plus a per-VM log (`<LabRoot>\Logs\vm-<VMName>.log`) and prefixes its log lines with `[<item>]`. The parent
   relays the workers' host output (Information stream) and warnings live, so the console, transcript and wizard see one stream.
   Every item runs to completion; failures are collected and reported together (`N of M failed: ...`); the phase then fails and a
   re-run resumes (finished VMs are skipped by the existing idempotency checks).
   Throttle: `Build.ThrottleLimit` (0 = auto: half the logical processors, 2..8). `Build.Parallel = $false` runs the same code one
   item at a time in the build process (fallback / troubleshooting).
2. **What runs in parallel:** phase Iso (one item per ISO; library locks from ADR 0013 still apply), phase BaseImages (one item per OS,
   throttle 2 - disk bound), creation of all VMs of a phase (disk copy/differencing disk + unattend injection), member servers after the
   **CA servers** (role ADCS configured first, sequentially - HTTPS needs the CA), and all workstations. The forest root and the
   additional DCs stay sequential (forest creation order; replication).
3. **Shared-state locks** (named mutexes, process wide): log file writes; mounting a VHD to inject unattend.xml (copies/children of one
   base share the GPT disk GUID - one mounted at a time); the certificate-template ACL change + CertSvc restart (read-modify-write of one
   ACL - concurrent IIS servers would lose each other's Enroll ACE).
4. **Differencing disks (option, D5):** `Disks.Type = 'Dynamic'` (default, ADR 0008) or `'Differencing'`: the VM disk is a differencing
   VHDX whose parent is `<Library>\BaseImages\<OS>.vhdx`, expanded with `Resize-VHD` to the tester's size, Windows partition extended as
   before. Seconds instead of minutes per VM and a few hundred MB instead of ~12 GB. The library protects such parents: a base image
   used by any VM's differencing disk is never rebuilt (an ISO change only warns) and never deleted by `Remove-Lab.ps1 -IncludeLibrary`.
   Validation accepts disk type `Differencing` with an existing parent when the lab uses the option. `lab.json` records the disk type.
5. **Progress events:** `Write-LabProgress -Phase -Item -Status [-Detail]` writes one JSON object per event to
   `<LabRoot>\Logs\progress.jsonl` and prints it as a line starting `##LBP ` (no secrets). Statuses: `creating`, `starting`,
   `configuring`, `joining`, `roles`, `promoting`, `ready`, `failed`, `skipped`. The wizard hides these lines from the log and shows a
   **VM | Status** list under the phase list.
6. **Wizard:** "Build options" on the *Install & lab* page: build in parallel (default on), VM disks: independent dynamic copies (default)
   or differencing disks (with a note on the dependency).

## Alternatives considered
- **`Start-Job`** - one PowerShell process per item (slower start, credentials re-serialised, output only after polling); runspaces share
  the process and stream output live.
- **Parallel additional DCs** - possible, but promotion order/replication problems would cost more than the minutes saved for 1-5 DCs.
- **Differencing disks by default** - the requester requires plain dynamic disks; VMs would depend on library files.
- **Progress only from log text** - fragile parsing; structured events are reusable by the web UI (3.0.0).

## Consequences
- + Build time is dominated by the slowest VM instead of the sum of all VMs; ISO/base preparation overlaps.
- + Optional differencing disks make large labs fast and small on disk.
- + Live per-VM status in the wizard; `progress.jsonl` for later front ends.
- − More load at once on the host (disk, RAM during boot); throttle and `Build.Parallel = $false` mitigate.
- − Logs of parallel VMs interleave (each line prefixed; per-VM log files help).
- − Differencing labs break if their base image is moved or deleted outside LabBuilder.
