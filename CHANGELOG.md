# Changelog

All notable changes to the reporting-troubleshooting toolset. The `VERSION` file is the single source of
truth; each release is tagged `vX.Y.Z` and published as a GitHub release by `scripts/New-Release.ps1`.

<!-- NEW RELEASES INSERTED BELOW -->

## [v1.0.40] - 2026-10-27
Changes since v1.0.39:

### Refactoring
- rename UI install wording to download/enable and update/create (9366b9e)


## [v1.0.39] - 2026-10-26
Changes since v1.0.38:

### Fixes
- stop PerfView progress heartbeat when the capture is finished (1607ba1)


## [v1.0.38] - 2026-10-26
Changes since v1.0.37:

### Refactoring
- one Start/Stop PerfView capture model, event-stoppable (013f9ed)


## [v1.0.37] - 2026-10-26
Changes since v1.0.36:

### Features
- live PerfView progress + Max capture profile (e36e623)


## [v1.0.36] - 2026-10-26
Changes since v1.0.35:

### Fixes
- Monitor install no longer crashes with a prompt error in the GUI (694958d)


## [v1.0.35] - 2026-10-26
### Fixes
- 32-bit (WOW64) monitored apps are now handled correctly. ClrMD loads the target's DAC as native code, so the fault-identifier now runs the attach/walk in the PowerShell host matching the target bitness, and the monitor captures each app with the matching-bitness ProcDump (procdump.exe for 32-bit, procdump64.exe for 64-bit). Previously a 32-bit app (e.g. the Biesse Wrt.* services) produced "Dac architecture mismatch" and an unwalkable dump.


## [v1.0.34] - 2026-10-26
### Features
- The main window is split into reusable per-tab controls: MainWindow.xaml is now just the shell, and each tab (Packages, PerfView, ProcDump Monitor, ProcDump Case) lives in its own file under Schemas\Tabs\, so tabs are easy to maintain in isolation.
- "Verify deps" moved to the ProcDump Monitor tab and no longer needs an existing dump: for each monitored app it detects the .NET runtime from the live process and passively attaches to prove the fault-identifier can load it. Gaps (missing walker, unsupported runtime, attach failure) are logged to KnownIssues\gaps.jsonl.
- Packages tab gains "Check for updates": detects a newer build (latest release for a stable install, the branch head for a branch build) and installs + relaunches in one click.


## [v1.0.33] - 2026-10-26
### Features
- `-Branch <name>` installs any branch's head for testing, isolated under `%ProgramData%\ReportingTroubleshooting\branch\<name>` so it never overwrites the stable install. `-Dev` is now shorthand for `-Branch develop`. The shared tool store and per-tool data stay machine-wide, so a branch build reuses already-installed tools.

### Fixes
- Release automation now publishes notes via `--notes-file`, so multi-line notes containing quotes like "this" and 'that' no longer break `gh release create`.


## [v1.0.32] - 2026-10-26
### Features
- Dump fault-identification and known-issues de-duplication. Every crash, hang or exception dump is given a STABLE fault id (crash = faulting module+offset; hang / managed exception = the normalised managed call stack, walked with ClrMD using the .NET Framework DAC already on the machine). Occurrences are recorded per machine; the first dump of an issue is kept and later recurrences are counted and suppressed, so already-analysed problems stop piling up.
- "Verify deps" button on the Packages tab: checks the environment the hang/exception walk relies on and proves it by walking a real dump on that machine.

### Fixes
- PerfView now caches symbols in its own dedicated Symbols subfolder instead of a shared/unset location.


## [v1.0.31] - 2026-10-25
Changes since v1.0.30:

### Fixes
- detach many ProcDump instances concurrently so Stop isn't slow (6825da6)


## [v1.0.30] - 2026-10-25
Changes since v1.0.29:

### Fixes
- ProcDump output no longer garbled or flooding the log (9febf37)


## [v1.0.29] - 2026-10-25
Changes since v1.0.28:

### Fixes
- Stop/Uninstall actually kill the monitor loop so ProcDump stops respawning (e586829)


## [v1.0.28] - 2026-10-25
Changes since v1.0.27:

### Fixes
- heal corrupt Apps config so the monitor attaches again (9e1b705)


## [v1.0.27] - 2026-10-25
Changes since v1.0.26:

### Fixes
- don't wait the detach timeout on unmanageable orphan ProcDumps (7b33352)


## [v1.0.26] - 2026-10-25
Changes since v1.0.25:

### Fixes
- name orphaned ProcDump instances instead of logging a blank app (9ad92ea)


## [v1.0.25] - 2026-10-25
Changes since v1.0.24:

### Fixes
- TaskUser populates and is a user picker, not an empty box (a2dc36d)


## [v1.0.24] - 2026-10-25
Changes since v1.0.23:

### Fixes
- treat the harmless render-target warning as benign, not a UI error (7b8bfb2)


## [v1.0.23] - 2026-10-25
Changes since v1.0.22:

### Fixes
- split commit hash/subject without a PS7-only escape (9fd9382)


## [v1.0.22] - 2026-10-25
Changes since v1.0.21:

### Other
-  (8fe11fcbuild: group auto-changelog by conventional-commit type)


## [v1.0.21] - 2026-10-25
Changes since v1.0.20:

- fix: Uninstall keeps config; versions stamped automatically at release (caa630b)


## [v1.0.20] - 2026-10-25
Changes since v1.0.19:

- fix: Uninstall removes only the scheduled task, preserves config (5d0665b)


## [v1.0.19] - 2026-10-25
Changes since v1.0.18:

- fix: monitor Start is self-verifying, never silently launches nothing (d323e6f)


## [v1.0.18] - 2026-10-25
Changes since v1.0.17:

- fix: drop per-tool version from Packages card (eaee9bf)


## [v1.0.17] - 2026-10-25
Changes since v1.0.16:

- fix: stop in-use package processes before (re)install (d0323ad)


## [v1.0.16] - 2026-10-25
Changes since v1.0.15:

- fix: software rendering + real Sysinternals Suite completeness (4566dd0)


## [v1.0.15] - 2026-10-25
Changes since v1.0.14:

- fix: monitor Stop is status-aware and not silent (d851c9b)


## [v1.0.14] - 2026-10-25
Changes since v1.0.13:

- feat: clearer monitor attach logging; TaskUser defaults to the current user (7986f41)


## [v1.0.13] - 2026-10-25
Changes since v1.0.12:

- fix: deleting a Monitor app chip threw a null-method error (d4ea00a)


## [v1.0.12] - 2026-10-25
Changes since v1.0.11:

- fix: a stray UI-thread error no longer kills the whole GUI (47ce54e)


## [v1.0.11] - 2026-10-25
Changes since v1.0.10:

- feat: dumps/traces go to C:\dumps and are named after the computer (2c06877)


## [v1.0.10] - 2026-10-25
Changes since v1.0.9:

- fix: Apps saved as System.Object[]; consolidate all app data under one root (e022a80)


## [v1.0.9] - 2026-10-25
Changes since v1.0.8:

- fix: updater wiped the installed packages on every update (db53c16)


## [v1.0.8] - 2026-10-25
Changes since v1.0.7:

- fix: Monitor Apps chips were invisible (closure script-scope) (d700004)


## [v1.0.7] - 2026-10-25
Changes since v1.0.6:

- feat: Reinstall does a clean wipe-and-reinstall (5b810dc)


## [v1.0.6] - 2026-10-25
Changes since v1.0.5:

- feat: live download progress; drop PerfView tab Install button; tidy install log (994e206)


## [v1.0.5] - 2026-10-25
Changes since v1.0.4:

- fix: package Install button crashed the GUI (script scope in a closure) (996edae)


## [v1.0.4] - 2026-10-25
Changes since v1.0.3:

- fix: run tool runspaces under Bypass and never exit silently on a startup failure (23222da)


## [v1.0.3] - 2026-10-25
Changes since v1.0.2:

- feat: central Packages tab + shared install engine (single source of truth) (5d5822e)


## [v1.0.2] - 2026-10-25
Changes since v1.0.1:

- feat: numeric inputs, app chip-list, Sysinternals Suite install, desktop shortcut (ef7238c)


## [v1.0.1] - 2026-10-25
Changes since v1.0.0:

- Merge pull request #4 from mcpolo99/develop (03ffe52)
- fix: bypass execution policy so the installed script launches on restricted machines (a418726)


## [v1.0.0] - 2026-10-24
- Initial toolset: PerfView performance tracing, self-installing ProcDump monitor, one-shot ProcDump case.
- WPF/XAML launcher (GUI default, `-CLI` text menu) with shared light/dark theme.
- Shared components (logging, admin/signature/prompt/version helpers) under `src/Common`.
- Bootstrap installer (`src/Get.ps1` + `src/run.bat`) with version check against GitHub.








































