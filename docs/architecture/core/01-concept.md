# 01 - Concept (host)

## What the host app is

A single, self-elevating desktop application a technician runs on a customer PC to capture troubleshooting
evidence. It is a **shell + platform**, not a capture tool itself: it presents one control surface, hosts
a set of tools, and provides the shared services they all need. The capture/analysis logic lives in the
tools ([monitor/](../monitor/README.md), perfview); the host launches, hosts, installs, and updates them.

## Actors

| Actor | Relationship |
|---|---|
| On-site technician / user | Runs the app, drives tools from the GUI or CLI |
| Hosted tools (Monitor, PerfView, Packages) | Plugins the host launches and hosts; the host does not know their internals |
| The machine / OS | Provides elevation, the shared store location, the scheduled-task host a tool may use |

## Capabilities

| Capability | Meaning |
|---|---|
| Present one control surface, two forms | A WPF window by default; a text menu on `-CLI` or where WPF is unavailable - interchangeable |
| Host tools off the UI thread | Run each tool's actions in an isolated runspace so a long action never freezes the shell |
| Install & verify tool binaries | Obtain the binaries a tool needs from a shared machine-wide store, signature-verified |
| Bootstrap, elevate, self-update | Download/version-check/install the app; run elevated; update in place |
| Shared logging & config | Common logging and per-tool configuration conventions |

## Invariants (host)

1. **The control surface never blocks on a tool.** Every tool action runs off the UI thread; the shell
   stays responsive.
2. **Tools are isolated from each other.** Each runs in its own runspace; their state and colliding names
   never clash.
3. **One shared store is the single source for tool binaries** - installed once per machine, reused by
   every tool and every build variant, never per-tool copies.
4. **The host runs fully offline.** Launching, hosting, and the menus need no network; network is a tool's
   concern.
5. **The GUI and the CLI are equivalent** control surfaces over the same host operations; neither is
   privileged, and the CLI is the guaranteed fallback.
6. **The host does not depend on any tool's internals** - it launches and hosts a tool through a small,
   uniform contract.

## Size

A small host. Its architecture earns exactly three boundaries: the **delivery shell** (GUI vs CLI vary),
the **tool plugin boundary** (tools are added/changed independently and must not block or couple to the
host), and the **shared platform** (the package store/installer is a swappable service behind the host's
use cases). See [04](04-layers-and-dependency-rule.md).
