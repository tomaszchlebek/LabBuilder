# ADR 0010: VM regional settings and time zone from the Hyper-V host

- **Status:** Accepted
- **Date:** 2026-11-14

## Context
The requester answered: use the Hyper-V host's language and time zone for the lab. The Evaluation Center ISOs are
single-language (en-US); Windows Setup fails or falls back if `UILanguage` names a language that is not in the image.

## Decision
- `Locale` values left empty in config (default) are taken **from the host at build time** by `Resolve-LabLocale`:
  - `TimeZone` = `(Get-TimeZone).Id` (Windows time-zone ID, e.g. `GMT Standard Time`)
  - `SystemLocale` = `(Get-WinSystemLocale).Name`
  - `UserLocale` = `(Get-Culture).Name` (formats)
  - `InputLocale` = first keyboard of the host's language list (`InputMethodTips[0]`, e.g. `0415:00000415`); if empty, the
    first language tag of the list; else `UserLocale`.
- `UILanguage` = the **language of the Windows image** (read from `install.wim` when the base image is built and stored in
  `<base>.vhdx.json`), unless set explicitly in config. Using a localized ISO therefore gives a localized UI.
- Any value can be pinned in config; the wizard shows the detected host values.
- Values go into `unattend.xml` (oobeSystem `International-Core`, specialize `TimeZone`).

## Alternatives considered
- Install language packs to match the host UI language — needs packs from the Volume Licensing/LP ISO (not in Evaluation media).
- Fixed en-US/UTC (v0.1) — rejected by requester.

## Consequences
- Keyboard, formats and time zone match the host; display language is the ISO language (English with the default links).
