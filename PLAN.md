# Enterprise Trading Plan

> **This replaces the original Python-era plan. The system is now a Rust enterprise.**
> **Before touching holon:** read the primers at `../algebraic-intelligence.dev/src/content/docs/blog/primers/`

## Where We Are (2026-03-29)

The enterprise architecture works. Self-organizing expert panel with proof gates.
52.6% direction accuracy at high conviction from gated experts. $10,000 preserved
through 100k candles by refusing to trade without proof. 38 commits in one session.

The system is architecturally complete but not yet profitable. The next phase is
enriching the enterprise with Holon's full toolkit — we've been using ~10% of
what's available.

## Architecture

```
Treasury (HashMap<String, f64>: USDC + WBTC, hold mode)
├── Manager Journal (signed expert configs → raw price direction → Win/Lose)
│   ├── Momentum Expert [GATED, sampled window]
│   ├── Structure Expert [GATED, sampled window]
│   ├── Volume Expert [GATED, sampled window]
│   ├── Narrative Expert [GATED, sampled window]
│   ├── Regime Expert [GATED, sampled window]
│   └── Generalist [GATED, fixed window=48]
├── Risk (5 OnlineSubspace branches — needs fractal rewire)
└── Accounting (trade_ledger, desk_predictions — all predictions paper + live)
```

Gates breathe: experts cycle in/out based on rolling accuracy. The enterprise
self-organizes its composition per market regime.

## Backlog

### Money Path (sequential, blocks profitability)
- [ ] **#17** Hold-mode manager reward — fix profitability metric for asset holding
- [ ] **#18** Fractional allocation — conviction maps to position size, not all-or-nothing
- [ ] **#19** Per-position stop/TP from ATR — each position manages itself
- [ ] **#20** Partial profit taking — reclaim input, let runners run

### Expert Path (each replaces a magic value)
- [ ] **#1** Exit Expert — learns hold/cut/take from trade-in-progress state
- [ ] **#3** Threshold Expert — learns move size from ATR/regime
- [ ] **#4** Horizon Expert — learns resolution time (cross_correlate could solve this)
- [ ] **#5** Position Sizing Expert — learns allocation from treasury state

### Architecture
- [ ] **#14** Risk generalist — same team structure for risk (fractal completion)
- [ ] Fix generalist proof gate (needs own accuracy tracking, not tht_journal curve_valid)
- [ ] S-expression logging — write wat representation of every manager thought to disk
- [ ] Time context atoms for manager (hour-of-day, day-of-week, session)

---

## Holon Toolkit Review

We use ~7 of ~40 available operations. The primers at
`../algebraic-intelligence.dev/src/content/docs/blog/primers/` describe a rich
algebra we built but haven't applied to the trading enterprise.

### What We Use Now
- `atom` (vm.get_vector) — naming concepts
- `bind` — composition (expert × conviction)
- `bundle` — superposition (manager thought = bundled expert opinions)
- `cosine` — measurement (journal prediction)
- `permute` — directional encoding (BUY vs SELL)
- `encode_log` — scalar magnitude
- `OnlineSubspace` — risk branch anomaly detection (disabled currently)

### Critical Gaps — Explore First

#### 1. `difference(before, after)` — What Changed?
The manager sees a snapshot per candle. It should see the DELTA.
"Momentum's conviction jumped from 0.05 to 0.25" is stronger signal than
"momentum is at 0.25."

**Apply to:** Manager input (diff between consecutive expert configs),
risk (diff between portfolio states), experts (diff between thought vectors).

#### 2. `attend(query, memory, strength, mode)` — Soft Attention
Manager currently treats all proven experts equally in the bundle.
Attend would let the manager weight experts by relevance to current context.
Three modes: Hard (binary), Soft (weighted), Amplify (boost matching dims).

**Apply to:** Manager attends to experts based on regime context.

#### 3. `prototype()` + `cleanup()` — Pattern Templates
Prototype extracts consensus from multiple examples. Cleanup snaps noisy
observations to the nearest known pattern.

**Apply to:** Build prototypes of "winning expert config" and "losing expert
config." The manager has a playbook of known good/bad configurations.

#### 4. `segment(stream)` — Regime Change Detection
Detect structural breakpoints in a vector stream without labels.
The gates breathe because accuracy shifts — segment detects the shift directly.

**Apply to:** Expert panel behavior stream. Trigger recalibration at
detected breakpoints instead of fixed recalib_interval.

#### 5. `surprise_fingerprint` via `unbind` — Field Attribution
When the manager sees anomalous config, unbind against each expert atom to
find WHICH expert is driving the anomaly.

**Apply to:** Diagnose WHY the manager predicted a direction. Debug the enterprise.

#### 6. `coherence(vectors)` — Panel Concentration
Mean pairwise similarity of expert opinions. High coherence = all agree =
potentially dangerous exhaustion signal.

**Apply to:** Manager context fact: `(bind panel-coherence (encode-log coherence))`.

#### 7. `cross_correlate(stream_a, stream_b)` — Causal Discovery
Does expert conviction at time t predict price direction at time t+k?
Discovers optimal horizon per expert — replaces hardcoded 36-candle horizon.

**Apply to:** The mechanism for Horizon Expert (#4).

#### 8. Temporal Encoding (`$time`, `$circular`)
Encode time-of-day and day-of-week as circular scalars.
Markets have strong time-of-day effects.

**Apply to:** Manager context: `(bind hour-atom (encode-circular hour))`.

### Medium Priority — Rich Diagnostics

#### 9. `Engram` + `EngramLibrary` — Pattern Memory
Mint engrams for known trading patterns. Match new observations against library.
Serializable experience that persists across runs.

#### 10. `StripedSubspace` — High-Complexity Attribution
When manager state has many fields, standard subspace saturates.
Striped distributes across independent subspaces by field name hash.

#### 11. `similarity_profile()` — Dimensional Agreement
Per-dimension agreement pattern. "These configs are similar in momentum
but different in regime."

#### 12. `negate(superposition, component)` — Geometric Exclusion
"What does this config look like WITHOUT momentum's contribution?"
Counterfactual reasoning within the enterprise.

### Lower Priority — Advanced
- `analogy(a, b, c)` — cross-asset pattern transfer
- `grover_amplify()` — extract weak signal from strong background
- `autocorrelate()` — periodicity in manager decisions
- `drift_rate()` — gradual drift vs sudden shifts
- `blend()` — interpolate between strategy prototypes
- `conditional_bind()` — context-dependent composition
- `power()` — fractional binding strength

---

## S-Expression Logging

Every manager thought logged as wat expression on disk. Human-readable.
Machine-parseable. The thought IS the log.

```
(thought candle=48372 timestamp="2019-06-15T14:30:00"
  (bind momentum BUY@0.182)              ; proven, gate open
  (bind (permute structure) SELL@0.094)   ; proven, gate open
  ;; volume: gate closed
  (bind narrative BUY@0.221)              ; proven, gate open
  ;; regime: gate closed
  ;; generalist: gate closed
  (bind panel-agreement 0.667)
  (bind panel-energy 0.166)
  (bind panel-divergence 0.052)
  (bind market-volatility 0.0024)
  (bind disc-strength 0.0013)
  → (manager-prediction BUY conviction=0.147))
```

---

## Sequence

1. Review Holon toolkit — understand each operation at the vector level
2. Add `difference` to manager — delta between consecutive expert configs
3. Add temporal encoding — hour/day/session as manager context
4. Add `coherence` — panel concentration as manager context
5. Run 100k — measure impact of richer vocabulary
6. Add `prototype` for winning/losing configs — pattern memory
7. Add `cross_correlate` — discover per-expert optimal horizon
8. Fix manager reward for hold mode (#17)
9. Fractional allocation (#18)
10. Per-position stop/TP (#19)
11. 652k validation — full dataset with enriched enterprise
12. S-expression logging — thoughts on disk

---

## Key Discoveries (session 2026-03-28 to 03-29)

- The enterprise self-organizes: gates breathe, experts cycle in/out by regime
- The flip emerges geometrically from signed convictions + raw direction labels
- Unsigned conviction = 49.5% (random). Signed = 54.8%. The sign IS the signal.
- "Don't average into one number" — repeat anti-pattern across all Holon work
- The generalist was redundant: same signal with or without it
- $10,000 preserved by refusing to trade without proof — most intelligent outcome
- The architecture IS the language: same 6 primitives at every level
- The gate is a derived pattern from curve + conditional, not a new primitive
- Different rewards at different levels: Buy/Sell, Win/Lose, Healthy/Unhealthy
- The trading enterprise and DDoS shield are the same architecture
- MTG is the next domain after trading is proven
