# 01 - Concept

## What the agent is

An unattended, per-machine **edge agent** on a customer PC. It keeps failure capture armed on configured
applications, turns each crash/hang dump into a durable factual **report** plus a compressed **evidence**
artifact, remembers per machine which failure **signatures** it already holds so it never hoards
duplicates (even with no network), and **reconciles** that memory with a central backend when a link
exists - degrading cleanly to fully offline and to manual hand-off.

It is the producer/edge half of a larger evidence system. The backend is the system of record; the
agent's job is correct, deduplicated, durable evidence, delivered when it can.

## Actors

| Actor | Relationship |
|---|---|
| Monitored applications | The subjects - they crash/hang; the agent captures from them, never controls them |
| Central backend / fleet operator | Consumer and authority: receives reports, authorizes evidence upload, owns the analysed-signature set |
| On-site technician / user | Control plane: enable/disable capture, test the link, collect evidence for manual hand-off, see status |

## Domain vocabulary

- **Capture** - a raw dump produced when a monitored app faults.
- **Signature** - the stable identity of a fault; same signature = same problem.
- **Report (occurrence)** - the factual record of one capture. Always produced.
- **Evidence** - the dump bytes, kept compressed.
- **Ledger** - the machine's memory: per-signature state + occurrence count + retained sample.
- **Known set** - fleet-wide signatures already analysed centrally.
- **Grant** - a backend authorization to upload one evidence artifact for a (signature, machine).
- **Link** - whether the backend is currently reachable.

## Invariants (always true, whatever the tech)

1. Every capture produces exactly **one report**. Occurrence counting never stops.
2. Evidence is **never destroyed until it is safe** - the backend confirmed it, or a human collected it.
3. **At most one evidence artifact per signature per machine** - duplicates are counted, not kept.
4. Reports deliver **at-least-once** - durable until the backend accepts, across reboots/offline.
5. The **backend is the sole upload authority** (grant). The agent offers, never forces; no backend = no upload.
6. Machine identity comes **from the capture**, never from the host that processes it.
7. **One source of truth per fact** - dedup state in one place; a fact derived once.

## Size

A small headless agent, but with real axes of change (capture tool, backend transport, UI, store medium)
and real testability needs (decisions must run with no IO). So: **four conceptual layers shared by a few
peer single-responsibility concerns** that talk only through the stores - no more boundaries than those
axes require. See [03](03-layers-and-dependency-rule.md) and [02](02-capabilities-and-contexts.md).
