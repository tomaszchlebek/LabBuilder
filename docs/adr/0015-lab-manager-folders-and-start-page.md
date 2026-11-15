# ADR 0015: Lab manager - app/labs/library folders, start page (new / edit / delete), one folder per lab

- **Status:** Accepted (design 2026-11-15; requester decisions D6-D8 below; implementation = release 1.4.0 after 1.3.0)
- **Date:** 2026-11-15

## Context
Requester (2026-11-15), during the 1.3.0 host test:
1. When the tester runs the app, the wizard asks whether to **create a new lab or edit an existing lab**.
2. On the **first run** the wizard sets the app folders: **App folder**, **Labs folder**, **Library folder**.
3. The wizard **scans the Library folder** for previously imported ISOs and base images.
4. **Each new lab is created inside the Labs folder in its own subfolder.**

Today (1.3.0): one config `<App>\config\lab.config.psd1` for every lab (a second lab overwrites the first lab's settings - happened with
TESTLAB -> DIFFLAB), credentials in `<App>\output\<Lab>`, the lab folder (LabRoot) is typed per lab anywhere on the host, and the
roadmap's 1.4.0 ("discover existing labs, delete a chosen lab") needs exactly this inventory. So the redesign and 1.4.0 are one release.

## Decision (proposed)
1. **Host settings** `%ProgramData%\LabBuilder\settings.json` (machine-wide, no secrets): `AppFolder` (default `C:\LabBuilder`),
   `LabsFolder` (default `<data drive>:\LabBuilder-Labs`), `LibraryFolder` (default `<data drive>:\LabBuilder-Library`), version,
   registered external labs. Missing file = **first run**: a *Folders* page sets the three folders (free space shown per drive),
   creates them and writes the file. Later runs show the folders read-only with a *Change folders...* button (changing the Labs or
   Library folder does not move existing content - it is refused while labs/differencing disks still use the old one).
2. **Start page** (after the prerequisite check):
   - **Create a new lab** -> the existing pages (lab folder no longer asked: it is `<LabsFolder>\<LabName>`).
   - **Edit an existing lab** -> list of discovered labs (name, domain, VMs, OS mix, disk type, state, size on disk, last build); the
     chosen lab's own config is loaded; lab name and domain are read-only (a built forest cannot be renamed); servers/workstations can be
     added, roles/features added, sizes changed only for VMs not created yet. Removing a VM from the list does not delete it (that is
     *Delete*). Then *Summary -> Build* resumes/extends the lab (idempotent phases).
   - **Delete a lab** (roadmap 1.4.0) -> preview of what goes (VMs, checkpoints, disks, switch if unused, lab folder incl. credentials),
     typed lab name to confirm; never the library; base images stay.
   - **Image library** -> inventory only (see 4).
3. **One folder per lab** `<LabsFolder>\<LabName>\`: `lab.config.psd1` (the lab's own config, BaseConfig = `<App>\config\lab.config.example.psd1`),
   `lab.json`, `state.json`, `VMs\`, `Logs\` (build + per-VM + progress.jsonl), `Reports\`, `output\` (credentials: `lab-admin.cred.xml`,
   `lab-accounts.csv`, `lab-sql.csv`, summary, validation reports - same ACL protection as today). `Paths.LabRoot` is derived from the
   Labs folder and lab name; scripts get `-LabPath <LabsFolder>\<LabName>` (or `-ConfigPath` as today for compatibility).
4. **Library scan** (`Get-LabLibraryInventory`): reads `<Library>\ISO\iso-manifest.json` and `<Library>\BaseImages\*.vhdx.json`; lists per
   OS: ISO present/verified (size, SHA-256, date), base image present (build number, language, date), used by which labs (incl.
   differencing parents), plus unknown ISO files in the folder (offered for verification/import). Shown on the start page and the ISO
   page; OS lists in the server/workstation grids mark "in library" vs "download ~X GB".
5. **Discovery** (`Get-LabInventory`): labs = subfolders of the Labs folder with `lab.json`, plus registered external labs (1.0-1.3 labs
   outside the Labs folder), plus VMs tagged `LabBuilder:<Lab>` without a known folder (shown as "orphaned VMs" with a delete option).
6. **Existing labs (migration):** stay where they are - no VM storage is moved. On the first 1.4.0 run each found lab is **registered**
   (path in settings.json). If its config is missing (overwritten by another lab, like TESTLAB), the wizard **reconstructs** it from
   `lab.json` + Hyper-V (VM names, OS, IPs, vCPU/RAM/disk) and asks the tester to confirm the roles before it can be edited; it can always
   be deleted. Credentials stay in `<App>\output\<Lab>` for such labs (path recorded).
7. **Command line** keeps working: `Invoke-LabBuild.ps1 -ConfigPath ...` as today; new `-LabName <Lab>` resolves
   `<LabsFolder>\<Lab>\lab.config.psd1` from settings.json; `Remove-Lab.ps1 -LabName <Lab>`; `Get-LabInventory`, `Get-LabLibraryInventory`
   for scripts and the 3.0.0 web UI.

## Alternatives considered
- **Keep one global config + Load/Save** - the cause of the overwrite problem; editing needs the lab's own config next to the lab.
- **Settings in the App folder only** - the App folder is chosen in the wizard; a fixed machine location is needed to find it again.
  The App folder also gets a copy for visibility.
- **Move existing labs into the Labs folder** - `Move-VMStorage` of every VM is slow and risky for a cosmetic gain; registering in place
  keeps them working.
- **Free-form lab folder per lab (today)** - labs end up anywhere; discovery and deletion would depend on guessing.

## Consequences
- + New/edit/delete from one start page; every lab self-contained in one folder (easy to back up or delete).
- + The library is visible: testers see which OS images are ready before building.
- + Foundation for the 3.0.0 web UI (same inventory functions).
- - Larger wizard change (start page, folders page, edit mode, delete flow, reconstruction of lost configs).
- - Two layouts exist on hosts that already have 1.0-1.3 labs (registered external labs) until those labs are deleted.

## Requester decisions (2026-11-15)
- **D6** Schedule: release **1.4.0**, merged with lab discovery/deletion, started after 1.3.0 passes the host test and is published;
  host compatibility moves after it.
- **D7** Existing labs (TESTLAB in `D:\HyperVLab`, DIFFLAB in `D:\HyperVLab-Diff`): **registered in place**, nothing moved.
- **D8** Default folders: **`C:\LabBuilder`** (app), **`<data drive>:\LabBuilder-Labs`**, **`<data drive>:\LabBuilder-Library`**
  (data drive = D: if present, else C:).

## Implementation notes (release 1.4.0, 2026-11-15)
- Module `Public/LabManager.ps1`: `Get-LabHostSettings` / `Set-LabHostSettings`, `Get-LabOutputPath` (`Paths.OutputPath`, new labs
  `<LabRoot>\output`), `Get-LabInventory` (Labs folder, registered labs, labs discovered from tagged VMs: lab folder = parent of `VMs`),
  `Register-LabExternal`, `Get-LabLibraryInventory`, **`Restore-LabLegacyConfig`** (the old shared `<App>\config\lab.config.psd1` and the
  wizard's `.bak-<time>` copies are searched for the newest file with the same LabName + LabRoot - preferred over reconstruction because it
  keeps the roles), `New-LabConfigFromInventory` (fallback), `Remove-LabFromInventory` (deletes only the lab's own files/folders; library
  files are never deleted, foreign files keep the folder).
- `scripts/Get-LabInventory.ps1` (JSON back end for the wizard: `-SaveSettings`, `-RegisterDiscovered`, `-ReconstructConfig`),
  `Invoke-LabBuild.ps1 -LabName`, `Remove-Lab.ps1 -LabName [-Force]`.
- Wizard: pages *Folders* (first run / "Change folders..."), *Start*, *Delete lab*, *Image library* (`installer/src/LabManagerPages.cs`,
  `WizardForm` is a partial class); the former *Install & lab* page is *Lab* (paths read-only from the host settings); Edit locks name,
  domain, network and disk type (NetBIOS editable only for a reconstructed config); the lab's config is written to its lab folder.
