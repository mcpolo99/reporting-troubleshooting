# Monitor subsystem - target architecture

The **Monitor** is the always-on background failure-evidence agent - one of the tools the host application
hosts (see [`../README.md`](../README.md) for the whole app and [`../core/`](../core/README.md) for the
host/shell it runs inside). This library is the Monitor's own backbone: how the capture -> report -> sync ->
flush agent should be. Target design, not today's code - everything here is how we want it to work.

## Reading order

| # | Topic | Answers |
|---|---|---|
| [01](01-concept.md) | Concept | What the agent is - purpose, actors, invariants |
| [02](02-capabilities-and-contexts.md) | Capabilities & concerns | What it must handle, and the single-responsibility concerns that own each |
| [03](03-layers-and-dependency-rule.md) | Layers & dependency rule | The four domain layers and the inward-only dependency direction |
| [04](04-ports-and-contracts.md) | Ports & contracts | Boundaries by role, and the one contract between concerns (the stores) |
| [05](05-stores-and-data-model.md) | Stores & data model | The ledger as the single local source of truth |
| [06](06-backend-contract.md) | Backend contract | The backend the agent consumes, behind one gateway |
| [07](07-capability-flows.md) | Capability flows | Ingest, sync/flush, the collect decision, link lifecycle |
| [08](08-rules.md) | Rules | The plainly-stated rules that bind every part |

## One-paragraph concept

An unattended, per-machine agent that keeps failure capture armed on chosen applications, turns each raw
dump into a durable factual **report** plus a compressed **evidence** artifact, keeps a per-machine
**ledger** of which failure **signatures** it already holds so it never hoards duplicates - even with no
network - and **reconciles** that memory with a central backend when a link exists, degrading cleanly to
fully offline and to manual hand-off. The backend holds the real data; the edge holds exactly enough
local truth to never duplicate and never lose evidence.
