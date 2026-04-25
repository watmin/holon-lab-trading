# Lab arc 015 — market/ichimoku vocab

**Status:** opened 2026-04-24. Twelfth Phase-2 vocab arc. Sixth
cross-sub-struct port. K=3 (Divergence + Ohlcv + Trend) — second
K=3 module. **Triggers `clamp` extraction** to
`vocab/shared/helpers.wat` — five clamp callers in this module
plus the prior arc 009 inline use puts the count well past arc
014's "fourth caller" threshold.

**Motivation.** Port `vocab/market/ichimoku.rs` (61L). Six atoms
describing Ichimoku cloud structure and TK relationships:

```
cloud-position    cloud-thickness   tk-cross-delta
tk-spread         tenkan-dist       kijun-dist
```

Five scaled-linear (clamped to [-1, 1]) + one plain Log
(cloud-thickness, asymmetric).

---

## Shape

K=3, alphabetical-by-leaf: **D** < **O** < **T**.

```scheme
(:trading::vocab::market::ichimoku::encode-ichimoku-holons
  (d :trading::types::Candle::Divergence)
  (o :trading::types::Ohlcv)
  (t :trading::types::Candle::Trend)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Emission preserves archive order:

| Pos | Atom | Source | Compute | Encoding |
|---|---|---|---|---|
| 0 | `cloud-position` | Ohlcv + Trend | nested-if + clamp ±1, round-to-2 | scaled-linear |
| 1 | `cloud-thickness` | Ohlcv + Trend | `cloud-width / close` floor 0.0001, round-to-4 | plain Log |
| 2 | `tk-cross-delta` | Divergence | clamp ±1, round-to-2 | scaled-linear |
| 3 | `tk-spread` | Ohlcv + Trend | `(tenkan - kijun) / (close × 0.01)` clamp ±1, round-to-2 | scaled-linear |
| 4 | `tenkan-dist` | Ohlcv + Trend | `(close - tenkan) / (close × 0.01)` clamp ±1, round-to-2 | scaled-linear |
| 5 | `kijun-dist` | Ohlcv + Trend | `(close - kijun) / (close × 0.01)` clamp ±1, round-to-2 | scaled-linear |

Five of six atoms cross sub-structs (Ohlcv + Trend), echoing arc
013 momentum's pattern. The "compute-atom helper?" question raised
by arc 011 + 013 surfaces again — the recurrence is undeniable but
the per-atom let-binding chain stays honest.

---

## Extracting `clamp` to `vocab/shared/helpers.wat`

Arc 014's INSCRIPTION named the threshold: "Three two-arm-if
shapes now (signum arc 011, clamp arc 009, abs arc 014). One more
caller and a unified family extraction becomes the right move."

Arc 015 has **five** clamp callers in one module (cloud-position,
tk-cross-delta, tk-spread, tenkan-dist, kijun-dist). Plus arc 009
stochastic's prior inline. Six total. Extraction pays for itself
the moment it ships.

Define:
```scheme
(:wat::core::define
  (:trading::vocab::shared::clamp
    (v :f64) (lo :f64) (hi :f64)
    -> :f64)
  (:wat::core::if (:wat::core::< v lo) -> :f64
    lo
    (:wat::core::if (:wat::core::> v hi) -> :f64
      hi
      v)))
```

General form (caller passes bounds), not specialized to
`clamp ±1`. The general form lets future callers use other bounds
without reinventing. Migration of arc 009's inline clamp to use
the helper is **out of scope** for arc 015 — non-essential
churn; arc 009 remains historically frozen, and a future arc
can sweep if desired.

`signum` and `f64-abs` stay inline — single uses each (arc 011,
arc 014). Family extraction can wait until a fourth two-arm-if
caller surfaces beyond clamp.

---

## cloud-position's nested compute

Cloud-position is the most computed atom in the module — it has
a **nested branch**:

```rust
if cloud_width > 0.0 {
    clamp((close - cloud_mid) / cloud_width.max(close * 0.001), -1.0, 1.0)
} else {
    clamp((close - cloud_mid) / (close * 0.01), -1.0, 1.0)
}
```

Two design decisions in archive:
- **Outer guard**: when `cloud_width > 0`, scale by `cloud_width`
  itself (with a 0.1%-of-price floor); when collapsed, scale by
  fixed 1%-of-price denominator.
- **Inner floor**: `cloud_width.max(close * 0.001)` — the floor
  prevents division-by-zero when `cloud_width` is positive but
  tiny. Two-arm `if` shape (third floor inline use after arc 010
  variance-ratio and arc 013 atr-ratio).

The inner floor is single-use here; stay inline. The outer guard
is the standard nested-if structure. wat translation:

```scheme
((cloud-mid :f64)
  (:wat::core::f64::/
    (:wat::core::f64::+ cloud-top cloud-bottom) 2.0))
((cloud-width :f64) (:wat::core::f64::- cloud-top cloud-bottom))
((cloud-position-raw :f64)
  (:wat::core::if (:wat::core::> cloud-width 0.0) -> :f64
    (:wat::core::let*
      (((cw-floor :f64) (:wat::core::f64::* close 0.001))
       ((denom :f64)
        (:wat::core::if (:wat::core::> cloud-width cw-floor) -> :f64
          cloud-width
          cw-floor)))
      (:wat::core::f64::/
        (:wat::core::f64::- close cloud-mid) denom))
    (:wat::core::f64::/
      (:wat::core::f64::- close cloud-mid)
      (:wat::core::f64::* close 0.01))))
((cloud-position :f64)
  (:trading::encoding::round-to-2
    (:trading::vocab::shared::clamp cloud-position-raw -1.0 1.0)))
```

---

## cloud-thickness — second plain-Log caller

Asymmetric domain (cloud-width as fraction of price, always
between 0 and ~0.5). Same shape as arc 013 atr-ratio — plain
`:wat::holon::Log` with bounds (floor, generous-upper).

- Lower bound: 0.0001 (matches archive's `.max(0.0001)` floor)
- Upper bound: 0.5 (generous; cloud thickness ≥ 50% of price is
  pathological)

Round-to-4 (not archive's round-to-2): same substrate-discipline
correction as arc 013 atr-ratio. round-to-2 of 0.0001 collapses
to 0.00 → ln(0). round-to-4 preserves the floor exactly.

Arc 013 named the precedent; arc 015 cites it. Lab now has at
least two plain-Log atoms — the asymmetric-domain pattern is
established.

---

## Why ichimoku before keltner / price_action / standard

- **Triggers clamp extraction** — five callers in one module is
  the strongest extraction signal yet. Shipping the helper now
  simplifies every subsequent vocab arc.
- **Second plain-Log caller** confirms the arc-013 pattern;
  asymmetric-domain Log atoms now have two precedents.
- **K=3 again** — second K=3 module (arc 014 was first).
  Repetition strengthens the cross-sub-struct rule.
- **Pure compute, no observation pass** — the clamp + nested
  branches are mechanical; no need for empirical bound choice
  beyond cloud-thickness's plain-Log bounds.

---

## Non-goals

- **Sweep arc 009's inline clamp to use the helper.** Arc 015
  ships the helper; arc 009 stays frozen. Migration is its own
  arc if/when desired.
- **Extract `f64-abs` and `signum` family.** Only two non-clamp
  two-arm-if callers (signum arc 011, abs arc 014). Wait for a
  fourth.
- **Specialize `clamp-symmetric` (1-arm helper for `clamp ±1`).**
  General form covers the use case; specialization fights the
  one place a different bound shows up (cloud-position's outer
  branch uses different denominators but the same ±1 clamp; the
  4 other clamp callers ALL use ±1, so a clamp-symmetric helper
  WOULD cover most uses — but the saved characters per call are
  small and the general form is more obvious to readers).
- **Generalized `compute-atom` helper for cross-sub-struct
  atoms.** Five callers in this module + arc 013's four = nine
  total. The shape varies per atom (different numerators,
  denominators, post-processing). A closure-passing helper still
  fights wat's let-binding ergonomics. Stay inline; reconsider
  for arc 016+ (standard.wat, the heaviest).
