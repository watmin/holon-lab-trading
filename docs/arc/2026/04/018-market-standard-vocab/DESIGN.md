# Lab arc 018 — market/standard vocab

**Status:** opened 2026-04-24. Fifteenth Phase-2 vocab arc.
**Last market sub-tree vocab.** Heaviest port — first
**window-based vocab** (takes `Vec<Candle>`, not a single
candle's sub-struct). Surfaced wat-rs arc 047 (Vec accessors
return Option) + four new substrate primitives during the
sketch; consumed straight after they shipped.

**Motivation.** Port `vocab/market/standard.rs` (166L, ~2× the
prior heaviest). Eight atoms describing window-level context:

```
since-rsi-extreme   since-vol-spike      since-large-move
dist-from-high      dist-from-low        dist-from-midpoint
dist-from-sma200    session-depth
```

Four plain Log + four scaled-linear. The Log atoms introduce a
**new domain shape** — "time-since-event" counts, asymmetric,
lower-bounded at 1 (matches arc 017's count-starting-at-1
family). The scaled-linear atoms are cross-Ohlcv-Trend distance
ratios, plus window aggregates (high, low, midpoint of window).

---

## Shape — the first window-based signature

```scheme
(:trading::vocab::market::standard::encode-standard-holons
  (window :Vec<trading::types::Candle>)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

**Departure from the cross-sub-struct rule.** Arcs 008/011
established "vocab functions declare every sub-struct they
read." But standard.wat reads MULTIPLE FIELDS of MULTIPLE
candles in the window — decomposing into per-candle sub-struct
slices is impractical and unhelpful (the iteration shape needs
the full Candle).

**Window vocabs take `Vec<Candle>` directly.** This is
substrate-honest: the function summarizes across time, which
inherently requires the candle as a whole. The arc 008 rule
applies to single-candle vocabs (twelve of them so far);
window vocabs get their own shape.

If a future cave-quest reveals a way to pass "Vec of sub-struct
projections" cleanly, revisit. Until then, `Vec<Candle>` is the
honest shape for window-takers.

---

## Empty-window guard

Archive returns `Vec::new()` for an empty window. The wat
equivalent: emit zero holons, scales unchanged.

```scheme
(:wat::core::if (:wat::core::empty? window) -> :VocabEmission
  (:wat::core::tuple (:wat::core::vec :wat::holon::HolonAST) scales)
  ;; ... non-empty branch ...
)
```

The non-empty branch can call `last`, `f64::max-of`, and
`f64::min-of` without worrying about None — they return Option
honestly per arc 047, but we know the inputs are non-empty
inside the guarded branch. Match-with-unreachable-:None pattern
applies (same as arc 047 sweep callsites).

---

## Substrate primitives consumed (all from arc 046 + 047)

| Primitive | Use in standard.wat |
|---|---|
| `:wat::core::last` (arc 047) | `current = last(window)` |
| `:wat::core::find-last-index` (arc 047) | three callers — `since-rsi-extreme`, `since-vol-spike`, `since-large-move` |
| `:wat::core::f64::max-of` (arc 047) | `window-high = max(map window high)` |
| `:wat::core::f64::min-of` (arc 047) | `window-low = min(map window low)` |
| `:wat::core::f64::max` (arc 046) | `since-X = max(1, n - last-idx)` floor pattern |
| `:wat::core::map` | project window to high / low / etc. |
| `:wat::core::length` | window size |
| `:wat::core::empty?` | empty-window guard |
| `:trading::encoding::round-to-2/4` | atom value rounding |
| `:wat::holon::Log`, scaled-linear | encoding |

---

## The "since-X" atoms — count-starting-at-1 family extension

Three atoms compute "how many bars since the last X event":

```rust
let mut last_rsi_extreme_idx = 0;
for (i, c) in candle_window.iter().enumerate() {
    if c.rsi > 80.0 || c.rsi < 20.0 {
        last_rsi_extreme_idx = i;
    }
}
let since_rsi_extreme = (n - last_rsi_extreme_idx) as f64;
```

Then `since_rsi_extreme.max(1.0)` floor, round-to-2, encode as
plain Log.

In wat — `find-last-index` returns `Option<i64>`:

```scheme
((last-rsi-idx :Option<i64>)
  (:wat::core::find-last-index window
    (:wat::core::lambda ((c :Candle) -> :bool)
      (:wat::core::let*
        (((rsi :f64) (:Candle::Momentum/rsi (:Candle/momentum c))))
        (:wat::core::or
          (:wat::core::> rsi 80.0)
          (:wat::core::< rsi 20.0))))))
((since-rsi-extreme :f64)
  (:wat::core::match last-rsi-idx -> :f64
    ((Some i)
      (:trading::encoding::round-to-2
        (:wat::core::f64::max
          (:wat::core::i64::to-f64
            (:wat::core::i64::- n (:wat::core::i64::+ i 1)))
          1.0)))
    (:None
      (:trading::encoding::round-to-2
        (:wat::core::i64::to-f64 n)))))   ;; no match → entire window
```

Wait — let me think about the indexing. Archive's Rust:
- `last_rsi_extreme_idx` defaults to 0
- After loop: `since = (n - last_idx) as f64`

If no match, `last_idx` stays 0, `since = n`. So no-match returns
n.

If last match at index `i`, `since = n - i`. For the most recent
candle (i = n-1): `since = 1`. Good.

But wait — Rust's archive uses 0-indexed. find-last-index returns
0-indexed too. So `since = n - i`:
- i = n-1 (most recent match): since = n - (n-1) = 1 ✓
- i = 0 (oldest match): since = n - 0 = n
- no match (i defaults to 0 in archive): since = n

Per archive, the no-match case ALSO returns n (because
last_idx defaults to 0 → since = n - 0 = n). So our None case
should return n.

In wat:
```scheme
((since-rsi-extreme-raw :i64)
  (:wat::core::match last-rsi-idx -> :i64
    ((Some i) (:wat::core::i64::- n i))
    (:None n)))
((since-rsi-extreme :f64)
  (:trading::encoding::round-to-2
    (:wat::core::f64::max
      (:wat::core::i64::to-f64 since-rsi-extreme-raw)
      1.0)))
```

Cleaner. Let me design BOTH the round/max sequence properly.

Bounds for the Log: count-starting-at-1 family from arc 017.
Arc 017 used `(1.0, 20.0)` for crypto 5m. For standard.wat, the
maximum possible value is window length (typically 100+). Use
`(1.0, 100.0)` for standard.wat — covers a 100-bar window's
saturation.

`session-depth` is `(1 + n).max(1)` — same family, same bounds.

---

## The distance atoms

Cross-Ohlcv compute "(price - X) / price" where X is window-high,
window-low, window-mid, or sma200 of the current candle. round-to-4,
scaled-linear. Same shape as arc 013 momentum's close-sma* family.

```scheme
((dist-from-high :f64)
  (:trading::encoding::round-to-4
    (:wat::core::f64::/ (:wat::core::f64::- price window-high) price)))
```

window-mid = (window-high + window-low) / 2 — derived from
aggregates.

---

## Why standard last in market sub-tree

Standard.wat is qualitatively different from the prior 12
market vocabs:
- Window-based (Vec<Candle>) vs single-candle (sub-struct slice)
- 4 Log + 4 scaled-linear (heaviest mix yet)
- Three find-last-index callers (validates arc 047's primitive)
- Two window aggregates (validates f64::max-of/min-of)

Shipping it last means every prior arc's pattern is in place;
this arc's complexity is concentrated on the window-shape
novelty + substrate primitive consumption.

---

## Non-goals

- **Rule revision for window-vocabs at arc 008's level.** The
  K-sub-struct rule still applies to single-candle vocabs.
  Standard.wat is simply different — takes Vec<Candle>. If more
  window-vocabs ship (in the exit/* tree?), name the pattern in
  that arc's DESIGN.
- **Cave-quest sub-struct projections from Vec<Candle>.** A
  hypothetical `(map-projection window :Candle::Momentum/rsi)`
  primitive would let standard.wat read sub-struct fields without
  the full Candle. Defer until a second window-vocab needs it.
- **`compute-atom` helper.** The recurrence question (open since
  arc 011) reaches its third look here. Standard.wat has 4
  distance atoms of the same shape ("(price - X) / price"). Even
  with the recurrence, the per-atom variation (different X) +
  the per-X-source (window aggregate vs current candle field)
  keeps a closure-passing helper unwieldy. **Stay inline; close
  the question — no helper warranted at this point.**
- **`unwrap` primitive for Option.** The match-with-unreachable
  pattern works; explicit unwrap reintroduces the Haskell wart
  arc 047 just retired.
- **Empirical N=100 refinement.** Best-current-estimate; explore
  data later if observation shows otherwise.
