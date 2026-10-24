# reporting-troubleshooting

Scripts run on customer PCs to capture crash / hang / performance evidence for dump analysis. The dumps
and traces produced here are analysed separately by the dumps-analysis-toolkit.

## Quick start (no clone, no manual copying)

Run one of these in an elevated or normal PowerShell / terminal - it downloads, installs and opens the menu:

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/mcpolo99/reporting-troubleshooting/main/src/Get.ps1')))
```

or double-click / run **`src\run.bat`**.

The bootstrap (`Get.ps1`) elevates, checks the installed version against GitHub, and only downloads when
there is a newer version. It installs to `%ProgramData%\ReportingTroubleshooting` and opens the launcher
(a small WPF window by default; `-CLI` for a text menu, also used as the fallback where WPF is unavailable).

| Switch | Effect |
|---|---|
| `-Dev`   | install from the `main` branch head instead of the latest release |
| `-Force` | reinstall even if already up to date |

Example: `run.bat -Force`

## Layout (mirrors Win11Debloat, slimmed)

All source lives under `src/`; repo-level maintainer scripts under `scripts/`; the repo root holds
`README.md`, `LICENSE`, `.gitignore`, `VERSION` and `CHANGELOG.md`. (`build/` is never committed.)

| Path | What |
|---|---|
| `VERSION` | single source of truth for the toolset version (read by `ReportingToolkit.ps1` and the release script) |
| `CHANGELOG.md` | per-release notes |
| `scripts/New-Release.ps1` | maintainer: bump version, tag `vX.Y.Z`, publish the GitHub release |
| `src/Get.ps1`, `src/run.bat` | bootstrap: download/version-check/install, then launch |
| `src/ReportingToolkit.ps1` | main entry: sets paths, dot-sources components, opens GUI or `-CLI` menu |
| `src/Schemas/` | `MainWindow.xaml`, `SharedStyles.xaml` (XAML lives here, not inside the scripts) |
| `src/GUI/` | `Show-MainWindow.ps1`, `Set-WindowThemeResources.ps1` (light/dark), `Get-SystemUsesDarkMode.ps1` |
| `src/CLI/` | `Show-CliMenu.ps1` |
| `src/Helpers/` | `Start-Tool.ps1` |
| `src/Common/` | `Logging.ps1`, `Common.ps1` - shared components dot-sourced by the tools |
| `src/Tools/` | the capture tools (see below) |

## Tools (`src/Tools/`)

| Tool | What it does | Installed? |
|---|---|---|
| `PerfView/PerfViewCapture.ps1` | Installs PerfView; starts/stops ETW/ETL performance traces using size-capped collection profiles (Lean / Balanced / Full); timed collect; abort | PerfView parked in a Tools folder |
| `ProcDump/ProcDumpMonitor.ps1` | Self-installing background monitor (scheduled task) that auto-captures crash / hang / exception dumps and keeps the newest N | Yes (scheduled task; also copies `Common/` next to its installed copy) |
| `ProcDump/ProcDumpCase.ps1` | One-shot "capture a case": runs an app under ProcDump, collects dumps + evidence, zips it | No - temporary |

Each tool can also be run directly and self-elevates; each keeps its own config/state under its own
`%ProgramData%\<tool>` folder, and dot-sources the shared `Scripts/Common/` components.

## Versioning & releases

The `VERSION` file is the single source of truth. To publish a new version (maintainers, needs `gh`
authenticated to GitHub):

```powershell
.\scripts\New-Release.ps1 -Bump patch -WhatIf   # preview
.\scripts\New-Release.ps1 -Bump patch           # bump VERSION + CHANGELOG, commit, tag vX.Y.Z, publish
```

`-Bump major|minor|patch` raises `VERSION` and records a `CHANGELOG.md` entry; `-Version X.Y.Z` sets an
explicit value; with neither it releases the version already in `VERSION`. GitHub attaches the source
zipball automatically, which is what `src/Get.ps1` installs; the installed copy's version is compared
against the latest release to decide when to update.

## Notes

- `PerfView.exe` and other tool binaries are **not** committed (see `.gitignore`); the scripts download and
  signature-verify them at runtime.
- Dumps, traces and logs are local capture output and are git-ignored.
- The GUI needs an STA desktop session (Windows PowerShell 5.1 default); on headless/Server Core it falls
  back to the text menu automatically.
