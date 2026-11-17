# ADR 0016: Role-ready base images (offline, no sysprep) and VM creation during the forest promotion

- **Status:** Accepted
- **Date:** 2026-11-15

## Context
Requester: "Promoting domain controller takes too much time same as adding certificate authority - can you speed up for example by
creating base image" (roadmap 1.4.1). In the host runs the forest root took ~10 min incl. the online AD DS feature install, the CA
another few minutes incl. the AD CS feature install; fresh VMs sometimes failed the first feature install with "Windows servicing busy"
(0x80071A2D). Member servers and workstations were only created after the whole DomainControllers phase.

The roadmap plan was a booted temporary VM with the roles installed, then `sysprep /generalize /oobe /mode:vm`. Microsoft's
[Sysprep Support for Server Roles](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/sysprep-support-for-server-roles)
lists **AD CS and AD DS as not supported** with sysprep ("those roles may not function after the imaging and deployment process").
A pre-promoted forest image is not possible either (every lab has its own domain name, SID, krbtgt and passwords).

## Decision
1. **Role-ready base image without sysprep:** `<Library>\BaseImages\<OS>-Roles.vhdx` = copy of the plain `<OS>.vhdx` (which was
   applied from `install.wim` and never booted), mounted on the host, and the optional features of AD DS, DNS and AD CS (+ their
   management tools where the build has them) enabled **offline** with `Enable-WindowsOptionalFeature -Path <mount> -All -LimitAccess`.
   It is never booted and never sysprepped: Windows completes the enablement during the first boot of each VM (specialize), like
   features added to any offline image. One image per server OS in use by a DC or an ADCS server; built once, shared by all labs,
   under the library lock; sidecar records parent, parent creation time, features, version, language. Rebuilt when the plain base
   changes (unless differencing disks use it, ADR 0014). Listed in the wizard's image library view.
2. **Used by DCs and ADCS servers only** (`Get-LabVmBaseImageKey`); other servers and workstations keep the plain base. The online
   `Install-WindowsFeature` step (with the servicing retry, 1.2.0) **still runs** and finishes in seconds - it adds whatever the
   offline step did not (e.g. management tools) and is the safety net.
3. **Fallback:** if the role image cannot be built (DISM error, feature missing, mount failure) a warning is logged, nothing is left
   behind, and DCs/CA servers use the plain base exactly as before.
4. **Create the other VMs during the promotion:** with the parallel build on, phase DomainControllers runs two tasks - the DC chain
   and, once the DC VMs exist, the creation of all member-server and workstation VMs - so their first boot is done when the domain is
   ready. Their configuration stays in their phases.
5. Option `Build.RoleImages` (default `$true`; wizard: Build options) switches 1 and 4 off.

## Alternatives considered
- **Sysprep a booted VM with the roles installed** - unsupported by Microsoft for AD DS / AD CS (rejected after checking the table).
- **Pre-promoted forest image** - one fixed domain identity for every lab (rejected).
- **Enable the features offline per VM** while its disk is mounted for unattend.xml - repeats the work for every VM and keeps the
  host-wide VHD mount lock for minutes; once per OS is cheaper.
- **Install the roles in parallel with something else on the same DC** - the DC chain is strictly sequential.

## Consequences
- + DC and CA servers skip most of the feature installation; no first-boot "servicing busy" failures on that step.
- + Member servers and workstations are booted and ready when the domain exists.
- - One extra image per server OS in the library (~ the size of the plain base) and a few minutes the first time.
- - The first boot of a DC/CA VM is a little longer (Windows finishes the offline-enabled features during specialize).
- - Not verified in the development environment (needs Hyper-V + elevation); the fallback keeps the old behaviour if it fails.

## Revision after the host test (2026-11-17)
The first 1.4.1 host run (lab `six`) failed at the forest promotion: **"Verification of prerequisites for Domain Controller promotion
failed. Certificate Server is installed."** A server with the AD CS binaries cannot be promoted, and a CA must not change domain
membership after AD CS is installed. Changes:
- The role image holds **AD DS + DNS only** (feature set `ADDS-DNS/2` recorded in the sidecar) and is used **only for domain
  controllers**; AD CS is always installed online after the promotion / domain join (as before 1.4.1).
- Role images with another feature set (the 1.4.1 test images with AD CS) are outdated: never used for new VMs, rebuilt when no
  differencing disk uses them.
- `Remove-LabUnconfiguredCa` runs before every DC promotion: AD CS binaries without a configured CA are uninstalled and the VM restarted,
  so a lab created from the faulty image (lab `six`) can simply be resumed.
Resumed run (07:25-07:44): the AD CS removal worked on both DCs and the forest was created in about 2 min (12.3 min in run `five`).
DC02 (Server 2025) then failed to join the Server 2022 forest in adprep (RPC / access denied). Not a role-image problem: a DC newer than
the forest root needs a schema update. Decision: `Test-LabConfig` rejects additional DCs with a newer Windows Server than DC 1; explicit
adprep support is a possible later roadmap item.
What the run confirmed: role images built offline (Server2022 1.4 min, Server2025 6.4 min), DC01 from its role image ready in 1.6 min
(3.6 min from the plain base in run `five`), the 6 other VMs created in 30 s during the promotion.
