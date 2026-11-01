# 06 - Backend contract (consumed behind one gateway)

The agent only **consumes** the backend, with a send-only fleet key, always through the BackendGateway
port ([04](04-ports-and-contracts.md)) - never raw HTTP in a use case. Request/response shapes are the
gateway's, kept distinct from the domain. A local-file stand-in satisfies the same port, so the whole
agent runs with no server (the offline / local mode).

| Operation | Used by | Meaning |
|---|---|---|
| `GET /v1/known-signatures` (ETag/304) | Sync | the analysed-signature set -> known store |
| `GET /v1/profile?deviceId` | Sync | this device's collection state -> merge into the ledger |
| `POST /v1/events` (Idempotency-Key = `dump-sha256:<hex>`) | Flush | deliver one report; the `202` may carry an upload grant |
| `POST /v1/dumps` (X-Upload-Grant) | Flush | upload one evidence artifact, only under a grant |

Contract notes:

- **Idempotency key is the dump content hash** (CONTRACT §3): the canonical literal `dump-sha256:<64 lowercase
  hex>` (76 chars = `dump-sha256:` + 64), keyed on the dump's RAW bytes, not a per-event id - so the same
  physical dump is deduped server-side however many times or by whomever it is re-sent (a re-generated blob or a
  re-ingested copy never double-counts). A sample-less recurrence with no content identity falls back to the
  event's unique id. Delivery is always safe to retry.
- **Statistics dedup is durable** (CONTRACT §7/§8): counts are deduped permanently on the tuple
  `(signatureId, deviceId, dump.sha256)` in durable storage, so a re-submitted or backfilled identical dump
  raises a count by at most one - independent of the Idempotency-Key and its 7-day TTL. The content key is the
  fast near-term short-circuit; this tuple is the long-term guarantee. Both the live and backfill paths honour it.
- **The grant is the sole upload authority** - issued per (signature, device), capped, operator
  kill-switch; the agent can never force an upload.
- **The payload is opaque to the backend** - the report's own schema is the producer's; the backend stores
  and indexes it without validating fields.
- **Versioned additively** - an unknown payload version is stored, never rejected.
- **deviceId** is derived from the capture (invariant 6, [01](01-concept.md)), never from the host running
  an off-box process.
