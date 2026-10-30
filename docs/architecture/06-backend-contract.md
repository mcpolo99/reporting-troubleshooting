# 06 - Backend contract (consumed behind one gateway)

The agent only **consumes** the backend, with a send-only fleet key, always through the BackendGateway
port ([04](04-ports-and-contracts.md)) - never raw HTTP in a use case. Request/response shapes are the
gateway's, kept distinct from the domain. A local-file stand-in satisfies the same port, so the whole
agent runs with no server (the offline / local mode).

| Operation | Used by | Meaning |
|---|---|---|
| `GET /v1/known-signatures` (ETag/304) | Sync | the analysed-signature set -> known store |
| `GET /v1/profile?deviceId` | Sync | this device's collection state -> merge into the ledger |
| `POST /v1/events` (Idempotency-Key = eventId) | Flush | deliver one report; the `202` may carry an upload grant |
| `POST /v1/dumps` (X-Upload-Grant) | Flush | upload one evidence artifact, only under a grant |

Contract notes:

- **Idempotency key per event** - a retry of the same report is deduped server-side, so delivery is safe.
- **The grant is the sole upload authority** - issued per (signature, device), capped, operator
  kill-switch; the agent can never force an upload.
- **The payload is opaque to the backend** - the report's own schema is the producer's; the backend stores
  and indexes it without validating fields.
- **Versioned additively** - an unknown payload version is stored, never rejected.
- **deviceId** is derived from the capture (invariant 6, [01](01-concept.md)), never from the host running
  an off-box process.
