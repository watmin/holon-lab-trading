# Lab arc 005 — market/oscillators vocab

**Status:** opened 2026-04-23. Third Phase-2 vocab arc (arc 001
shared/time, arc 002 exit/time, arc 005 market/oscillators).
Cave-quested wat-rs arc 034 mid-arc for the `ReciprocalLog` macro.

**Motivation.** Port `archived/pre-wat-native/src/vocab/market/oscillators.rs`
(84L) — eight oscillator holons encoded per candle. First market-
tree vocab; opens Phase 2's heaviest remaining sub-tree (14
market modules). Simpler than `standard.rs` (per `rewrite-backlog.md`'s
own "good candidate" note) — per-candle emission, no window,
no custom struct.

---

## Shape

Per arc 001's design refinement, vocab takes sub-structs, not the
full Candle. Oscillators spans two:

- `Candle::Momentum` — holds `rsi`, `cci`, `mfi`, `williams-r`
- `Candle::RateOfChange` — holds `roc-1`, `roc-3`, `roc-6`, `roc-12`

Signature:

```scheme
(:trading::vocab::market::oscillators::encode-oscillators-holons
  (m :trading::types::Candle::Momentum)
  (r :trading::types::Candle::RateOfChange)
  (scales :trading::encoding::Scales)
  -> :(wat::holon::Holons, trading::encoding::Scales))
```

Returns a tuple: 8 holons + updated scales. Same values-up
pattern scaled-linear uses; just with a Vec of holons instead of
one. This is NEW shape — may want naming once a second caller
surfaces. Defer naming per stdlib-as-blueprint discipline.

---

## The eight holons

**First four via `scaled-linear`** — bounded scalars, thread
`Scales`:

| Atom | Value expression | Thresholds from archive |
|---|---|---|
| `rsi` | `round-to-2(rsi)` | 0-100 normalized via learned scale |
| `cci` | `round-to-2(cci / 300.0)` | unbounded, compressed |
| `mfi` | `round-to-2(mfi / 100.0)` | 0-100 normalized |
| `williams-r` | `round-to-2((williams-r + 100.0) / 100.0)` | shifted to [0,1] |

Each produces `Bind(Atom(name), Thermometer(value, -scale, scale))`
via scaled-linear; scales threaded through the HashMap.

**Last four via `ReciprocalLog`** — ratio-valued, no scales
needed:

| Atom | Value expression | Bounds |
|---|---|---|
| `roc-1` | `round-to-2(1.0 + roc-1)` | `(0.5, 2.0)` via ReciprocalLog 2.0 |
| `roc-3` | `round-to-2(1.0 + roc-3)` | same |
| `roc-6` | `round-to-2(1.0 + roc-6)` | same |
| `roc-12` | `round-to-2(1.0 + roc-12)` | same |

Each produces `Bind(Atom(name), Log(v, 0.5, 2.0))` via
ReciprocalLog 2.0 — the smallest reciprocal pair, covers
±doubling per single candle.

**Why ReciprocalLog 2.0 for ROC:** arc 034's DESIGN + INSCRIPTION
records the first-principles rationale. The `(1 + roc)` value is
a price ratio (close/prev); `N=2` saturates at ±100% single-candle
moves (doublings), gives ~1% resolution within normal ranges.

---

## Values-up scales threading

Four `scaled-linear` calls in sequence; each consumes the
previous `Scales` and returns a new one. Final `Scales` is
returned alongside the Holons vec. Log-emitted holons don't
touch scales (no learned scale to track; bounds are fixed).

Pattern:

```scheme
(let* (((e1 :ScaleEmission) (:scaled-linear "rsi" rsi scales))
       ((s1 :Scales) (:second e1))
       ((e2 :ScaleEmission) (:scaled-linear "cci" cci s1))
       ((s2 :Scales) (:second e2))
       ;; ... etc
       ((h5-8 :HolonAST) (:ReciprocalLog 2.0 roc-N))  ;; no scales
       (holons :Holons) (:vec h1 h2 h3 h4 h5 h6 h7 h8))
  (:tuple holons s4))
```

---

## Positive-guard for Log inputs

058-017 Q2: `value > 0` required for ln to be defined.
`(1.0 + roc)` is typically ≥ 0.5 in normal candles but could
approach 0 or go negative in crash scenarios (roc < -1.0 means
close is negative, which is impossible for prices, but the
input field is f64 so theoretically possible).

**Decision:** trust the archive's silent assumption that
`1.0 + roc > 0` always holds for real BTC candles. If a crash
scenario produces roc ≤ -1.0, the test suite will catch it; for
arc 005 we ship without explicit guards. Inline guard helpers
can surface as arc 006's follow-up if a real caller hits the
edge.

---

## Tests

Five outstanding tests:

1. **Count.** `encode-oscillators-holons` returns a tuple whose
   Holons element has 8 elements.
2. **RSI holon shape.** fact[0] coincides with hand-built
   `Bind(Atom("rsi"), Thermometer(round-to-2(rsi), -scale, scale))`
   where scale comes from the updated scales after the call.
3. **ROC holon shape.** fact[4] coincides with hand-built
   `Bind(Atom("roc-1"), Log(round-to-2(1.0+roc-1), 0.5, 2.0))`.
4. **Scales accumulate through the four scaled-linear atoms.**
   After the call, the returned Scales has 4 entries (rsi, cci,
   mfi, williams-r).
5. **Different candles produce non-coincident holons.** Two
   distinct Momentum/RateOfChange inputs emit encodings that
   don't coincide at the level of the bundled holons vec
   (this is coarse; individual holons might be equivalent but
   the full set differs).

Uses arc 031's `make-deftest` + inherited-config shape with a
default-prelude that loads candle + oscillators.

---

## Non-goals

- **No `Oscillators` struct (archive had `OscillatorsThought`).**
  Values inline into `let*`; no intermediate struct needed in
  wat. Matches arc 001's shared/time pattern.
- **No Log bounds config.** ReciprocalLog 2.0 is the per-caller
  choice for this arc. Other market modules make their own call.
- **No vocab-helpers additions.** The wat arc-002-extracted
  `named-bind` and `circ` don't fit oscillators' shape
  (scaled-linear and ReciprocalLog produce differently-shaped
  binds). Oscillators emits directly.
