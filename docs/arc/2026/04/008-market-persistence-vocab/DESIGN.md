# Lab arc 008 — market/persistence vocab

**Status:** opened 2026-04-23. Sixth Phase-2 vocab arc.
**First cross-sub-struct port.** Resolves task #49 — the
cross-sub-struct vocab signature pattern — by choosing the
rule and demonstrating it on the simplest cross-sub-struct
caller.

**Motivation.** Port `vocab/market/persistence.rs` (36L). Three
scaled-linear atoms — `hurst`, `autocorrelation`, `adx` —
derived from two different Candle sub-structs. No Log, no
conditional emission. The simplest possible cross-sub-struct
shape.

---

## The cross-sub-struct signature rule (closes task #49)

Arcs 001 – 007 each read **one** Candle sub-struct. Every
remaining market vocab module reads two or more. The signature
question task #49 named: when a vocab reads K ≥ 2 sub-structs,
what does its parameter list look like?

**The rule:** *the vocab signature declares every sub-struct it
reads, one parameter per sub-struct, alphabetically ordered by
sub-struct type name.* Scales is last. This is a straight
continuation of arcs 001 – 007's "vocab reads its specific
sub-struct" pattern — K=1 scales to K≥2 linearly, not as a new
shape.

| Module | Signature (alphabetical sub-struct order) |
|---|---|
| arc 001 — shared/time | `(t :Candle::Time) (scales :Scales) -> :VocabEmission` |
| arc 005 — market/oscillators | `(m :Candle::Momentum) (r :Candle::RateOfChange) (scales :Scales) -> :VocabEmission` |
| arc 006 — market/divergence | `(d :Candle::Divergence) (scales :Scales) -> :VocabEmission` |
| arc 007 — market/fibonacci | `(r :Candle::RateOfChange) (scales :Scales) -> :VocabEmission` |
| **arc 008 — market/persistence** | `(m :Candle::Momentum) (p :Candle::Persistence) (scales :Scales) -> :VocabEmission` |

### Why this rule, not alternatives

**Not "pass the full Candle"** — that signature lies about
scope. A function declaring `(c :Candle)` could touch any
field; the type reveals nothing about what the function
actually reads. Arc 001 rejected this implicitly with the
header-comment pattern *"vocab reads its specific sub-struct."*
Extending to K≥2 under the same principle is coherent;
reverting to monolithic Candle pass would retract arc 001's
call.

**Not "wrap sub-structs in a per-vocab view struct"** — a new
named struct per cross-sub-struct vocab (9+ types) that exists
only to group fields of the same underlying Candle. Ceremony
without information: the view struct's single consumer unpacks
it immediately. Hickey test fails — the wrapper name conflates
"which sub-structs this vocab reads" with "the Candle itself."

**Not "anonymous tuple"** — positional access inside the
function body (`first views`, `second views`) loses the per-
param names the declared signature gives you.

### What the rule means for the dispatcher (Phase 3.5)

The thought_encoder dispatcher, when it ships, knows each
vocab's declared sub-struct reads. At dispatch time it extracts
the right sub-structs from the Candle (via `:Candle/momentum`,
`:Candle/persistence`, etc. — the auto-generated field
accessors from arc 019's struct runtime) and calls each vocab
with its declared inputs. Extraction lives at ONE site (the
dispatcher); each vocab signature stays honest about what it
reads.

This is the same shape arc 006 established for conditional
emission: orchestration stays in the caller; the vocab function
declares what it needs and consumes that exactly.

---

## Shape

Two sub-structs, both accessed via their auto-generated field
getters:

| Position | Atom | Source field | Value |
|---|---|---|---|
| 0 | `hurst` | `:Candle::Persistence/hurst p` | `round-to-2(hurst)` |
| 1 | `autocorrelation` | `:Candle::Persistence/autocorrelation p` | `round-to-2(autocorrelation)` |
| 2 | `adx` | `:Candle::Momentum/adx m` | `round-to-2(adx / 100.0)` |

All three thread `Scales` values-up through sequential
scaled-linear calls. Returns `VocabEmission`.

Field order in the emitted holons matches the archive:
Persistence fields first (hurst, autocorrelation) then
Momentum's adx. The archive's order isn't alphabetical; it
reflects the semantic grouping *"memory-in-the-series
properties first, directional-strength second."* We preserve
that. Signature order (alphabetical by sub-struct type) and
emission order (semantic) are distinct concerns — the type
system only cares about the first.

---

## Why persistence first

- Simplest cross-sub-struct: K=2, all scaled-linear, no Log,
  no conditional. Demonstrates the rule without introducing
  any new fog.
- No bound observation needed (unlike regime, which has 2 Log
  atoms still requiring an `explore-log.wat` pass).
- The rule is the whole teaching artifact; persistence is the
  first worked example. Subsequent cross-sub-struct arcs
  inherit the rule without re-deriving it.

Expected ship time: ~25 minutes including tests + INSCRIPTION.

---

## Non-goals

- **No emission-order rule sweep.** Arcs 005 – 007 each picked
  their own emission order (parameter order in the enclosing
  scaled-linear chain). Arc 008 continues that — the archive's
  order is the chosen order. We don't retroactively standardize
  across past arcs.
- **No rewrite-backlog verbose replay.** The rule gets one
  Phase 2 note in `rewrite-backlog.md` pointing at this arc's
  INSCRIPTION. Future cross-sub-struct arcs reference the note;
  they don't re-explain the rule.
- **No test for the rule itself.** The rule is a convention,
  enforced by reviewer taste + the type checker catching
  missing fields. Tests verify behavior (the 3 emitted holons);
  they don't verify the signature shape.
