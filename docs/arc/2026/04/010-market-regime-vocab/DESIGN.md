# Lab arc 010 — market/regime vocab

**Status:** opened 2026-04-23. Eighth Phase-2 vocab arc.
Single sub-struct (K=1). First arc since 005 to exercise the
Log-bounds observation reflex per Chapter 35.

**Motivation.** Port `vocab/market/regime.rs` (83L). Eight atoms
describing "what kind of market is this" — trending,
mean-reverting, chaotic, or structured. Seven scaled-linear;
one Log.

---

## Shape

Single sub-struct (`Candle::Regime`); signature trivially satisfies
arc 008's rule. One Log atom requires bound selection via
observation.

```scheme
(:trading::vocab::market::regime::encode-regime-holons
  (r :trading::types::Candle::Regime)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Emission order follows archive:

| Pos | Atom | Source | Value | Encoding |
|---|---|---|---|---|
| 0 | `kama-er` | `:Regime/kama-er r` | `round-to-2(raw)` | scaled-linear |
| 1 | `choppiness` | `:Regime/choppiness r` | `round-to-2(raw / 100)` | scaled-linear |
| 2 | `dfa-alpha` | `:Regime/dfa-alpha r` | `round-to-2(raw / 2)` | scaled-linear |
| 3 | `variance-ratio` | `:Regime/variance-ratio r` | `round-to-2(max(raw, 0.001))` | **ReciprocalLog 10.0** |
| 4 | `entropy-rate` | `:Regime/entropy-rate r` | `round-to-2(raw)` | scaled-linear |
| 5 | `aroon-up` | `:Regime/aroon-up r` | `round-to-2(raw / 100)` | scaled-linear |
| 6 | `aroon-down` | `:Regime/aroon-down r` | `round-to-2(raw / 100)` | scaled-linear |
| 7 | `fractal-dim` | `:Regime/fractal-dim r` | `round-to-2(raw - 1)` | scaled-linear |

---

## Why N=10 for variance-ratio (observation-first)

`explore-log.wat` (on disk alongside this DESIGN) tabulates
cosine-vs-reference-1.0 at three candidate bound settings for
values 0.1 – 20.0. Observed behavior at d=1024 (coincident? fires
when cosine > 0.96875):

| value | N=2 (0.5, 2) | N=3 (⅓, 3) | N=10 (0.1, 10) |
|---|---|---|---|
| 0.1 | 0 | 0 | 0 |
| 0.3 | 0 | 0 | 0.48 |
| 0.5 | 0 | 0.37 | 0.70 |
| 0.9 | 0.85 | 0.90 | 0.96 |
| 1.0 | 1.00 | 1.00 | 1.00 |
| 1.1 | 0.86 | 0.91 | 0.96 |
| 2.0 | 0 | 0.37 | 0.70 |
| 3.0 | 0 | 0 | 0.52 |
| 10.0 | 0 | 0 | 0 |

Analysis:

- **N=2** — per-1% resolution near 1.0, total saturation at
  ±doubling. Right for ROC (ratio-near-1.0, rarely doubles per
  candle — arc 005's answer). **Wrong for variance-ratio** —
  0.5 and 2.0 are meaningful regime signals (mean-reverting vs
  trending) that should stay distinguishable. N=2 collapses
  them to the same saturation value.
- **N=3** — per-5% resolution near 1.0, saturates at ±tripling.
  Middle option; still loses fine-grained signal outside
  ±tripling.
- **N=10** — per-10% resolution near 1.0 (coarse at small
  excursions) but **full financial range preserved**. 0.3 and
  3.0 stay distinguishable (cos 0.48 and 0.52 — well below
  the 0.97 coincidence threshold). 0.5 and 2.0 reach cos 0.70.
  The complete variance-ratio regime map survives encoding.

**Domain argument:** regime's job is "what kind of market" —
random-walk vs mean-reverting vs trending. Small fluctuations
around 1.0 (noise) SHOULD collapse; different orders of magnitude
(0.5/2.0 vs 0.1/10) SHOULD distinguish. N=10 matches. ROC wanted
the opposite (fine-near-1.0, ±doubling saturation); regime
wants coarse-near-1.0, ±10× saturation.

**First-principles tie:** the archive's pre-058-017 Log was
`10^-5` to `10^5` — "10 orders of magnitude." That was overkill
under 058-017's Thermometer-Log semantics (everything centered
around 1.0 saturated at wide bounds). The honest financial range
for variance ratio at 5-minute candles is one order of magnitude
each way — `(0.1, 10)` = `(1/10, 10/1)` = N=10 in arc 034's
reciprocal-pair family.

---

## The one-sided floor on variance_ratio

Archive: `variance_ratio.max(0.001)`. Preserves Log-semantic safety
against value=0 under the pre-058-017 substrate. Under 058-017's
Thermometer-Log, values below `min` saturate at the bottom
regardless — the `.max(0.001)` floor is operationally moot
(0.001 < 0.1 = N=10's min, so anything ≤ 0.001 saturates the
same as 0.001). We preserve it anyway as a defensive marker: if
the data ever introduces NaN/Inf from raw zeros, the floor
keeps Log honest.

Inline 2-line:
```scheme
((vr-floored :f64)
  (:wat::core::if (:wat::core::>= vr-raw 0.001) -> :f64
    vr-raw
    0.001))
```

Same one-sided-if pattern as arc 009's inline clamp minus one branch.

---

## Why regime after stochastic, not before

- Regime needs Log-bound observation; stochastic didn't.
  Knocking out stochastic first kept the cross-sub-struct rule's
  first demonstration clean (arc 009 = pure rule exercise, zero
  fog). Regime is the first arc that combines a shipped rule
  with an observation requirement.
- Regime re-exercises Chapter 35's observation reflex — proves
  it holds as standing practice beyond arc 005's single instance.

---

## Non-goals

- **No ReciprocalLog bound change.** `(0.1, 10)` is N=10 from
  arc 034's family; no new primitive needed.
- **No variance-ratio-specific alias.** The macro call
  `(ReciprocalLog 10.0 vr)` IS the name; wrapping it in
  `VarianceLog` would mumble.
- **No observation-program sharing.** `explore-log.wat` stays
  per-arc, on disk as a teaching artifact. When a third arc
  needs Log bounds, each writes its own.
