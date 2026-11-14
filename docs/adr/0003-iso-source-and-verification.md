# ADR 0003: ISO source, download location and verification

- **Status:** Accepted
- **Date:** 2026-11-14

## Context
The brief requires the OS installation ISOs to be downloaded from Microsoft's official website and stored on the dedicated Hyper-V host.
The requester added that the ISOs can be downloaded **first to this workstation, or any workstation that will run test deployments later**.
Windows 11 consumer ISOs (microsoft.com/software-download) are behind a session-based anti-automation page; Evaluation Center ISOs are plain HTTPS links.

## Decision
- **Source:** Microsoft Evaluation Center
  - Windows Server 2025 (Standard / Datacenter evaluation, 180 days) — <https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025>
  - Windows 11 **Enterprise LTSC** (evaluation, 90 days; changed from Enterprise on 2026-11-14 by requester decision) — <https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise>
  - The `go.microsoft.com/fwlink` links from those pages are in `config/lab.config.example.psd1`. Microsoft changes the link IDs when a new
    build is published; the tester updates the URL from the page (RUNBOOK §ISO links).
  - Checked 2026-11-14: Server link resolves to `26100.32230 …SERVER_EVAL_x64FRE_en-us.iso` (8,152,356,864 bytes);
    Windows 11 Enterprise link resolved to `26300.9457 …CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso` (8,225,329,152 bytes); the
    **LTSC** link (linkid 2289029) resolves to `26100.1742.240906-0331…CLIENT_LTSC_EVAL_x64FRE_en-us.iso` (5,112,850,432 bytes),
    all on `software-static.download.prss.microsoft.com`.
- **Location** (amended 2026-11-14 with ADR 0007 — the build runs on the Hyper-V host):
  - Phase `Iso` downloads straight into **`<LabRoot>\ISO` on the host** that runs the build; verified files are reused by every later build on that host.
  - `scripts/Get-LabIso.ps1` pre-downloads on **any** machine (no Hyper-V, no elevation; default `%USERPROFILE%\LabIsoCache`).
    The folder (ISOs + `iso-manifest.json`) is copied to the host and passed as `Invoke-LabBuild.ps1 -IsoSource <folder>`;
    each file is copied into `<LabRoot>\ISO` and its SHA-256 re-checked against the manifest.
- **Verification:**
  1. Redirects are followed by hand (max 10); every hop must be HTTPS on `*.microsoft.com` or `aka.ms`, and the final host must be in
     `AllowedDownloadHosts`.
  2. File size must equal the server's `Content-Length`.
  3. SHA-256 is computed and written to `iso-manifest.json`; if `ExpectedSha256` is set in config it must match.
  4. In phase `BaseImages` the ISO must contain `sources\install.wim|esd` with an image matching `ImageNamePattern`.
- **Download tool:** `curl.exe` (inbox since Windows 10 1803 / Server 2019) — resumable (`-C -`) into `<file>.partial`, fast;
  `Invoke-WebRequest` fallback.

## Alternatives considered
- Consumer Windows 11 ISO via the Fido-style API — fragile, against the intent of the page.
- BITS — needs an interactive logon session for user jobs; `curl.exe` is simpler and resumable.
- Copying from a workstation cache over WinRM (first version of this ADR) — dropped with ADR 0002.

## Consequences
- Evaluation media expire (Server 180 days, Windows 11 90 days) — fine for a disposable lab; rebuild when expired.
- About 16 GB on the host; the host needs internet access unless `-IsoSource` is used.
- When Microsoft changes the link IDs, the old fwlink stops resolving; the build fails with a clear error and the tester updates the URL.
