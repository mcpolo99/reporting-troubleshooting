# Changelog

All notable changes to the reporting-troubleshooting toolset. The `VERSION` file is the single source of
truth; each release is tagged `vX.Y.Z` and published as a GitHub release by `scripts/New-Release.ps1`.

<!-- NEW RELEASES INSERTED BELOW -->

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















