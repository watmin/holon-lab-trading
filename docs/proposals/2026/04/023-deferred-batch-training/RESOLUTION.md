# Resolution: Proposal 023 — Deferred Batch Training

**Date:** 2026-04-11
**Decision:** ACCEPTED — implement

## Designers

Both accepted.

**Hickey:** RunnerHistory belongs on the broker, not PaperEntry.
Papers are values. History is learning material. O(n²) avoidable
via suffix-max pass. The three learning rates are discovered from
when information becomes available.

**Beckman:** Don't subsample. Second teaching uses excess (excursion
minus trail), not raw. Violence papers should teach exit too.

## Refinements applied

1. RunnerHistory on broker as HashMap<paper_id, RunnerHistory>
2. PaperEntry gains paper_id (counter on broker)
3. Second market teaching weight = excursion - trail (the excess)
4. Violence papers teach exit (deferred — implement runners first)
5. Suffix-max pass for optimal distance computation (O(n) not O(n²))
