# Requirements — Build TEST environment

- **Version:** 0.5 (2026-11-15)
- **Owner:** project requester
- **Status:** v0.5 — v0.4 plus OS choice per VM and a shared image library (release 1.2.0)

History: v0.1 brief · v0.2 ISOs downloaded first on the deployment machine; runs directly on any Hyper-V host ·
v0.3 answers (Server 2025 OK, Windows 11 **LTSC**, host language/time zone, tester decides local admin + network isolation),
tester-defined topology/roles/sizes/accounts, `.exe` wizard installer · v0.4 (1.1.0) SQL Server Express member servers with
tester-chosen SQL options · v0.5 (1.2.0) OS per VM (Server 2019/2022/2025, Windows 11 LTSC, Windows 10 from the tester's ISO), shared image library, lab manifest.

## 1. Goal

Build an **isolated lab test environment** on a **Hyper-V** host, automatically and repeatably, so testers can run tests
against a realistic Active Directory domain with a certificate authority, servers with chosen roles and domain-joined
Windows 11 clients. The tester runs a **Windows `.exe` installer wizard** on the host and answers all questions there.

## 2. Inputs supplied by the tester (wizard pages, or config file)

| # | Input | Default | Notes |
|---|-------|---------|-------|
| IN-1 | Hyper-V host | the machine running the wizard | Runs **directly on the host**, elevated |
| IN-2 | Lab name, lab folder, image library folder | `TESTLAB`, `D:\HyperVLab`, `<lab drive>:\LabBuilder-Library` | VM name prefix; lab folder for VM disks, logs, reports; **library folder shared by all labs** for ISOs and base images |
| IN-3 | Forest root domain FQDN, NetBIOS name | — | e.g. `lab.test`, `LABTEST` |
| IN-4 | Lab administrator password | generated | or entered twice by the tester |
| IN-5 | Network isolation | Private (isolated) | **tester decides**: Private or Internal (host can reach VMs); lab subnet |
| IN-6 | Number of domain controllers + size of each (vCPU, RAM, disk) + roles of each | 1 × (2 vCPU, 4 GB, 80 GB), AD CS | first DC creates the forest, others join it |
| IN-7 | Member servers: number, name, size and **roles of each** | 1 × IIS01 (IIS) | 0..10 |
| IN-8 | Number of **dedicated domain admin accounts** | 1 | random names `adm.<first>.<last>`, members of Domain Admins |
| IN-9 | Number of **domain test users** | 3 | random names, all in the first security group |
| IN-10 | Security groups | 4 (`SG-Lab-*`) | editable list |
| IN-11 | **Test users local administrators on workstations** | No | **tester decides** |
| IN-12 | Number of **test workstations** + generic size (vCPU, RAM, disk) | 1 × (2 vCPU, 4 GB, 80 GB) | 0..20 |
| IN-13 | Pre-downloaded ISO folder | none | optional; may contain a `SQL` subfolder with the SQL Express package |
| IN-15 | **Operating system per VM** | servers: Windows Server 2025; workstations: Windows 11 Enterprise LTSC | **tester decides**: each DC / member server Server 2019, 2022 or 2025 (Standard, Desktop Experience, evaluation); workstations (all the same) Windows 11 Enterprise LTSC or **Windows 10 Enterprise from an ISO the tester supplies** (no Microsoft evaluation download exists any more) |
| IN-14 | **SQL Server options** (servers with role SQL) | instance `SQLEXPRESS`, TCP 1433, Windows auth, sysadmin: Domain Admins, database `LabDB` (db_owner `SG-Lab-Testers`), default collation | **tester decides** on the wizard page "SQL Server": instance name, TCP port, Windows/Mixed auth, sysadmin groups, test database + db_owner groups, collation |

All disks are **dynamically expanding VHDX** of the size the tester chooses.

## 3. Functional requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | Download the OS installation ISOs the lab uses (Windows Server **2019, 2022, 2025**, **Windows 11 Enterprise LTSC**) **from Microsoft's official website** (Evaluation Center); Windows 10 Enterprise only from an ISO the tester supplies. | Must |
| FR-2 | Downloads happen first on the machine that runs the deployment (the Hyper-V host) into the **image library** (`<Library>\ISO`), reused by every later build and lab; ISOs can be pre-downloaded on any machine and imported. | Must |
| FR-3 | Verify every ISO: allow-listed Microsoft hosts over HTTPS, size, SHA-256 (optionally pinned), image present inside. | Must |
| FR-4 | Store the ISOs on the dedicated Hyper-V host; all VMs are built from them. | Must |
| FR-5 | Isolated virtual network by default; the tester may choose an Internal switch instead. | Must |
| FR-6 | Deploy **1..N domain controllers**: the first creates a **new AD forest** (tester's FQDN + NetBIOS, DNS); additional ones join it as DCs with DNS. | Must |
| FR-7 | Deploy the **Certificate Authority** role (AD CS Enterprise Root CA) on the server the tester chooses (default: first DC); at most one CA. | Must |
| FR-8 | Create the tester-chosen number of **random domain admin accounts** and **random test users**, and the **security groups** with test users as members. | Must |
| FR-9 | Deploy the tester-chosen **member servers**, domain-joined, each with the **roles the tester selects** (catalog: IIS, AD CS, DHCP, File Server, plus any extra Windows feature names). | Must |
| FR-10 | IIS serves HTTPS with a certificate from the lab CA when a CA is deployed. | Should |
| FR-11 | After the servers, deploy the tester-chosen number of **domain-joined workstations** (Windows 11 LTSC or Windows 10) with the chosen generic size. | Must |
| FR-12 | Validation checks after the build with a report (DCs/replication, CA, accounts, groups, each role, workstations, web/file access, isolation). | Must |
| FR-13 | Give the tester the lab credentials (admin + generated accounts) in a local, protected, git-ignored folder. | Must |
| FR-14 | Builds can be re-run/resumed (idempotent phases) and run phase by phase. | Must |
| FR-15 | Tear down the lab, keeping the shared image library (ISOs, base images) unless explicitly asked. | Should |
| FR-16 | Runs directly on any Hyper-V host (Windows Server 2019+ or Windows 10/11 Pro/Enterprise with Hyper-V). | Must |
| FR-17 | VMs use the **Hyper-V host's regional settings and time zone** (UI language = language of the ISO). | Must |
| FR-18 | A **Windows `.exe` installer wizard** collects all inputs above, checks prerequisites, installs the application files, saves the configuration, runs the build with live progress and shows the result. | Must |
| FR-19 | The configuration chosen in the wizard can be saved and loaded again (repeatable labs). | Should |
| FR-20 | A member server can get role **SQL**: **SQL Server Express installed unattended** from Microsoft media (downloaded on the host, signature-checked), configured with the tester's SQL options (IN-14), and validated (service, TCP, auth mode, sysadmins, test database, remote connection). | Must |
| FR-21 | **Shared image library**: ISOs and base images are stored once per host (library folder) and reused by all labs; a base image is built once per OS and rebuilt only when its ISO changes; concurrent builds never build the same image twice; media of labs built with 1.0–1.1 (`<LabRoot>\ISO`, `<LabRoot>\BaseImages`) is moved into the library. | Must |
| FR-22 | **OS choice per VM** (IN-15); validation checks the installed OS of every VM. | Must |
| FR-23 | **Lab manifest**: each lab records its name, version, folders, switch and VMs in `<LabRoot>\lab.json`, and every VM carries a `LabBuilder:<LabName>` tag in its notes (basis for lab discovery, release 1.4.0). | Must |

## 4. Non-functional requirements

| ID | Requirement |
|----|-------------|
| NFR-1 | Inbox tooling only to run **and to build**: Windows PowerShell 5.1, Hyper-V/Storage/DISM modules, `curl.exe`, .NET Framework 4.8 (`csc.exe`) — no third-party downloads. |
| NFR-2 | Unattended end to end after the tester finishes the wizard. |
| NFR-3 | Secrets never in logs or on command lines; credential files protected and git-ignored; `unattend.xml` removed from VMs after first boot. |
| NFR-4 | Every action logged (build log, transcript, host log). |
| NFR-5 | All settings in one config file; the wizard writes it; command-line values override it. |
| NFR-6 | Default build ≤ 2 hours after ISOs are cached. |
| NFR-7 | Input validation identical in wizard and scripts (the wizard runs the script validation before starting). |

## 5. Out of scope

- Internet access, routing or NAT for the lab VMs.
- Licensing/activation — evaluation media (Server 180 days, Windows 11 LTSC 90 days); SQL Server Express is free; Windows 10 media and licence are the tester's.
- SQL Server editions other than Express, SQL Server Management Studio, SQL Agent, high availability.
- Child domains / multiple forests, two-tier PKI.
- Installing the software under test.
- Code-signing the `.exe` (no certificate available; SmartScreen may warn).

## 6. Decisions

| Topic | Decision | ADR |
|-------|----------|-----|
| Execution model | Run on the Hyper-V host, PowerShell Direct into VMs | [0007](adr/0007-run-directly-on-the-hyper-v-host.md) (supersedes [0002](adr/0002-execution-model-winrm-and-powershell-direct.md)) |
| ISO source | Evaluation Center; Windows 11 **Enterprise LTSC** | [0003](adr/0003-iso-source-and-verification.md) |
| VM disks | Base VHDX from `install.wim`; per-VM **dynamic** copy resized to the tester's size | [0008](adr/0008-per-vm-dynamic-disks.md) (supersedes disk part of [0004](adr/0004-vm-build-from-base-vhdx.md)) |
| Network | Private switch default, Internal by tester choice | [0005](adr/0005-isolated-private-network.md) |
| Secrets | Generated passwords, DPAPI file, protected accounts CSV | [0006](adr/0006-lab-secrets-handling.md) |
| Topology | Tester-defined DCs, member servers with role catalog, workstations, accounts | [0009](adr/0009-tester-defined-topology-and-role-catalog.md) |
| Locale | Host regional settings + time zone; UI language from image | [0010](adr/0010-locale-from-hyper-v-host.md) |
| Installer | .NET Framework 4.8 WinForms wizard `.exe` built with inbox `csc.exe`, payload embedded | [0011](adr/0011-wizard-installer-exe.md) |
| SQL Server | SQL Server 2025 Express, member servers only; web installer download mode on the host, Microsoft signature check; unattended Setup from a deleted config file | [0012](adr/0012-sql-server-express-role.md) |
| Image library / OS | Shared library folder for ISOs + base images (one per OS); OS catalog Server 2019/2022/2025, Windows 11 LTSC, Windows 10 (tester ISO); lab manifest + VM tags | [0013](adr/0013-shared-image-library-and-os-choice.md) |

## 7. Answered questions (v0.2 → v0.3)

1. Windows Server 2025 Standard (Desktop Experience) — **yes**.
2. Windows 11 edition — **Enterprise LTSC**.
3. Language / time zone — **use the Hyper-V host's settings**.
4. Test users local administrators — **tester decides during installation**.
5. Isolated (Private) vs host-reachable (Internal) network — **tester decides during installation**.

## 8. Open questions

None at present.
