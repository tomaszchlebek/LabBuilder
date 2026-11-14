# ADR 0011: Windows wizard installer `.exe` (.NET Framework 4.8 WinForms, built with inbox csc.exe)

- **Status:** Accepted
- **Date:** 2026-11-14

## Context
The requester wants a Windows `.exe` installer that asks the tester every input (domain, network isolation, DCs and their
sizes/roles, member servers and roles, admin/user/workstation counts and sizes, local admin choice) and deploys the lab.
It must run on any Hyper-V host without installing prerequisites (NFR-1), and the project should build without third-party tools.

## Decision
- **`LabBuilderSetup.exe`** — a WinForms wizard targeting **.NET Framework 4.8** (inbox on Windows 10 1903+/Server 2022+;
  installable on Server 2019), compiled by **`installer\build.ps1`** with the inbox
  `%windir%\Microsoft.NET\Framework64\v4.0.30319\csc.exe` (C# 5 language level). No SDK, NuGet or installer toolkit needed.
- The application payload (`src\`, `scripts\`, `config\`, `docs\`, `README.md`, `LICENSE` if present) is zipped and **embedded as a
  resource**; the exe has a manifest with `requireAdministrator`.
- Wizard pages: Welcome + prerequisite check → Install folder & lab → Domain & admin password → Network → Domain controllers →
  Member servers & roles → Accounts & groups → Workstations → ISOs → Summary → Build (live log, phase checklist) → Finish.
  *Load/Save configuration* buttons read/write the `.psd1`.
- On *Install & build* the exe: extracts the payload to the install folder (default `C:\LabBuilder`; keeps `output\` and an
  existing `config\lab.config.psd1` backup), writes `config\lab.config.psd1`, runs the **script validation**
  (`Test-LabConfig` via `powershell.exe`) and shows errors, then starts
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-LabBuild.ps1 -ConfigPath … -AdminPasswordFromStdin`.
  The admin password (if entered) is written to the child's **stdin**, never on a command line or in a file.
  stdout/stderr are streamed into the log view; `=== Phase X …` lines drive the phase checklist.
- `-ConfigOnly` mode: write/save the configuration without building (e.g. to run the script later or on another host).
- The scripts stay the single source of truth; the wizard only collects inputs. Running the scripts by hand still works.

## Alternatives considered
- **.NET 10 WinForms single-file** — modern C#, but needs the SDK + NuGet to build and ~60–150 MB self-contained output.
- **Inno Setup / WiX MSI** — third-party toolchain; an MSI UI for this many dynamic inputs is awkward.
- **PowerShell WPF GUI + ps2exe** — ps2exe is a third-party module; such exes are often flagged by antivirus.

## Consequences
- C# 5 only (no string interpolation, `?.`, `nameof`) in `installer\src`.
- The exe is unsigned: SmartScreen/Defender may warn; unblock or sign it with an internal certificate.
- The wizard needs elevation because the build needs it.
