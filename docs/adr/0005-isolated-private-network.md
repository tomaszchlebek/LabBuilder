# ADR 0005: Isolated lab network on a Hyper-V Private switch with static IPs

- **Status:** Accepted
- **Date:** 2026-11-14

## Context
The brief asks for a whole **isolated** test environment. A new AD forest with its own DNS and an Enterprise CA must not leak onto
the host's LAN (rogue DNS/CA, name clashes) and the evaluation VMs need no internet.

## Decision
- Create a Hyper-V **Private** switch (default name `LAB-Isolated`) — VM-to-VM traffic only; the host and LAN have no adapter on it.
- Static IPv4 addressing from config (default `10.10.10.0/24`): DC `.10`, IIS `.20`, workstations `.101–.103`; no gateway.
  DNS on every member points to the DC.
- All management uses PowerShell Direct (ADR 0007), which works without a network.
- `Network.SwitchType = 'Internal'` is allowed for testers who want host access; the build then warns that isolation is reduced.
- Validation checks that every lab VM adapter is connected only to the lab switch and that the switch is Private.

## Alternatives considered
- Internal switch + NAT — gives internet (Windows Update) but is not isolated.
- External switch / VLAN — depends on the tester's physical network.

## Consequences
- No Windows Update or activation inside the lab (evaluation media, out of scope).
- Testers reach VMs with Hyper-V Manager / VMConnect (console), not RDP from the LAN.
- Software under test is copied in with `Copy-VMFile` or PowerShell Direct (`Copy-Item -ToSession`).
