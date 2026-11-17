# Runbook — building the TEST lab

## 1. What you need

- A **dedicated Hyper-V host**: Windows Server 2019+ (Desktop Experience for the wizard) or Windows 10/11 Pro/Enterprise with the
  Hyper-V role and **Hyper-V PowerShell module**; .NET Framework 4.8 (inbox on Windows 10 1903+ / Server 2022+).
- A local administrator account on the host and a console session there (local or RDP).
- RAM and disk for the VMs you choose — the default lab (1 DC, 1 IIS server, 1 workstation, 4 GB each) needs **~12 GB free RAM**
  and **~150 GB free disk** (dynamic disks start at ~15 GB each and grow up to the chosen size).
- Internet access from the host for the ISO download (5–8 GB per operating system you use and the library does not have yet;
  plus ~300 MB SQL Server Express media if a server gets role SQL) — or pre-downloaded media (§4).
- For Windows 10 workstations: your own **Windows 10 Enterprise ISO** on the host (Microsoft offers no evaluation any more).
- Your decisions: domain FQDN (e.g. `lab.test`, not `.local`) and NetBIOS name (≤ 15 characters), plus the topology below.

## 2. Install and build with the wizard (recommended)

1. Copy **`LabBuilderSetup.exe`** to the host. If Windows SmartScreen warns (the exe is not code-signed), choose
   *More info → Run anyway*, or unblock it in the file properties.
2. Run it and accept the administrator prompt. The wizard opens maximised (resize or restore it freely). Pages:

| Page | You decide |
|------|-----------|
| Welcome | prerequisite check (must be all OK/WARN) |
| Folders | **first run only** (later: *Change folders...* on the start page): **App folder** (default `C:\LabBuilder`), **Labs folder** (default `<data drive>:\LabBuilder-Labs`, one subfolder per lab), **Library folder** (default `<data drive>:\LabBuilder-Library`, ISOs + one base image per OS, shared by all labs) - saved in `%ProgramData%\LabBuilder\settings.json` |
| Start | **create a new lab**, **edit an existing lab**, **delete a lab**, or **show the image library**; list of labs on the host (domain, VMs, disk type, last phase, size, folder) and a library summary |
| Delete lab | (delete only) what will be removed; type the lab name to confirm; live log |
| Image library | (library only) per OS: ISO, base image, Windows build, VMs whose differencing disks use it; unknown ISO files |
| Lab | lab name (new lab: folder `<Labs folder>\<LabName>`; edit: fixed); **build options**: VMs in parallel (default on), VM disks as independent dynamic copies (default) or **differencing disks** (fast, small; the VMs then depend on the library) |
| Domain | forest FQDN, NetBIOS name, generated or entered lab administrator password |
| Network | **isolated (Private)** or **host-reachable (Internal)** switch, switch name, /24 subnet |
| Domain controllers | **how many (1–5)**, per DC: name, **operating system (Windows Server 2025 / 2022 / 2019)**, IP, **vCPU, RAM, disk (dynamic)**, extra roles (ADCS, IIS, DHCP, File Server, features) |
| Member servers | **how many (0–10)**, per server: name, **operating system**, IP, size, **roles** (ADCS, IIS, DHCP, File Server, **SQL**); IIS HTTPS, DHCP range, share name |
| Accounts | **number of dedicated domain admins**, **number of test users**, password length, **test users local admins yes/no**, security groups |
| SQL Server | **shown only when a member server has role SQL** (SQL Server 2025 Express): **instance name** (`SQLEXPRESS` named / `MSSQLSERVER` default), **static TCP port**, **Windows or Mixed authentication** (sa password generated), **sysadmin groups** (Domain Admins always), **test database** (or none) and its **db_owner groups**, **collation** |
| Workstations | **how many (0–20)**, **operating system** (Windows 11 Enterprise LTSC, or Windows 10 Enterprise + **your ISO file**), name prefix, first IP, **generic vCPU / RAM / disk (dynamic)** |
| ISOs | lists the ISOs this lab needs; missing ones are downloaded from Microsoft, or imported from a pre-downloaded folder |
| Summary | everything, resource totals vs host, VM regional settings (from this host); validated with the build rules |

3. Click **Install & build**. The wizard installs LabBuilder into the App folder, saves the lab's own configuration
   `<Labs folder>\<LabName>\lab.config.psd1`, and runs the build with a live log, phase list and VM list. Typical duration after
   ISOs are present: 30–90 minutes depending on the number of VMs.
4. When it finishes, use **Open output folder / Lab summary / Validation report** (`<Labs folder>\<LabName>\output\`).

*Load configuration… / Save configuration…* store your answers (never the password) so a lab can be repeated elsewhere.
*Only install … do not build now* installs and saves the configuration; build later with `Invoke-LabBuild.ps1 -LabName <LabName>` (§3).

If the build stops, fix the cause (see the log), run the wizard again and choose **Edit an existing lab** → the lab → *Install &
build* - finished work is detected and skipped.

**Labs built with 1.0–1.3** (e.g. `D:\HyperVLab`) appear in the list automatically (found through their tagged VMs) and stay where
they are. Their configuration is restored from the old shared `C:\LabBuilder\config\lab.config.psd1` or its `.bak-<time>` copies when
one matches the lab; otherwise *Edit* rebuilds it from `lab.json` + Hyper-V and you confirm the **roles** of each server and the
**NetBIOS name** before building again.

## 3. Build with the scripts (alternative)

Elevated PowerShell on the host, in the install folder (or a copy of the repository):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\Invoke-LabBuild.ps1 -LabName QALAB                               # a lab known to this host (its own config)
.\scripts\Invoke-LabBuild.ps1 -ConfigPath D:\LabBuilder-Labs\QALAB\lab.config.psd1
.\scripts\Get-LabInventory.ps1 -AsObject | Select-Object -ExpandProperty Labs | Format-Table Name, Domain, LabRoot, Source
# or with the example defaults:
.\scripts\Invoke-LabBuild.ps1 -DomainFqdn lab.test -DomainNetbios LABTEST
```

| Parameter | Use |
|-----------|-----|
| `-LabName` | a lab of this host (Labs folder or registered); uses its own `lab.config.psd1` |
| `-ConfigPath` | config file (a lab's `lab.config.psd1` or a copy of `config\lab.config.example.psd1`) |
| `-DomainFqdn`, `-DomainNetbios`, `-LabRoot` | override config values |
| `-LabAdminCredential (Get-Credential)` | choose the lab admin password |
| `-IsoSource F:\LabIso` | import pre-downloaded ISOs |
| `-Phase MemberServers,Workstations,Validate` | run selected phases |

Check a config without building: `.\scripts\Test-LabConfigFile.ps1 -ConfigPath .\config\lab.config.psd1`.

## 4. Pre-downloading ISOs (optional)

On any Windows machine with internet access (no Hyper-V or admin rights needed):

```powershell
.\scripts\Get-LabIso.ps1 -Destination E:\LabIso                                          # the OSes the config uses
.\scripts\Get-LabIso.ps1 -Destination E:\LabIso -Image Server2025, Server2022, Server2019, Win11LTSC
```

Windows 10 (`Win10`) is never downloaded — choose your ISO in the wizard (or set `Iso.Images.Win10.SourcePath`).

With SQL servers in the lab, add `-IncludeSql`: the Microsoft web installer (signature-checked) downloads the SQL Server Express
offline package into `E:\LabIso\SQL` (nothing is installed on that machine).

Copy the folder (ISOs **and** `iso-manifest.json`, plus the `SQL` subfolder) to the host and choose it on the wizard's ISO page (or `-IsoSource`).
Every ISO is re-checked by SHA-256. Once in the image library (`<library>\ISO`), ISOs are reused by every later build and lab.

### Image library (ADR 0013)

```
<library>\ISO\            ISOs + iso-manifest.json (SHA-256, source), SQL\ (SQL Server Express package)
<library>\BaseImages\     <OS>.vhdx (read-only) + <OS>.vhdx.json (version, language, ISO SHA-256) - one per OS
<lab folder>\             VMs\, Logs\, Reports\, state.json, lab.json (this lab only)
```

- A base image is built once per OS and rebuilt automatically only when its ISO changes (new Microsoft build or another
  Windows 10 ISO). VMs are independent copies, so a rebuild never breaks an existing lab.
- Two builds running at the same time never download or build the same item twice (host-wide lock per item).
- Labs built with 1.0/1.1 keep working: their `<LabRoot>\ISO` and `<LabRoot>\BaseImages` are moved into the library on the
  next run of phase Iso / BaseImages.

### ISO links

`config\lab.config.example.psd1` → `Iso.Images.*.Url` (Microsoft Evaluation Center, English):

- Windows Server 2025 — <https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025> → ISO, 64-bit, English (United States)
- Windows Server 2022 — <https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022> → ISO, 64-bit, English (United States)
- Windows Server 2019 — <https://www.microsoft.com/en-us/evalcenter/download-windows-server-2019> → ISO, 64-bit, English (United States)
- Windows 11 Enterprise **LTSC** — <https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise> → "ISO – Enterprise LTSC download", English (United States)
- SQL Server 2025 **Express** — <https://www.microsoft.com/en-us/sql-server/sql-server-downloads> → Express "Download now" (`Roles.SQL.BootstrapperUrl`).
  If the automatic media download fails, run that web installer by hand → *Download Media* → *Express Core*, and put
  `SQLEXPR_x64_ENU.exe` into `<library>\ISO\SQL` (or `<pre-download folder>\SQL`); it must be signed by Microsoft.
- Windows 10 Enterprise — no evaluation download exists any more; use your own ISO (e.g. Windows 10 Enterprise LTSC 2021).

If a download fails with *HTTP 404* or *not in Iso.AllowedDownloadHosts*, Microsoft published a new build: copy the new
link into `config\lab.config.example.psd1` in the install folder and re-run. Set `ExpectedSha256` to pin an exact file.

## 5. Result

`<install folder>\output\<LabName>\`:

| File | Content |
|------|---------|
| `lab-summary.md` | VMs, roles, IPs, sizes, where the credentials are |
| `lab-accounts.csv` | domain admins and test users: type, user name, UPN, **password**, groups |
| `lab-sql.csv` | SQL Server `sa` password (only with role SQL and Mixed authentication) |
| `lab-admin.cred.xml` | lab administrator credential, encrypted for you on this host |
| `validation-*.md` | validation report |
| `build-*.log`, `build-*.transcript.log` | logs (no passwords) |

Lab administrator password: `(Import-Clixml .\output\TESTLAB\lab-admin.cred.xml).GetNetworkCredential().Password`

## 6. Using the lab

- **Private** switch: VMs reach each other only. **Internal**: give the host adapter `vEthernet (<switch>)` an address in the
  lab subnet (e.g. `10.10.10.250/24`) to reach the VMs from the host.
- Consoles: Hyper-V Manager → Connect (or `vmconnect.exe localhost TESTLAB-WS01`).
- Commands without network: `Invoke-Command -VMName TESTLAB-WS01 -Credential LABTEST\Administrator { hostname }`
- Copy files in: `Copy-VMFile -Name TESTLAB-WS01 -SourcePath C:\pkg\app.msi -DestinationPath C:\Temp\app.msi -CreateFullPath -FileSource Host`
- IIS: `http(s)://<server>.<domain>/lab-health.html`; file share `\\<server>\LabShare`.
- SQL Server: `<server>.<domain>\SQLEXPRESS` (named instance, SQL Browser) or `<server>.<domain>,1433`; Windows logins of the
  sysadmin / db_owner groups you chose; test database `LabDB` with table `dbo.LabCheck`. From PowerShell in the lab:
  `$cn = New-Object System.Data.SqlClient.SqlConnection('Data Source=tcp:SQL01.lab.test,1433;Integrated Security=SSPI'); $cn.Open()`.
- VM regional settings and time zone match the host; display language is the ISO language (English).
- Checkpoint before a test run: `Get-VM TESTLAB-* | Checkpoint-VM -SnapshotName clean`.

## 7. Troubleshooting

| Symptom | Action |
|---------|--------|
| A phase fails | Read the error in the wizard log / `output\<Lab>\build-*.log`; fix; run again (wizard: load the config; script: the printed `-Phase` command). |
| "Timed out waiting for <VM>" | Open the VM console — OOBE stuck or error screen. Check host RAM. |
| "request to list features ... failed" / `0x80071A2D` | Windows inside the new VM was still finishing first-boot servicing. The build restarts the VM and retries automatically (log: "Windows servicing is busy ... restarting"); if it still fails after 3 retries, re-run — finished work is skipped. |
| Additional DC promotion fails | Check DC01 is healthy (console); re-run `-Phase DomainControllers`. |
| HTTPS certificate request fails | The build grants the IIS server's computer account Enroll on the template and restarts the CA. If it still fails (e.g. `0x80094012` with a custom `CertificateTemplate`), check the template's Security tab and that it is published on the CA, then re-run `-Phase MemberServers,Workstations,Validate`. |
| Summary page: "Lab name ... is already used on this host by a lab of domain ..." / "Lab folder ... already belongs to lab ..." / "Switch ... already connects VMs of another lab" | Another lab exists on the host. For a **second lab** next to it: on *Install & lab* choose a new **lab name** and **lab folder**, on *Network* a new **switch name** and **subnet** (e.g. `10.10.20`) — the image library is shared, so nothing is downloaded again. To **replace** the old lab: `Remove-Lab.ps1 -ConfigPath <old config> -RemoveOutput` first. |
| Base image wrong edition | Adjust `ImageNamePattern`, delete `<library>\BaseImages\<OS>.vhdx` (+ `.json`), rebuild. |
| "No image matching 'Windows 10 Enterprise*'" | Your Windows 10 ISO has no Enterprise edition (e.g. a consumer Home/Pro ISO) — use an Enterprise or Enterprise LTSC ISO. |
| "another LabBuilder build is preparing library item ..." | A second build on the host is downloading/building the same ISO or base image; this one waits and then reuses it. |
| Validation "Windows licence not expired" fails / workstations switch off about an hour after every start | The Windows evaluation in that ISO has run out (event 1074 from `wlms.exe`: "The license period for this installation of Windows has expired"). Microsoft's Windows 11 Enterprise LTSC evaluation ISO 26100.1742 is expired. Start the VM again when needed (it runs about an hour each time), or rebuild the workstations from a newer evaluation or a licensed ISO. LabBuilder doesn't disable the licence shutdown. |
| Validation "OS is Windows Server 20xx" fails | The VM was built from another image (e.g. a 1.1 lab with the OS changed later) — remove that VM and build again. |
| Changed VM sizes after a build | Existing VMs are not resized; remove the lab (or the VM) and build again. |
| SQL media download fails (phase Iso) | Read the error; download the package by hand (§4 "ISO links") into `<library>\ISO\SQL` and re-run. A file not signed by Microsoft is refused. |
| SQL Setup fails | The error shows the exit code and the result lines of `Summary.txt` (path inside the VM in the message). Check RAM (≥ 4 GB recommended) and disk, then re-run `-Phase MemberServers,Workstations,Validate`. |
| "N of M member servers/workstations failed: ..." | Each failed VM is named with its error (details in `Logs\vm-<name>.log`); the others finished. Fix the cause and run again. If the host is overloaded, lower `Build.ThrottleLimit` or build one VM at a time. |
| "Base image ... was built from another ISO, but differencing disks of ... use it - kept" | Expected with differencing disks: the old base stays until no lab uses it; new labs keep using it too. Remove the differencing labs to get a rebuilt base. |
| Changed SQL instance, authentication or collation | Not applied to an installed SQL Server — remove that VM and build again (groups, database and port are re-applied on every run). |
| Evaluation expired | Server 180 days, Windows 11 LTSC 90 days — remove and rebuild (SQL Server Express does not expire; Windows 10 follows your ISO's licence). |

## 8. Teardown

Easiest: wizard → start page → **Delete a lab** (preview, type the lab name). From PowerShell:

```powershell
.\scripts\Remove-Lab.ps1 -LabName QALAB -WhatIf                           # preview
.\scripts\Remove-Lab.ps1 -LabName QALAB                                   # VMs, disks, switch if unused, lab folder + credentials (keeps the library)
.\scripts\Remove-Lab.ps1 -ConfigPath .\config\lab.config.psd1 -WhatIf     # older form: by config file
.\scripts\Remove-Lab.ps1 -ConfigPath .\config\lab.config.psd1             # VMs, disks, switch, lab.json (keeps the image library)
.\scripts\Remove-Lab.ps1 -ConfigPath .\config\lab.config.psd1 -IncludeLibrary -RemoveOutput
```

Only VMs named `<LabName>-<ComputerName>` from the config are removed. `-IncludeLibrary` also deletes the ISOs and base
images **this lab uses** from the shared library — other labs on the host that use the same OS will download/build them again.
A base image that differencing disks of another lab still use is never deleted (the log names the VMs).

## 8a. Parallel build and progress (ADR 0014)

- Phases Iso, BaseImages, the creation of all VMs, member servers (after the CA server) and workstations run in parallel; log lines
  of parallel work start with `[<VM or item>]`, and each VM also has its own log `<lab folder>\Logs\vm-<name>.log`.
- If one VM fails, the others still finish; the error lists every failed VM. Fix the cause and run again - finished VMs are skipped.
- Too much load on a small host: lower `Build.ThrottleLimit` (e.g. 2) or clear *Build VMs in parallel* (one VM at a time).
- Progress events (one JSON object per line) are in `<lab folder>\Logs\progress.jsonl`; the wizard shows them as the
  *Virtual machines* list on the Build page.
- **Differencing disks** (option): each VM disk is a child of `<library>\BaseImages\<OS>.vhdx`. Do not move or delete the library
  while such a lab exists; LabBuilder itself never rebuilds or deletes a base image in use (an ISO update then only warns).

## 8b. Faster domain controllers (ADR 0016)

- Phase BaseImages builds `<library>\BaseImages\<OS>-Roles.vhdx` once per server OS that a domain controller uses: a copy of the
  plain base with **AD DS and DNS** enabled offline (log: "Building role-ready base image ..."). It is never booted and not
  sysprepped (Microsoft does not support sysprep with these roles). Domain controllers start from it ("disk: ... on
  Server2025-Roles.vhdx"); the AD DS install step then finishes in seconds. **AD CS is not in the image** - a server with AD CS
  binaries cannot be promoted; the CA is installed online after the promotion.
- While the forest root is promoted, the member-server and workstation VMs are created in parallel (log lines `[other VMs]`).
- If the role image cannot be built, the log shows a warning and DCs use the plain base as before - nothing to do.
- Labs started with the first 1.4.1 test build (role image with AD CS): just resume - the AD CS binaries are removed from the DC
  before the promotion ("unconfigured AD CS binaries removed"), and the old role image is rebuilt once no VM uses it.
- Switch off: *Build options* → clear "Faster domain controllers" (`Build.RoleImages = $false`).
- **DC operating systems:** no DC may run a newer Windows Server than DC 1. Put the newest version on DC 1 (or use the same on all).
  A newer additional DC needs adprep against the forest root, which fails in the lab; the config check refuses such a lab. An
  existing lab with that mix cannot be repaired by editing - delete it and build it again.

## 8c. Windows Server activation with AVMA (ADR 0017)

- Needs an **activated Windows Server Datacenter** Hyper-V host (ITOMHV01 qualifies). AVMA runs through Hyper-V, not the network,
  so it works in the isolated lab.
- Phase BaseImages converts each Windows Server base image once, offline, from Evaluation to Standard (log: "Converting base image
  ... for AVMA"; about a minute per OS). The role-ready DC images are then rebuilt from the converted base.
- Each server VM logs "Windows activated with AVMA" after its network setup; validation shows "licensed (AVMA, renewed by the host)".
- Warnings, build continues with evaluation servers: host not Datacenter / not activated / older than the guest; base used by
  differencing disks ("stays an evaluation edition"); VM built from an old evaluation base ("evaluation edition ... not activated").
- Labs built before 1.4.3 are not converted (a DC cannot be converted from Evaluation): delete and rebuild them to get activated servers.
- Workstations (Windows 11) are not activated by AVMA.
- Switch off: *Build options* -> clear "Activate Windows Server VMs with AVMA" (`Build.Avma = $false`).
- Check on the host: Application log, event ID 12310 (one per AVMA request); in a VM: event ID 12309, `slmgr /dlv`.

## 9. Recording a lab run

After each real build, append a DEVLOG entry (CLAUDE.md rule): date, host (OS/build), topology, ISO file names + SHA-256
(from `iso-manifest.json`), duration, validation result, problems found.
