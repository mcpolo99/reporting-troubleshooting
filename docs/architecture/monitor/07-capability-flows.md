# 07 - Capability flows

How each capability moves through the layers, end to end.

## Ingest pipeline (dump lands -> report, no network)

The dump is parsed **exactly once** and the signatureId computed **exactly once**, in the detached triage
step (the hang/managed-exception id needs the slow ClrMD walk). Rename is folded into the gzip - the
final-named `.dmp.gz` is written straight from the placeholder - so the id is computed first, then the
file gets its final name, once. The report is written last, pointing at the final file.

```mermaid
flowchart TD
  subgraph WATCH["Ingest watcher - detect only (no parse)"]
    C0["a new ...pending....dmp appears (ProcDump wrote it)"] --> C1{"write complete?<br/>size stable + not locked"}
    C1 -->|no| C1
    C1 -->|yes| C5["enqueue detached triage worker (placeholder path)"]
  end
  subgraph TRI["Triage - parse once, id once"]
    T1["parse dump header ONCE -> reason, exception, pid, tag + signature inputs"]
    T1 --> T2{"tier-2 kind?<br/>hang / managed exception"}
    T2 -->|yes, ClrMD ok| T3["managed stack walk (frames, storm, UI)"]
    T2 -->|no| T4
    T3 --> T4["stable signatureId ONCE (+ tag, + provisional?)"]
    T4 --> T5{"collect decision<br/>(ledger + known store + link state)"}
    T5 -->|collect / defer| G1["write FINAL-named <pc>_<proc>_<tag>_<date>_<time>.dmp.gz<br/>(rename + gzip in one), delete placeholder"]
    G1 --> G2["ledger: state=held, record sample, localCount++"]
    T5 -->|drop| D1["delete placeholder bytes; ledger: localCount++"]
    G2 --> R1["build event, write report to outbox (references the final .dmp.gz)"]
    D1 --> R1
  end
  C5 --> T1
```

## Collect decision (first match wins)

Two independent axes per capture. **Report** is unconditional - every capture emits one durable event and
bumps `localCount`. **Collect** decides only the dump *bytes*, top to bottom, first match wins:

| # | Condition | Bytes | Why |
|---|---|---|---|
| 1 | id **provisional** (managed walk pending) | KEEP (defer) | cannot dedup on an unreliable id |
| 2 | ledger = **uploaded** (this device already uploaded this id) | DROP | backend holds our sample |
| 3 | ledger **held/granted** and the sample is **on disk** | DROP | we already hold one - local dedup |
| 4 | ledger held/granted but the sample is **gone** (evicted/lost) | KEEP (re-held) | re-acquire a sample we lost |
| 5 | **known/analysed** and **offline** (no grant can come) | DROP | nothing can request it; do not hoard |
| 6 | **known/analysed** and **online** | KEEP (held) | the per-device grant is the authority; hold one |
| 7 | otherwise (new on this machine) | KEEP (held) | first sample here |

Offline duplicate-avoidance is rows 2-3: the ledger's `sample` is the "I already have one for this id"
memory, so repeated crashes of one signature while offline keep exactly ONE dump. Online, the grant stays
the sole upload authority (rows 5-6).

```mermaid
flowchart TD
  A["new dump -> signatureId"] --> P{"id provisional?"}
  P -->|yes| K1["KEEP (defer)"]
  P -->|no| U{"ledger = uploaded?"}
  U -->|yes| D1["DROP - backend has ours"]
  U -->|no| H{"held/granted sample on disk?"}
  H -->|yes| D2["DROP - local dedup"]
  H -->|no, sample lost| K2["KEEP - re-held"]
  H -->|not held| N{"known/analysed?"}
  N -->|yes, offline| D3["DROP - no grant possible"]
  N -->|yes, online| K3["KEEP (held) - grant decides upload"]
  N -->|no| K4["KEEP (held) - first sample here"]
```

Every branch also emits the report; `DROP`/`KEEP` is only about the bytes.

## Sync (pull) and Flush (push) are separate

Staying in sync is not part of flushing - distinct jobs, failure modes, and cadence, each single-instance.

- **Sync (pull), read-only:** refresh the known store; merge the backend profile into the ledger (backend
  `uploaded`/`granted` overlaid on local `held`, never a blind overwrite). Writes only local stores. Useful
  on its own - keeps the collect decision correct even with an empty outbox - so it runs on its own cadence.
- **Flush (push):** per outbox event, deliver it; on a grant, upload the held `.dmp.gz` -> mark `uploaded`
  + free the local copy; no grant -> archive the event, the dump stays `held`.
- **When both run:** sync first (fresh state), but independent - a failed sync never stops a flush, and a
  sync runs when there is nothing to flush.

```mermaid
flowchart TD
  subgraph SYNC["Sync (pull) - read-only reconcile"]
    SK["GET known-signatures (ETag) -> known store"]
    SP["GET profile -> MERGE into ledger<br/>held kept; held->uploaded reconciled; local copy freed"]
  end
  subgraph FLUSH["Flush (push)"]
    EV["for each outbox event: POST events (Idempotency-Key)"]
    GR{"grant?"}
    UP["POST dumps (held .dmp.gz) -> 201<br/>ledger=uploaded, delete local bytes"]
    AR["archive event; dump stays held"]
    EV --> GR
    GR -->|yes| UP
    GR -->|no| AR
  end
  SYNC -->|fresh state first, but independent| FLUSH

  RET["retention: size budget<br/>evict only uploaded, oldest first<br/>never held / granted / pending"]
  MAN["Collect -> DumpDir manual-outbox<br/>outbox reports + held .dmp.gz, removed from the send loop"]
```

## Link lifecycle

```mermaid
flowchart LR
  ONLINE["ONLINE"] -->|link dropped| OFFLINE["OFFLINE"]
  OFFLINE -->|re-linked| ONLINE
  ONLINE -->|operator / user| MANUAL["MANUAL"]
  OFFLINE -->|operator / user| MANUAL

  ONLINE -.- O1["sync known store + profile (merge)<br/>drain outbox, upload held on grant<br/>reconcile held->uploaded, evict uploaded"]
  OFFLINE -.- F1["no server; dedup via local ledger + cached/shipped known store<br/>outbox + held dumps accumulate (bounded by disk, never dropping held)"]
  MANUAL -.- M1["Collect moves outbox + held .gz to manual-outbox<br/>hand-carry to an online PC; removed from the send loop"]
```
