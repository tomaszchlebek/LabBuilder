# ADR 0006: Lab secrets handling

- **Status:** Accepted
- **Date:** 2026-11-14

## Context
The build needs a lab administrator password (local Administrator, domain Administrator, DSRM) and passwords for 3 random test users,
and testers need to read them to log on. The lab is isolated and disposable, but credentials must still not leak into git or logs.

## Decision
- The tester may pass `-LabAdminCredential`; otherwise a **random 20-character password** is generated (crypto RNG, upper/lower/digit/symbol,
  no look-alike characters). The same password is used for DSRM (lab only).
- Saved per lab as `output\<LabName>\lab-admin.cred.xml` with `Export-Clixml` (**DPAPI**, readable only by the same Windows user on the same
  Hyper-V host) so re-runs and teardown use the same password.
- The account plan (3 random users, passwords, group memberships) is generated once and saved as `output\<LabName>\lab-accounts.csv`,
  which testers need to log on. It is **plaintext**, in a git-ignored folder, and the build sets its ACL to the current user and SYSTEM only.
- Secrets stay on the host and go into VMs only over PowerShell Direct (VMBus); they are **never logged**.
- In `unattend.xml` passwords are stored in the unattend encoding (not plaintext) and the file is **deleted** from each VM after setup.

## Alternatives considered
- SecretManagement vault — third-party module (NFR-1).
- Same fixed password for every lab — easy to guess, reused across labs.

## Consequences
- A different host/user cannot resume a lab with the saved admin credential; pass `-LabAdminCredential` there.
- Testers must treat `lab-accounts.csv` as sensitive and delete it with the lab.
