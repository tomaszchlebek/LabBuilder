# Runbook — building the TEST lab

## 1. What you need

- A **dedicated Hyper-V host**: Windows Server 2019+ (Desktop Experience for the wizard) or Windows 10/11 Pro/Enterprise with the
  Hyper-V role and **Hyper-V PowerShell module**; .NET Framework 4.8 (inbox on Windows 10 1903+ / Server 2022+).
- A local administrator account on the host and a console session there (local or RDP).
- RAM and disk for the VMs you choose — the default lab (1 DC, 1 IIS server, 3 workstations, 4 GB each) needs **~20 GB free RAM**
  and **~150 GB free disk** (dynamic disks start at ~15 GB each and grow up to the chosen size).
- Internet access from the host for the ISO download (~13 GB) — or pre-downloaded ISOs (§4).
- Your decisions: domain FQDN (e.g. `lab.test`, not `.local`) and NetBIOS name (≤ 15 characters), plus the topology below.

## 2. Install and build with the wizard (recommended)

1. Copy **`LabBuilderSetup.exe`** to the host. If Windows SmartScreen warns (the exe is not code-signed), choose
   *More info → Run anyway*, or unblock it in the file properties.
2. Run it and accept the administrator prompt. Pages:

| Page | You decide |
|------|-----------|
| Welcome | prerequisite check (must be all OK/WARN) |
| Install & lab | install folder (default `C:\LabBuilder`), lab name, lab folder for ISOs/VMs |
| Domain | forest FQDN, NetBIOS name, generated or entered lab administrator password |
| Network | **isolated (Private)** or **host-reachable (Internal)** switch, switch name, /24 subnet |
| Domain controllers | **how many (1–5)**, per DC: name, IP, **vCPU, RAM, disk (dynamic)**, extra roles (ADCS, IIS, DHCP, File Server, features) |
| Member servers | **how many (0–10)**, per server: name, IP, size, **roles**; IIS HTTPS, DHCP range, share name |
| Accounts | **number of dedicated domain admins**, **number of test users**, password length, **test users local admins yes/no**, security groups |
| Workstations | **how many (0–20)**, name prefix, first IP, **generic vCPU / RAM / disk (dynamic)** |
| ISOs | download from Microsoft, or a pre-downloaded folder |
| Summary | everything, resource totals vs host, VM regional settings (from this host); validated with the build rules |

3. Click **Install & build**. The wizard installs LabBuilder into the install folder, saves
   `config\lab.config.psd1`, and runs the build with a live log and phase list. Typical duration after ISOs are present:
   30–90 minutes depending on the number of VMs.
4. When it finishes, use **Open output folder / Lab summary / Validation report**.

*Load configuration… / Save configuration…* store your answers (never the password) so a lab can be rebuilt the same way.
*Only install … do not build now* installs and saves the configuration; build later with the script (§3).

If the build stops, fix the cause (see the log) and run the wizard again with the same settings (Load configuration from
`<install>\config\lab.config.psd1`) — finished work is detected and skipped.

## 3. Build with the scripts (alternative)

Elevated PowerShell on the host, in the install folder (or a copy of the repository):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\Invoke-LabBuild.ps1 -ConfigPath .\config\lab.config.psd1
# or with the example defaults:
.\scripts\Invoke-LabBuild.ps1 -DomainFqdn lab.test -DomainNetbios LABTEST
```

| Parameter | Use |
|-----------|-----|
| `-ConfigPath` | config file (wizard output or a copy of `config\lab.config.example.psd1`) |
| `-DomainFqdn`, `-DomainNetbios`, `-LabRoot` | override config values |
| `-LabAdminCredential (Get-Credential)` | choose the lab admin password |
| `-IsoSource F:\LabIso` | import pre-downloaded ISOs |
| `-Phase MemberServers,Workstations,Validate` | run selected phases |

Check a config without building: `.\scripts\Test-LabConfigFile.ps1 -ConfigPath .\config\lab.config.psd1`.

## 4. Pre-downloading ISOs (optional)

On any Windows machine with internet access (no Hyper-V or admin rights needed):

```powershell
.\scripts\Get-LabIso.ps1 -Destination E:\LabIso
```

Copy the folder (ISOs **and** `iso-manifest.json`) to the host and choose it on the wizard's ISO page (or `-IsoSource`).
Every ISO is re-checked by SHA-256. Once in `<LabRoot>\ISO`, ISOs are reused by later builds.

### ISO links

`config\lab.config.example.psd1` → `Iso.Images.*.Url` (Microsoft Evaluation Center, English):

- Windows Server 2025 — <https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025> → ISO, 64-bit, English (United States)
- Windows 11 Enterprise **LTSC** — <https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise> → "ISO – Enterprise LTSC download", English (United States)

If a download fails with *HTTP 404* or *not in Iso.AllowedDownloadHosts*, Microsoft published a new build: copy the new
link into `config\lab.config.example.psd1` in the install folder and re-run. Set `ExpectedSha256` to pin an exact file.

## 5. Result

`<install folder>\output\<LabName>\`:

| File | Content |
|------|---------|
| `lab-summary.md` | VMs, roles, IPs, sizes, where the credentials are |
| `lab-accounts.csv` | domain admins and test users: type, user name, UPN, **password**, groups |
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
- VM regional settings and time zone match the host; display language is the ISO language (English).
- Checkpoint before a test run: `Get-VM TESTLAB-* | Checkpoint-VM -SnapshotName clean`.

## 7. Troubleshooting

| Symptom | Action |
|---------|--------|
| A phase fails | Read the error in the wizard log / `output\<Lab>\build-*.log`; fix; run again (wizard: load the config; script: the printed `-Phase` command). |
| "Timed out waiting for <VM>" | Open the VM console — OOBE stuck or error screen. Check host RAM. |
| Additional DC promotion fails | Check DC01 is healthy (console); re-run `-Phase DomainControllers`. |
| HTTPS certificate request fails | The build grants the IIS server's computer account Enroll on the template and restarts the CA. If it still fails (e.g. `0x80094012` with a custom `CertificateTemplate`), check the template's Security tab and that it is published on the CA, then re-run `-Phase MemberServers,Workstations,Validate`. |
| Base image wrong edition | Adjust `ImageNamePattern`, `Remove-Lab.ps1 -IncludeBaseImages`, rebuild. |
| Changed VM sizes after a build | Existing VMs are not resized; remove the lab (or the VM) and build again. |
| Evaluation expired | Server 180 days, Windows 11 LTSC 90 days — remove and rebuild. |

## 8. Teardown

```powershell
.\scripts\Remove-Lab.ps1 -ConfigPath .\config\lab.config.psd1 -WhatIf     # preview
.\scripts\Remove-Lab.ps1 -ConfigPath .\config\lab.config.psd1             # VMs, disks, switch (keeps ISOs + base images)
.\scripts\Remove-Lab.ps1 -ConfigPath .\config\lab.config.psd1 -IncludeBaseImages -IncludeIso -RemoveOutput
```

Only VMs named `<LabName>-<ComputerName>` from the config are removed.

## 9. Recording a lab run

After each real build, append a DEVLOG entry (CLAUDE.md rule): date, host (OS/build), topology, ISO file names + SHA-256
(from `iso-manifest.json`), duration, validation result, problems found.
