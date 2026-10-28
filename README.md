# reporting-troubleshooting

Scripts run on customer PCs to capture crash / hang / performance evidence for dump analysis. The dumps
and traces produced here are analysed separately by the dumps-analysis-toolkit.

There are two ways to start it - an online one-liner, and an offline local launcher.

### Online (no clone, no manual copying)

Run this in a PowerShell / terminal - it downloads the latest release, installs it and opens the launcher:

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/mcpolo99/reporting-troubleshooting/main/src/Get.ps1')))
```

The bootstrap (`src/Get.ps1`) elevates, checks the installed version against GitHub, downloads only when
there is a newer version, installs to `%ProgramData%\ReportingTroubleshooting`, and opens the launcher.

Pass switches after the closing `)` of the one-liner, e.g. to install the **develop** branch:

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/mcpolo99/reporting-troubleshooting/main/src/Get.ps1'))) -Dev
```

any branch by name (slashes are allowed, e.g. a feature branch):

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/mcpolo99/reporting-troubleshooting/main/src/Get.ps1'))) -Branch feature/my-change
```

| Switch | Effect |
|---|---|
| `-Branch <name>` | install that branch's head instead of the stable release (for testing) |
| `-Dev` | shorthand for `-Branch develop` |
| `-Force` | reinstall even if already up to date |

A branch build is **isolated**: it installs to `%ProgramData%\ReportingTroubleshooting\branch\<name>` and runs
from there, so it never overwrites the stable install at `%ProgramData%\ReportingTroubleshooting`. The shared
tool store (`...\Packages`) and per-tool data (`...\Monitor`, `...\PerfView`) stay machine-wide, so a branch
build reuses already-installed tools instead of re-downloading them. Omit both switches for the normal stable
install from the latest release.

### Offline (download the source, run it as-is)

Download / copy the `src/` folder to the target PC and double-click / run **`src\run.bat`**. It launches
the local `ReportingToolkit.ps1` directly (elevated, via Windows Terminal if present) - no internet, no
install step. The launcher opens as a small WPF window by default; `-CLI` gives a text menu, which is also
the automatic fallback where WPF is unavailable.

(Downloading a tool binary such as PerfView still needs internet the first time, but the launcher itself
and the menu run fully offline.)

## Layout

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
| `src/GUI/` | `Show-MainWindow.ps1` (interactive window), `ToolRunspace.ps1` (per-tool background runspaces), `Set-WindowThemeResources.ps1` (light/dark), `Get-SystemUsesDarkMode.ps1` |
| `src/CLI/` | `Show-CliMenu.ps1` |
| `src/Helpers/` | `Start-Tool.ps1` |
| `src/Common/` | `Logging.ps1`, `Common.ps1` - shared components dot-sourced by the tools |
| `src/Tools/` | the capture tools (see below) |

## Tools (`src/Tools/`)

| Tool | What it does | Installed? |
|---|---|---|
| `PerfView/PerfViewCapture.ps1` | Installs PerfView; one Start/Stop model for every ETW/ETL trace using size-capped collection profiles (Lean / Balanced / Full / Max). Start runs a single `collect` with the stop event always armed; an optional max-seconds field adds a time cap (0 = run until Stop); Stop (or any process writing the event) stops it, merges + zips and reports the file; Abort force-cancels | PerfView parked in a Tools folder |
| `ProcDump/ProcDumpMonitor.ps1` | Self-installing background monitor (scheduled task) that auto-captures crash / hang / exception dumps and keeps the newest N | Yes (scheduled task; also copies `Common/` next to its installed copy) |

The launcher window drives these **in-process**: toggles, profile selection and actions (install,
start/stop/abort capture, monitor install/start/stop, case capture) run in a background runspace
per tool - no console is spawned - with output streamed to the window. Each tool can still be run
directly as a standalone script too; each keeps its own config/state under its own `%ProgramData%\<tool>`
folder and dot-sources the shared `src/Common/` components.

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
