# Changelog

All notable changes to the reporting-troubleshooting toolset. The `VERSION` file is the single source of
truth; each release is tagged `vX.Y.Z` and published as a GitHub release by `scripts/New-Release.ps1`.

<!-- NEW RELEASES INSERTED BELOW -->

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


