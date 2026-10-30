# Architecture - reporting-troubleshooting

Target architecture for the whole application. It is an admin **host shell** a technician runs on a
customer PC to capture troubleshooting evidence; the shell hosts a set of **tools**, each its own
subsystem. Everything here is how we want it to be, not a description of today's code.

```
reporting-troubleshooting (host app)
├── core      ← the host/shell + shared platform (launcher, GUI/CLI, tool hosting, package store, logging)
└── tools
    ├── monitor    ← always-on crash/hang capture + telemetry agent   (fully specified)
    ├── perfview   ← on-demand ETW/ETL capture                        (tool, not yet specified here)
    └── packages   ← shared tool-binary install/verify surface        (platform; see core)
```

## Libraries

| Area | What it covers |
|---|---|
| [core/](core/README.md) | The application itself: self-elevating bootstrap/update, the GUI and CLI shells, the isolated-runspace tool-hosting model and the tool plugin contract, the shared package store + install engine, logging and config conventions. |
| [monitor/](monitor/README.md) | The Monitor tool: the background agent that arms capture, turns a dump into a deduplicated report + compressed evidence, keeps a per-machine ledger, and reconciles with the backend online / offline / manually. |

A tool (monitor, perfview) is a **plugin** the core hosts: a standalone entry script with its own
per-tool config, hosted off the UI thread in an isolated runspace, dot-sourcing the shared platform. Core
knows how to launch and host a tool; it does not know a tool's internals. Each tool's own subsystem
architecture lives in its folder here.

Start with [core/](core/README.md) for the host, then [monitor/](monitor/README.md) for the agent.
