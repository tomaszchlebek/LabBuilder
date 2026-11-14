# Build TEST environment — working rules

## Documentation discipline (mandatory)

Every step of work on this project is documented. After **every step or major change**:

1. **Append an entry to [`docs/DEVLOG.md`](docs/DEVLOG.md)** (newest at the bottom), using the entry template in that file:
   date, step title, what was done, why, files touched, how it was verified, next steps.
2. **Update [`CHANGELOG.md`](CHANGELOG.md)** under `[Unreleased]` when the change affects behaviour, features, configuration or dependencies (Keep a Changelog format).
3. **Write an ADR in [`docs/adr/`](docs/adr/)** for any significant technical decision (execution model, image build method, networking, ISO sourcing, secrets handling). Copy `docs/adr/0000-template.md`, number sequentially, and link it from the DEVLOG entry.
4. **Keep [`README.md`](README.md), [`docs/RUNBOOK.md`](docs/RUNBOOK.md) and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) current** — they must match the scripts.
5. **Record lab runs** (date, host, build numbers of ISOs, validation result) in the DEVLOG.

A step is not finished until its DEVLOG entry is written.

## Development practices

- Version control with git; small, focused commits (Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`).
- Commit only when the user asks.
- Never commit secrets or generated output: `output/`, `*.cred.xml`, `lab-accounts.csv` and ISO/VHDX files are git-ignored.
- Requirements are recorded in `docs/REQUIREMENTS.md` before implementation starts.
- Tests (`tests/*.Tests.ps1`) accompany new logic that can run without Hyper-V; record results in the DEVLOG.

## Code conventions

- Target **Windows PowerShell 5.1** (inbox on every Hyper-V host); code must also run on PowerShell 7.
- **ASCII only in `.ps1`/`.psm1`/`.psd1` files** — Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.
- Every phase must be **idempotent**: check state first, then act, so a failed build can be re-run.
- Tests use Pester 3.4 syntax (`Should Be`) because that version ships with Windows.
- No secrets in logs, console output or command lines (the wizard passes the admin password via stdin).
- Wizard (`installer/src`): **C# 5** only (inbox `csc.exe`: no `$""`, `?.`, `nameof`, auto-property initializers),
  .NET Framework 4.8, ASCII source. Rebuild with `installer\build.ps1` after any change to `src/`, `scripts/`, `config/` or `docs/`
  (they are embedded in the exe). The scripts are the single source of truth; the wizard only collects inputs.
- Config schema changes: update `config/lab.config.example.psd1`, `Test-LabConfig`, the wizard (`LabModel.cs`) and tests together.
