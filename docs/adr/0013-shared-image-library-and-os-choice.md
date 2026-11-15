# ADR 0013: Shared image library, OS choice per VM and lab manifest

- **Status:** Accepted (amends [ADR 0003](0003-iso-source-and-verification.md) and [ADR 0008](0008-per-vm-dynamic-disks.md) — storage location only)
- **Date:** 2026-11-15

## Context
Release 1.2.0 (roadmap: old 1.1.3 + 1.1.5) asks for two things that touch the same code:
1. **Create base images once and use them for any future lab.** Until 1.1.x, ISOs lived in `<LabRoot>\ISO` and base images in
   `<LabRoot>\BaseImages\<LabName>-<Server|Client>-base.vhdx` — a second lab (another LabRoot or LabName) downloaded and built
   everything again.
2. **Choose the OS** of servers (Windows Server 2019, 2022, 2025) and workstations (Windows 10, 11). On 2026-11-15 the Evaluation
   Center still offers Server 2019 and 2022 ISOs (go.microsoft.com fwlinks resolving to `software-static.download.prss.microsoft.com`,
   already allow-listed); Windows 10 Enterprise evaluation is gone (page redirects to the end-of-support post). Requester decision D1:
   Windows 10 only from an ISO the tester supplies.

The roadmap also asks for a **lab manifest and VM tags** now, so that lab discovery (1.4.0) needs no guessing.

## Decision
1. **OS catalog** in `Iso.Images` (example config): keys `Server2025`, `Server2022`, `Server2019` (Kind `Server`; Standard,
   Desktop Experience), `Win11LTSC` and `Win10` (Kind `Client`). Each entry: Description, SourcePage, Url, FileName,
   ExpectedSha256, ImageNamePattern, **CaptionPattern** (checked by validation). `Win10` has `Supplied = $true`, no Url, and
   `SourcePath` = the tester's ISO.
2. **OS per VM:** each domain controller / member server may set `Image` (default `Iso.DefaultServerImage` = `Server2025`);
   all workstations share `Workstations.Image` (default `Win11LTSC`). VM definitions carry `Image` (catalog key) and `Kind`
   (Server/Client: unattend template, local admin, vTPM). Forest/domain functional level stays 2016 (`WinThreshold`), valid
   for every catalog server OS.
3. **Image library** `Paths.LibraryRoot` (default `<LabRoot drive>:\LabBuilder-Library`), shared by all labs on the host:
   `ISO\` (ISOs + `iso-manifest.json`, `SQL\` package) and `BaseImages\<Key>.vhdx` + sidecar JSON (image, version, language,
   **ISO SHA-256**). A base image is rebuilt only if its ISO hash changed. Each download/import/base build holds a named
   mutex per image (`Global\LabBuilder-Library-<Key>`), so concurrent lab builds never build or download the same item twice
   and never delete each other's work in progress.
4. **Migration:** phase Iso moves 1.0/1.1 ISOs and SQL media from `<LabRoot>\ISO` into the library (Move-Item on the same
   volume, verified copy otherwise); phase BaseImages adopts `<LabRoot>\BaseImages\<Lab>-Server|Client-base.vhdx` as
   `Server2025` / `Win11LTSC` when its sidecar names the same ISO file. Nothing is downloaded or built again.
5. **Tester-supplied ISO (Windows 10):** copied into the library as `Windows10-supplied.iso`, hashed and recorded with its source
   path, size and time; a different source file replaces it (and its base image is rebuilt via the hash check). The Windows
   image inside is matched by `ImageNamePattern` (`Windows 10 Enterprise*`, LTSC included).
6. **VM disks** are still independent dynamic copies of the base (ADR 0008); only the base location changes.
7. **Lab manifest** `<LabRoot>\lab.json` (no secrets): lab name, LabBuilder version, LabRoot, LibraryRoot, switch, domain,
   created/updated, last phase, VMs (name, VM name, role, OS key, IP). Every VM's notes start with `LabBuilder:<LabName>`.
8. **Teardown:** `Remove-Lab.ps1` never touches the library unless `-IncludeLibrary` is given: it then deletes the ISOs and base images **this lab uses** (other labs that use them download/build them again);
   the old `-IncludeBaseImages`/`-IncludeIso` switches are kept as aliases of that.

## Alternatives considered
- **Keep media per LabRoot** — every new lab re-downloads ~5–15 GB and rebuilds images (the requested problem).
- **Differencing disks on library bases** — would make VMs depend on library files; ADR 0008 requires plain dynamic disks.
- **Per-row OS for workstations** — workstations are generated from a count; one OS for all keeps the page simple.
- **Windows 10 from a third-party/consumer source** (Media Creation Tool, UUP) — not an evaluation; consumer editions; rejected.
- **File lock files instead of mutexes** — stale after a crash; a named mutex is released by Windows when the process dies.

## Consequences
- + A second lab on the same host starts at the Network phase in practice (ISOs and base images cached).
- + Testers choose server and workstation OS; validation proves the OS of every VM.
- + `lab.json` + VM tags make discovery/deletion (1.4.0) reliable.
- − Library and labs can live on different drives; Preflight checks free space on both.
- − `-IncludeLibrary` removes shared items: other labs that use the same OS download/build them again (documented, confirmation required).
- Roadmap note: the generic media downloader planned for 1.2.0 is moved to 1.5.0, where its first new user (IT Portal packages)
  arrives; 1.2.0 needed no new media type beyond ISOs.
- − Windows 10 builds depend on the tester's ISO (edition must contain an Enterprise image).
