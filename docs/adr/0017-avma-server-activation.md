# ADR 0017: Activate Windows Server VMs with AVMA (offline edition conversion of the base images)

- **Status:** Accepted
- **Date:** 2026-11-17

## Context
Host run `seven` (1.4.2 licence check) showed that every Windows Server VM built from the Microsoft evaluation ISOs has only
**10 days**: an evaluation gets its 180 days only after online activation, and the lab is isolated (Private switch). After that the
servers would shut down every hour (wlms.exe), as the expired Windows 11 LTSC evaluation workstations already do.
The tester's host ITOMHV01 runs Windows Server 2025 **Datacenter**, activated. Microsoft's Automatic Virtual Machine Activation (AVMA)
lets an activated Datacenter Hyper-V host activate Windows Server guests (2025 host: 2025, 2022, 2019, 2016, 2012 R2; all editions)
over the Data Exchange (KVP) integration service, without network access, using public generic AVMA keys.
Constraints (Microsoft Learn "Convert Windows Server editions and license types"): an AVMA key does not install on an
**evaluation** edition - it must be converted to retail first (`DISM /Set-Edition`); **a domain controller cannot be converted**.

## Decision
- New option `Build.Avma` (default `$true`; wizard *Build options*: "Activate Windows Server VMs with AVMA").
- Phase BaseImages converts each Windows Server library base image **offline**, once: `DISM /Image:<mounted> /Set-Edition:ServerStandard
  /ProductKey:<key> /AcceptEula` on a copy, then replaces the base; sidecar `Edition = ServerStandard`, `Activation = AVMA`, new
  `CreatedUtc` (role images are copies of the base and rebuild from it). Conversion key: 2025/2022 the AVMA key, 2019 the KMS client
  setup key (DISM rejects the 2019 AVMA key offline).
- Every server VM - root DC, additional DCs (before promotion), member servers - installs the AVMA key (`slmgr /ipk`) and activates
  (`slmgr /ato`) right after its network setup. Idempotent; never fails the build (warning instead).
- Skipped with a warning: host not Datacenter / not activated / older than the guest OS; base used by differencing disks; DISM error.
  The base then stays an evaluation (behaviour as before).
- Keys live in `Public\Activation.ps1` (Microsoft's public generic keys, not secrets), not in the lab config.
- Windows client (workstations) is out of scope: AVMA activates Windows Server only; a client evaluation cannot be converted.

Verified before implementation on ITOMHV01 with throwaway VMs (no network): Server 2025 converted offline with its AVMA key and
activated ("Licensed", guest event 12309 / host event 12310 hr=0x0, 7-day AVMA renewal); Server 2019 converted with the KMS client key,
AVMA key installed in the VM, activated; Server 2022 converted offline. AVMA did not activate by itself within 3 minutes - `slmgr /ato`
does it immediately, hence the explicit step.

## Alternatives considered
- **Online conversion in each VM** (`DISM /online /Set-Edition`): slow (several minutes and restarts per VM) and impossible on DCs.
- **`slmgr /rearm`**: only postpones the end a few times; not a licence.
- **Temporary internet access for online activation**: breaks the lab's isolation (ADR 0007).
- **Tester-supplied retail ISO + key**: not chosen by the requester; would still need per-version keys.

## Consequences
- Lab servers stay activated as long as they run on an activated Datacenter host; the validation check shows "licensed (AVMA, renewed
  by the host)" instead of the evaluation days left.
- Licensing is the host's Datacenter licence (unlimited Windows Server VMs on that host) - AVMA is Microsoft's proof-of-purchase
  mechanism, not a workaround. On a Standard host the option does nothing (warning).
- Existing evaluation base images are converted on the next build unless differencing disks use them; existing evaluation VMs are not
  changed (DCs cannot be converted) - those labs need a rebuild to be activated.
- Workstations from the expired Windows 11 LTSC evaluation still shut down hourly.
