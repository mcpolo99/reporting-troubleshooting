# 03 - Layers & dependency rule

Four layers, dependencies point **inward only**. Inner layers are pure policy; outer layers are swappable
detail. Nothing inner names anything outer - the outer side implements interfaces (**ports**,
[04](04-ports-and-contracts.md)) the inner side defines.

```mermaid
flowchart TD
  subgraph DRV["Frameworks & drivers - swappable detail (outermost)"]
    D["ProcDump · ClrMD · minidump format · WPF · scheduled task · HTTP · filesystem · registry"]
  end
  subgraph ADP["Interface adapters - triggers & gateways"]
    TRIG["Triggers: ProcDump lifecycle · dump-dir watcher · timers · GUI · CLI"]
    GW["Gateways/repos: backend client (HTTP or local stand-in) · store repos · process control · dump parser · stack walker · compressor"]
  end
  subgraph APP["Application - use cases + the ports they need"]
    UC["ArmCaptures · IngestCapture · ReconcileLedger · DeliverReports · EnforceRetention · CollectForManual"]
    PORTS["ports: CaptureControl · DumpReader · SignatureResolver · EvidenceCompressor · LedgerStore · KnownStore · Outbox · EvidenceStore · BackendGateway · LinkProbe · Clock · Log"]
  end
  subgraph DOM["Domain - pure policy (innermost)"]
    E["signature identity · report-vs-collect decision · ledger state machine · retention eligibility · machine-identity derivation"]
  end

  TRIG --> UC
  UC --> E
  UC --> PORTS
  GW -. implements .-> PORTS
```

| Layer | Holds | Depends on |
|---|---|---|
| **Domain** (pure) | the signature concept, the report-vs-collect rules, the held/granted/uploaded state machine, retention-eligibility rules, deriving machine identity from a capture | nothing |
| **Application** (use cases + ports) | one use case per capability, and the port interfaces each needs | Domain only |
| **Interface adapters** | trigger surfaces (what wakes a use case) and gateway/repo implementations of the ports | Application |
| **Frameworks & drivers** | ProcDump, ClrMD, the minidump format, WPF, the scheduled-task host, HTTP, the filesystem, the registry | plug-ins |

**Dependency rule:** a trigger invokes a use case; the use case runs domain policy and calls ports it
owns; infrastructure implements those ports. Swapping the backend (HTTP vs local stand-in), the capture
tool, the UI, or the store medium never touches the domain or the use cases. If any such swap would force
a change inside a use case or the domain, the rule is being broken.
