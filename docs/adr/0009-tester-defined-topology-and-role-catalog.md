# ADR 0009: Tester-defined topology, accounts and server role catalog

- **Status:** Accepted
- **Date:** 2026-11-14

## Context
The requester wants the tester to decide at install time: how many domain controllers and their sizes, which server roles go
on which server, how many dedicated domain admins and test users, how many workstations and their generic size, whether test
users are local admins, and whether the network is isolated.

## Decision
Config schema v2 (`config/lab.config.example.psd1`), written by the wizard (ADR 0011):

- `DomainControllers = @( @{ Name; HostOctet; ProcessorCount; MemoryBytes; DiskSizeBytes; Roles; AdditionalFeatures } … )` — 1..5.
  The first creates the forest (`Install-ADDSForest`), others are promoted with `Install-ADDSDomainController` (+DNS, GC).
  Each DC's DNS client points to itself first, then the other DCs; members point to all DCs.
- `MemberServers = @( … same shape … )` — 0..10, domain-joined into `OU=Servers`.
- `Workstations = @{ Count; NamePrefix; FirstHostOctet; ProcessorCount; MemoryBytes; DiskSizeBytes }` — 0..20, names `<Prefix>01…`.
- `Accounts = @{ DomainAdminCount; TestUserCount; PasswordLength; UpnSuffix; TestUsersAreLocalAdmins }` — admins 0..10 in
  `OU=Admins` and **Domain Admins** (found by well-known RID 512, language-independent); users 0..100 in `OU=Users`.
- `Network.SwitchType` Private | Internal.
- **Role catalog** (implemented and validated by LabBuilder):

  | Role | Allowed on | What is deployed | Validation |
  |------|------------|------------------|------------|
  | `ADCS` | any server, **max 1** | Enterprise Root CA (RSA 4096, SHA-256) | `certutil -ping`, CA in AD |
  | `IIS` | any server | Web Server + features from `Roles.IIS.Features`, `/lab-health.html`, HTTPS cert from lab CA if a CA exists | HTTP/HTTPS GET from a workstation |
  | `DHCP` | any server, **max 1** | DHCP Server, authorised in AD, scope `<Prefix>.<RangeStart>-<RangeEnd>`, DNS option = DCs | authorised in AD, scope active |
  | `FileServer` | any server | File Server, share `\\<server>\<ShareName>` — Change for the first group, Full for Domain Admins | share reachable from a workstation |

  `AdditionalFeatures` takes any extra `Install-WindowsFeature` names (e.g. `RSAT-AD-Tools`, `Telnet-Client`); they are
  installed but not validated beyond install success. AD DS + DNS are implicit on DCs.
- Order: all DCs → CA server (if member) → other member servers → workstations; IIS HTTPS is requested after the CA exists.
- Every list is validated (counts, unique names/octets in 1..254, sizes, role rules) by `Test-LabConfig`, which the wizard also runs.

## Alternatives considered
- Free-form role list only (any Windows feature, no config) — testers would get half-configured roles (e.g. unauthorised DHCP, CA without setup).
- Fixed topology (v0.2) — rejected by requirement.

## Consequences
- More combinations to test; role post-configuration is limited to the catalog above.
- Phases renamed: `DomainController` → `DomainControllers`, `IisServer` → `MemberServers` (old names still accepted).
