# Changelog

All notable changes to the reporting-troubleshooting toolset. The `VERSION` file is the single source of
truth; each release is tagged `vX.Y.Z` and published as a GitHub release by `scripts/New-Release.ps1`.

<!-- NEW RELEASES INSERTED BELOW -->

## [v1.0.54] - 2026-10-30
Changes since v1.0.53:

### Features
- context-free Get-DumpEvent + single parse+id path (Resolve-DumpIdentity) (#01) (375f555)
- offline-first known store + ETag/304 sync + manual-collect manifest (#09 #10) (320a424)
- gzip dumps at rest, disk-budget retention, and offline-safe telemetry (7e286b7)
- add Test Telemetry button + surface the real reason for sync failures (895bc9e)

### Refactoring
- armer only arms; a separate ingest worker owns dump detection/triage/retention (#16) (0af72a1)
- remove dead duplicate parsers + fold dump-deletion to one helper (#13) (cefa56e)
- parse-once + rename-fold-in-triage, ledger-based retention, sync/flush split (#15 #07 #14) (be4c670)
- drop the .info.txt sidecar; derive machine identity from the dump filename (#11) (29bbf9f)
- replace registry with the device-ledger (held/granted/uploaded) + collect decision (2868aba)

### Documentation
- split architecture into core (host) and monitor (tool) libraries (b005c71)
- target architecture for the edge agent (layers, concerns, stores, flows) (2d06008)

### Tests
- run the real ingest worker (DumpTriage -DumpDir) e2e + add -DryRun (#16 #02) (2260a7e)
- end-to-end over a generated minidump (#02) (5ab5f74)


## [v1.0.53] - 2026-10-28
Changes since v1.0.52:

### Features
- dump type as a single Full/Mini-plus/Mini selector (-ma and -mp are mutually exclusive) (#94) (87b1c9e)


## [v1.0.52] - 2026-10-28
Changes since v1.0.51:

### Features
- exception arg as one -e checkbox + a level number box (blank=-e, 1=-e 1) (#86) (4bce2e6)


## [v1.0.51] - 2026-10-28
Changes since v1.0.50:

### Features
- triage suppresses a signature this device already uploaded (durable per-device dedup from the profile) (#84) (249b939)


## [v1.0.50] - 2026-10-28
Changes since v1.0.49:

### Features
- sync the per-device collection profile (CONTRACT 4a) and drop redundant firstSeenOnDevice (#82) (d6b11c2)

### Fixes
- known-signature sync creates the baseline dir and fails closed to -1 (#80) (ffb76ec)


## [v1.0.49] - 2026-10-28
Changes since v1.0.48:

### Features
- emit firstSeenOnDevice so the backend can grant a dump per device per signature (#68) (752123e)
- configurable background-worker CPU priority (WorkerPriority) in General settings (#76) (66acf4c)


## [v1.0.48] - 2026-10-28
Changes since v1.0.47:

### Features
- move the live monitor log into its own sub-tab and Verify deps into General (#72) (31949ca)

### Fixes
- never prune a dump that still has a pending outbox event (un-flushed) (#75) (18c91c6)
- delete dumps after the flush handles them; keep only failed-uploads; retire Suppressed/Recycle (#73) (47e7cc7)


## [v1.0.47] - 2026-10-28
Changes since v1.0.46:

### Features
- live dump-compression progress indicator on the Monitor tab (#65) (ab47ee8)

### Fixes
- stop double-processing renamed dumps and handle ProcDump's .exe in the process token (#70, #71) (f80937d)
- delete suppressed recurrence dumps by default and prune the Suppressed store (#67) (4bebc22)


## [v1.0.46] - 2026-10-28
Changes since v1.0.45:

### Features
- ProcDump args as toggles and split monitor settings into sub-tabs (#53) (657a4ec)
- log dump compression progress; keep compression strictly upload-gated (#65, #64) (d05f28e)
- gzip dumps as the last step before upload (#43) (62247ab)
- rename captured dumps to ProcDump_<pc>_<process>_<tag>_<date>_<time> (#51) (7ed1e72)

### Fixes
- enforce a 60s minimum re-arm cooldown to stop the ProcDump re-arm loop (#63) (2dcf206)

### Chores
- retire the one-shot ProcDumpCase capture tool (#52) (58955ae)


## [v1.0.45] - 2026-10-28
Changes since v1.0.44:

### Fixes
- only archive a telemetry event once its granted dump actually uploaded (#42) (17042d3)


## [v1.0.44] - 2026-10-28
Changes since v1.0.43:

### Features
- log every telemetry flush so sends are no longer invisible (#38) (ce80e6a)


## [v1.0.43] - 2026-10-28
Changes since v1.0.42:

### Features
- upload dumps under the server-issued grant from the events 202 (#38) (d363fce)

### Fixes
- conform the edge event+upload to the fleet wire contract so grants issue (#38) (42bac6c)


## [v1.0.42] - 2026-10-28
Changes since v1.0.41:

### Features
- telemetry enabled by default now that endpoints ship with the build (7280df2)
- ship the encoded telemetry endpoint blob with the build (1edaf9c)
- fleet telemetry endpoints are a local untracked encoded blob, Bearer auth (26e7468)
- Start/Stop Monitor act on the service when enabled, else a non-persistent run (78632ac)
- a branch install disables the release monitor (stop+disable the shared task) so the branch can be tested (d76910e)
- make telemetry operable from the monitor - config keys, outbox housekeeping, status (6ce9dab)
- monitor runs the telemetry forwarder on a timer (off by default) and deploys it (abf8ff4)
- forwarder uploads the full dump for a new signature and stamps the object key (94796cc)
- edge telemetry transport client with local-default targets (backend = URL swap) (b10d552)
- central heap enrichment - count Visual/FrameworkElement/BindingExpression for an escalated dump (58cb2f7)

### Fixes
- blank BaselinePath no longer crashes the triage worker (53311b3)
- GUI-launched monitor no longer no-ops from an inherited RT_LIBRARY (e369095)
- say 'Downloaded to' at the end of Get.ps1 and drop the trailing monitor-tab hint (6e24b43)
- say 'Downloaded to' at the end of Get.ps1 and drop the trailing monitor-tab hint (fcefa79)
- Start Monitor falls back to a non-persistent run when the task points at an old path (4c4d29e)
- install branch builds to the normal location, not an isolated branch dir (92d5fe0)
- run triage worker from src and keep Get.ps1 to install-only (12641a0)
- fail loudly on an incomplete engine deploy instead of silently producing no JSON (1d88c23)
- show the branch name + commit in the version label so a branch build is distinguishable (32eea83)
- deploy Common recursively so the installed monitor gets the Dump engine (Common\Dump\*) (8a823f4)
- branch install must not disable the shared monitor task (it broke Start); only stop prod's running capture (647e641)

### Refactoring
- drop redundant copy-model fallback in the -Triage worker path (ff159fc)
- run monitor scripts in place from src; Enable only registers the task (no script copying) (5191d18)
- branch builds install to the normal location (drop the half-isolation + takeover) (d0b44ba)
- make the heap walk an opt-in edge tool (gated merge, reuse a result), not an auto path (2f988a3)

### Tests
- aggregate runner for the full dump+telemetry+heap suite (one command, exit code) (e7b3430)
- deterministic tests for the heap-enrichment merge gating (synthetic result, no walk) (baeb394)
- deterministic tests for the telemetry transport (synthetic events, local sinks) (4da6846)


## [v1.0.41] - 2026-10-27
Changes since v1.0.40:

### Features
- measure WPF storm facts (operation, recursion depth) and keep hang verdicts fact-only (cdf10cb)
- attribute hangs to the application frame and keep vendor frames in the fault stack (302d668)
- version the signature scheme so the recipe can change without breaking history (331116b)
- emit a procdump-facts/v1 event per capture to the local outbox (d483030)

### Fixes
- derive deviceId from the dump (machine number) instead of nulling it off-box (7f8cff9)
- source the computer name from the dump (ProcDump comment / info.txt sidecar), not the analyst host (773a1bc)
- keep the full managed stack in the event instead of omitting deep framework frames (d26377d)
- separate vendor code executing at the leaf from a vendor-triggered framework storm at the root (bd4de38)
- read environment (os, cpus, arch) from the dump SystemInfo stream and set the hang thread id from the walk (d6eb51a)

### Refactoring
- split the dump engine into focused Dump/* modules and make it self-sufficient (860869b)

### Tests
- deterministic unit tests for the dump engine classification, signature and diagnosis logic (1ec8fa4)


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






















































