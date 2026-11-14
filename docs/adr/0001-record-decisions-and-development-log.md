# ADR 0001: Record decisions and keep a development log

- **Status:** Accepted
- **Date:** 2026-11-14

## Context
The requester asked for application development best practice, with every step of the project recorded and documented.
The lab build is infrastructure code that testers will re-run on different hosts, so the reasons behind each choice must be traceable.

## Decision
- Keep a chronological development log in `docs/DEVLOG.md`; an entry is written after every step or major change.
- Keep `CHANGELOG.md` in Keep a Changelog format with Semantic Versioning.
- Record significant decisions as Architecture Decision Records in `docs/adr/` (this format).
- Capture requirements in `docs/REQUIREMENTS.md` before implementation.
- Record each real lab run (host, ISO builds, validation result) in the DEVLOG.
- The rules are in `CLAUDE.md` so every working session follows them.

## Alternatives considered
- Commit messages only — not readable by testers, and decisions get lost.
- Wiki outside the repo — drifts from the code.

## Consequences
- Small overhead per step; full traceability for the requester and testers.
