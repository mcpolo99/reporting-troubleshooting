# 04 - Layers & dependency rule (host)

The host is small; it earns three boundaries - the delivery shell, the tool plugin boundary, and the
shared platform. Dependencies point inward.

```mermaid
flowchart TD
  subgraph DRV["Frameworks & drivers"]
    D["WPF · PowerShell runspaces · scheduled-task host · HTTP (bootstrap) · filesystem · OS elevation"]
  end
  subgraph ADP["Interface adapters"]
    SHELL["Delivery shells: GUI window · CLI menu"]
    PLAT["Platform adapters: package store/installer · logger · runspace host · bootstrap/updater"]
    TOOLHOST["Tool host: launch + host a tool via the plugin contract"]
  end
  subgraph APP["Application - host use cases + ports"]
    UC["LaunchTool · InstallPackage · Check/ApplyUpdate · ReadToolConfig · ShowStatus"]
    PORTS["ports: ToolHost · PackageStore · Logger · UpdateSource · Clock"]
  end
  subgraph DOM["Domain - host policy"]
    E["tool registry (which tools exist) · version/update policy · install readiness rules"]
  end

  SHELL --> UC
  TOOLHOST --> UC
  UC --> E
  UC --> PORTS
  PLAT -. implements .-> PORTS
```

| Layer | Holds | Depends on |
|---|---|---|
| **Domain** | the tool registry concept, version/update policy, install-readiness rules | nothing |
| **Application** | host use cases (launch a tool, install a package, check/apply an update, read a tool's config, show status) + the ports they need | Domain |
| **Interface adapters** | the GUI and CLI shells; the tool host; platform adapters (package store/installer, logger, runspace host, bootstrap/updater) | Application |
| **Frameworks & drivers** | WPF, PowerShell runspaces, the scheduled-task host, HTTP for bootstrap, the filesystem, OS elevation | plug-ins |

## The tool plugin boundary

A tool is a **plugin behind the `ToolHost` port**. The host launches and hosts a tool through the uniform
contract ([02](02-shell-and-tool-hosting.md)); it never names or depends on a tool's internals. This is
the key boundary:

- Adding or changing a tool (Monitor, PerfView, a future tool) never touches the host's use cases or domain.
- A tool runs in its own isolated runspace, so it cannot block the shell or collide with another tool.
- A tool's own subsystem architecture (its layers, its domain) lives in that tool's library - e.g. the
  Monitor's full backbone in [../monitor/](../monitor/README.md). Core stops at the plugin boundary.

**Dependency rule:** a shell or the tool host invokes a host use case; the use case runs host policy and
calls its ports; platform adapters implement those ports; tools plug in behind `ToolHost`. Swapping WPF
for the CLI, or the install source, never reaches the host's domain.
