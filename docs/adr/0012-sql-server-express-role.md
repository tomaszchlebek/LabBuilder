# ADR 0012: SQL Server Express as an unattended member-server role

- **Status:** Accepted
- **Date:** 2026-11-14

## Context
Version 1.1.0 adds requirement FR-20: the tester can deploy member servers with **SQL Server Express installed
unattended**, and chooses the SQL options in the wizard. The lab VMs have no internet access (ADR 0005), media must
come from Microsoft (like the ISOs, ADR 0003), and the build runs only on the Hyper-V host with PowerShell Direct (ADR 0007).

On 2026-11-14 Microsoft's SQL Server downloads page (<https://www.microsoft.com/en-us/sql-server/sql-server-downloads>)
offers Express as a web installer: `go.microsoft.com/fwlink/p/?linkid=2216019` → `aka.ms/sql2025express` →
`download.microsoft.com/.../SQL2025-SSEI-Expr.exe` (4.6 MB, Authenticode-signed by Microsoft Corporation, version
17.0.1000.9). The SQL Server 2022 Express link is no longer on that page.

## Decision
1. **Product:** SQL Server **2025 Express**, database engine only (`FEATURES=SQLENGINE`). Role name `SQL`, allowed on
   **member servers only** — SQL Server is not supported on domain controllers (virtual service accounts do not work there).
2. **Media (phase Iso, on the host):** download the web installer through the same redirect allow-list as the ISOs;
   require a valid **Authenticode signature by Microsoft Corporation**; run it with
   `/ACTION=Download /MEDIAPATH=<dir> /MEDIATYPE=Core /QUIET` to get the offline package `SQLEXPR_x64_ENU.exe`; check that
   signature too; record size, SHA-256 and version in `<LabRoot>\ISO\SQL\sql-media.json`. A signature, not a pinned hash,
   is the integrity check because Microsoft updates this media in place. Pre-download elsewhere:
   `Get-LabIso.ps1 -IncludeSql`; a package downloaded by hand can be dropped into the `SQL` folder.
3. **Install (phase MemberServers):** copy the package into the VM over a PowerShell Direct session (`Copy-Item -ToSession`),
   extract it (`/q /x:`), run `setup.exe /ConfigurationFile=<ini> /IACCEPTSQLSERVERLICENSETERMS`. The `.ini` holds all
   options (instance, virtual service account `NT Service\MSSQL$<inst>`, TCP on, Named Pipes off, sysadmins, collation,
   Mixed mode + `SAPWD`) and is **deleted right after Setup** — the sa password never appears on a command line.
   Exit 3010 → VM restart. On failure the `Summary.txt` result lines are reported.
4. **Configuration, every run (idempotent):** static TCP port on `IPAll`, firewall rule, SQL Browser + UDP 1434 for a
   named instance, sysadmin logins for the chosen lab groups (Domain Admins always, found by RID 512 in any language),
   optional test database with `db_owner` groups and table `dbo.LabCheck` (one row `LAB-SQL-OK`) — via
   `System.Data.SqlClient` (inbox .NET), no `sqlcmd` needed.
5. **sa password (Mixed mode):** generated once by `Invoke-LabBuild.ps1`, kept in `output\<Lab>\lab-sql.csv` (same ACL as
   `lab-accounts.csv`, ADR 0006) — **not** in `lab-accounts.csv`, because every row there becomes an AD user.
6. **Tester options (wizard page "SQL Server", config `Roles.SQL`):** instance name (`SQLEXPRESS` or `MSSQLSERVER`),
   TCP port, Windows or Mixed authentication, sysadmin groups, test database name (or none) and its `db_owner` groups,
   collation. Download URL, media type and package pattern stay in the example config (editable if Microsoft changes them).
7. **Validation:** inside the server — service, TCP listener, firewall rule, Express edition, authentication mode, sysadmin
   members, database + `LabCheck` row + `db_owner` members; from the client — TCP reachability, Windows-authenticated
   query and (Mixed) `sa` login over TCP.

## Alternatives considered
- **SQL Server 2022 Express** — no longer linked from Microsoft's download page; 2025 is current and supported on
  Windows Server 2025.
- **Run the web installer inside the VM** — needs internet in the lab; rejected (ADR 0005).
- **Pin a SHA-256** of the package — breaks whenever Microsoft refreshes the media; the signature check plus a recorded
  hash is stable and still auditable.
- **sqlcmd / SqlServer PowerShell module** — not inbox on Windows Server 2025 (third-party download, NFR-1); SqlClient is inbox.
- **SQL on domain controllers** — unsupported by Microsoft for virtual accounts; blocked by validation.

## Consequences
- + SQL test servers are built unattended with tester-chosen options; repeatable and validated.
- + No secrets on command lines; media integrity checked by Microsoft signature.
- − The web installer's download mode (`/ACTION=Download`) could not be executed in the development environment; it is
  first exercised on the tester's Hyper-V host, where it worked (2026-11-15). If it ever fails, the error explains how to
  place the package by hand.
- − Changing instance, authentication mode or collation after installation needs the SQL server VM to be rebuilt.
- − SQL Server Express limits (Microsoft): one socket / 4 cores, ~1.4 GB buffer pool, 50 GB per database (2025).
