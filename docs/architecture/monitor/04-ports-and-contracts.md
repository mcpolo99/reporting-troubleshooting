# 04 - Ports & contracts

Ports are named for the **need**, not the technology; the use case that needs the behavior owns the
interface, and an adapter at the edge implements it ([03](03-layers-and-dependency-rule.md)).

| Port | What crosses it | Fulfilled by |
|---|---|---|
| CaptureControl | arm / re-arm / detach a capture tool against an app | process control over ProcDump |
| DumpReader | parse a dump once -> reason, exception, pid, tag + signature inputs | minidump byte parser |
| SignatureResolver | parsed facts (+ a managed walk when needed) -> a stable signatureId | ClrMD-backed walker + id recipe |
| EvidenceCompressor | write a dump to its final gzipped resting file | streamed gzip |
| LedgerStore | read / merge / upsert per-signature state, count, sample | the ledger document |
| KnownStore | read the analysed-signature set; refresh it | the known store (backend or shipped package) |
| Outbox | append a report; drain pending; archive sent; park failed | the outbox directory |
| EvidenceStore | put / get / evict / move-to-manual the evidence artifacts | the dump directory |
| BackendGateway | events, grant, dump upload, known-signatures, profile | HTTP client, or a local-file stand-in |
| LinkProbe | is the backend reachable right now? | reachability check |
| Clock / Log | time; diagnostics | OS clock, log files |

## The one contract between concerns: the stores

The concerns ([02](02-capabilities-and-contexts.md)) never call each other. The Armer's ProcDump writes a
dump file; from there every concern only reads/writes the **ledger, known store, outbox, and dump dir**
through the ports above. That shared store set is the single inter-concern contract.

**Tradeoff (accepted):** the store shapes become a contract, so a store-schema change touches every
concern that reads it. We take that cost because it buys full independence (a slow/failed concern never
blocks another) and offline durability (the stores are the memory when there is no backend). See
[05](05-stores-and-data-model.md) for the shapes.
