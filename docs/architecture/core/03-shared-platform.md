# 03 - Shared platform

The services every tool reuses. These belong to core (the host), not to any one tool - a tool dot-sources
them ([02](02-shell-and-tool-hosting.md)). Tool-specific engines (e.g. the Monitor's dump-signature and
telemetry logic) are NOT platform even if they physically sit beside these; they belong to that tool's
subsystem.

## Package store + install engine

The single source of truth for tool binaries (ProcDump, PerfView, etc.).

- **One machine-wide shared store.** A binary is installed once per machine and reused by every tool and
  every build variant - never a per-tool or per-case copy.
- **Install engine** (one implementation, reused by GUI and CLI): download, signature-verify, extract to
  the store, and report readiness. Re-install stops any in-use processes first.
- Exposed two ways over the same engine: a CLI menu option, and a GUI surface that runs the install in a
  tool runspace off the UI thread.
- Preserves any layout a tool needs inside the store (e.g. subfolders a tool's binary requires).

## Logging

One logging facility, reused by the host and every tool: per-launch log files, size-roll, retention by
count, and a console echo mode the GUI uses to capture a tool's output on its information stream.

## Configuration conventions

- Each tool keeps its **own config** under its own machine-wide location; the host does not centralize it.
- Config is merged over defaults so a new setting appears without discarding a user's edits, and an
  invalid saved value heals back to a default.
- The host reads a tool's config through the tool's runspace (so the tool owns its own schema).

## Bootstrap, elevation & update

- **Bootstrap:** a one-line installer downloads the release (or a named branch), version-checks against
  what is installed, installs only when newer, and launches. A branch build is isolated from the stable
  install but reuses the shared store.
- **Elevation:** the app self-elevates on start (the tools need admin for ETW, scheduled tasks, dumps).
- **Version:** a single `VERSION` file is the source of truth, stamped into tools at release.
- **Update:** reinstalls in place over the one-line installer; config and the shared store survive.
