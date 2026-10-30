# Core - the host application

The application itself: the shell a technician runs, and the platform the tools plug into. The Monitor and
PerfView are tools this host launches and hosts; core owns everything that is not a specific tool's
internals. Part of the whole-app architecture ([`../README.md`](../README.md)).

## Reading order

| # | Topic | Answers |
|---|---|---|
| [01](01-concept.md) | Concept | What the host app is - purpose, actors, invariants |
| [02](02-shell-and-tool-hosting.md) | Shell & tool hosting | The GUI/CLI shells, the isolated-runspace model, the tool plugin contract |
| [03](03-shared-platform.md) | Shared platform | Package store + installer, logging, config, bootstrap/update |
| [04](04-layers-and-dependency-rule.md) | Layers & dependency rule | The host's layers and why a tool is a plugin behind a boundary |

## One-paragraph concept

A single self-elevating desktop app a technician runs on a customer PC to capture troubleshooting
evidence. It presents one control surface in two interchangeable forms (a WPF window, or a text menu), and
hosts a set of tools - each run **off the UI thread in its own isolated runspace** so a long action never
freezes the shell and tools never collide. It installs and verifies the tool binaries it needs from a
shared machine-wide store, and bootstraps/updates itself. It runs fully offline; the network belongs to
the tools, not the host.
