# 08 - Rules, stated plainly

The rules that bind every part. They restate the invariants ([01](01-concept.md)) as working rules.

- **Report** happens for every capture, always - the occurrence signal; durable and retried until the
  backend accepts it. There is no "do not report" path.
- **Collect = keep the dump bytes; drop = do not keep the bytes** (still reported). The word "suppress" is
  retired because it blurred these two.
- A dump is deleted locally in exactly two cases:
  1. a **confirmed upload** (the backend now holds it), or
  2. it was **never collected** (dedup / known / already-uploaded).
  A held, un-delivered dump is **never** auto-deleted - only evicted once `uploaded`, or moved out by a
  manual collect.
- **Retention evicts only `uploaded` evidence**, oldest first, to stay under the disk budget. It never
  evicts `held`/`granted` or any dump whose report is still pending (including parked/failed events). Over
  budget with only held dumps -> warn, never silently delete; manual collect is the relief valve.
- **Offline tracking is real:** the local ledger alone prevents one-dump-per-recurrence with no backend,
  and reconciles cleanly when the link returns. A failed sync is a clean no-op, never a destructive rewrite.
- **The backend is the sole upload authority:** the agent offers evidence via a grant, never forces it;
  with no backend, nothing uploads and everything is kept.
- **Machine identity comes from the capture** (its environment/filename), never from the host running an
  off-box process.
- **Single source of truth:** one ledger for dedup, one parse per dump, one home per shared helper - no
  duplicated state and no duplicated logic.
