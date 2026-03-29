# Wat Discoveries

Ideas, findings, and improvements encountered while backfilling the wat specifications.
Append-only. Each entry dated. The act of writing specifications reveals gaps.

---

## 2026-03-29: Writing manager.wat

1. **The manager's temporal encoding was wrong.** Used `encode_log(hour)` — a scalar
   where hour 3 and 4 are "close." Should be named atoms: `(bind hour-of-day h20)`.
   Fixed in code. The act of writing the wat spec caught the bug.

2. **The manager's `day-of-week` atom actually binds to session, not day.** We encode
   `(bind day-of-week asian-session)` not `(bind day-of-week monday)`. The session is
   more market-relevant than the calendar day. But the atom name is misleading. Should
   we rename to `trading-session`? Or keep both?

3. **The `motion` fact bundles delta with the snapshot.** The final thought is
   `bundle(snapshot, delta)`. Is this the right composition? The delta is a different
   KIND of information than the snapshot — it's about change, not state. Should it be
   bound with a role atom instead of just bundled? e.g. `(bind change-atom delta)`
   rather than raw bundle? Currently the delta IS bound with `panel-delta` atom so
   this is already correct.

4. **Panel coherence uses expert THOUGHT vectors, not convictions.** The cosine between
   two expert thought vectors measures how similar their VIEWS of the market are, not
   how similar their opinions are. Two experts could see the market differently
   (low coherence) but agree on direction (high agreement). These are distinct signals.
   Both are in the manager's vocabulary. Good.

5. **Missing: the manager doesn't know HOW proven each expert is.** The gate is binary
   (proven/not). But an expert at 55% accuracy is more reliable than one at 52.1%.
   Should the manager encode a `reliability` scalar per proven expert? This would let
   the discriminant weight experts by quality, not just presence.

6. **Missing: the manager doesn't know how LONG each expert has been proven.** An expert
   that just opened its gate (100 resolved predictions) is less trustworthy than one
   that's been open for 5000. Tenure as a fact?
