# Proof 003 — Thinker Significance

**Date:** opened 2026-04-25.
**Status:** **BLOCKED on lab arc 029** (RunDb service). Initial supporting program drafted but discarded — the arc 027 shim binds `run_name` at open, and proof 003 needs N run_names per database. Builder direction 2026-04-25: "we need a db service for this." Arc 029 refactors the shim to take `run_name` per-message and adds `:lab::rundb::Service` (Console-style fire-and-forget driver). Once arc 029 ships, proof 003 builds on top.
**Pair file (planned):** [`wat-tests-integ/proof/003-thinker-significance/003-thinker-significance.wat`](../../../../wat-tests-integ/proof/003-thinker-significance/003-thinker-significance.wat).
**Predecessor:** [Proof 002 — Thinker Baseline](../002-thinker-baseline/PROOF.md).
**Unblocking arc:** [`docs/arc/2026/04/029-rundb-service/`](../../../arc/2026/04/029-rundb-service/DESIGN.md).

Proof 002 showed that on a single 10k-candle window, sma-cross
loses **−0.2791** vs always-up's **−0.6498** — sma-cross looks
better. But one window is one regime. Is the gap real, or did
sma-cross just get lucky on the first month of 2019?

Proof 003 runs both thinkers on **10 windows** spread across the
full 6-year stream and asks: does sma-cross beat always-up
consistently, or does the gap collapse into noise?

> Every proof moves us a step forward. — the user.

---

## A — The window scheme

The stream is 652,608 candles. Ten 10k-windows, evenly strided:

| window | start | end (exclusive) | approx calendar |
|-------:|------:|----------------:|-----------------|
| w0 | 0 | 10,000 | Jan–Feb 2019 |
| w1 | 65,261 | 75,261 | Aug–Sep 2019 |
| w2 | 130,522 | 140,522 | Apr–May 2020 |
| w3 | 195,783 | 205,783 | Nov–Dec 2020 |
| w4 | 261,044 | 271,044 | Jul–Aug 2021 |
| w5 | 326,304 | 336,304 | Mar–Apr 2022 |
| w6 | 391,565 | 401,565 | Oct–Nov 2022 |
| w7 | 456,826 | 466,826 | Jun–Jul 2023 |
| w8 | 522,087 | 532,087 | Feb–Mar 2024 |
| w9 | 587,348 | 597,348 | Sep–Oct 2024 |

Stride = ⌊652,608 / 10⌋ = 65,261. Each window covers
~34.7 days of 5-min candles. Different regimes (the 2020 crash,
the 2021 bull run, the 2022 collapse, the 2024 rally) all show up.

**No infra change.** `:lab::candles::open-bounded path n` caps
total emissions from row 0. To reach window `w_i`:
1. Open with `n = start_i + 10_000`.
2. `next!` × `start_i` to discard.
3. Pass the partially-drained stream to `:trading::sim::run-loop`,
   which then sees exactly 10k candles before EOS.

Skip cost is parquet streaming-reads — negligible vs simulator
work.

---

## B — Schema reuse

The `paper_resolutions` table from arc 027 is reused unchanged.
Window identity rides in the `run_name` column:

- always-up DB writes 10 run_names: `always-up-w0-<iso>`, …, `always-up-w9-<iso>`.
- sma-cross DB writes 10 run_names: `sma-cross-w0-<iso>`, …, `sma-cross-w9-<iso>`.

Per-window slicing is then `GROUP BY run_name`. Sufficient —
proof 003 does not need a schema migration. (Arc 029 makes
`run_name` a per-message field on `log-paper`; that's the seam
proof 003 walks 10 different run_names through one connection.)

---

## C — Two deftests

```scheme
(:deftest :trading::test::proofs::003::always-up-multiwindow
  ;; Open one DB, run always-up across 10 windows, log every Outcome.
  ;; Assert: aggregate papers > 0; conservation holds across all 10.
  )

(:deftest :trading::test::proofs::003::sma-cross-multiwindow
  ;; Same shape, sma-cross thinker.
  )
```

Both tests use the same Config as proof 002:
`(:trading::sim::Config/new 288 0.01 35.0 14)` —
288-candle deadline, 1% peak/valley thresholds, 35-candle
lookback, 14-candle min life.

The supporting program shares one helper, `run-window-and-log`,
parameterized by `(stream-start, run-name, db, thinker, predictor)`
and reusing proof 002's `log-outcome` walker on the
`SimState/outcomes` vec.

---

## D — The metrics this proof measures

For each thinker:

| Metric | Source |
|--------|--------|
| Per-window: `papers, grace, violence, total_residue, total_loss, net_pnl` | `GROUP BY run_name` |
| Aggregate across 10 windows: same six | `WHERE thinker = ?` (no group) |
| Per-window: `grace_rate = grace / papers` | derived |
| Aggregate `grace_rate`, mean, stddev across windows | per-window stats |
| Direction × state | `GROUP BY direction, state` |

The headline comparison:

| Comparison | Question |
|-----------|----------|
| sma-cross net_pnl − always-up net_pnl, **per window** | How many of the 10 windows does sma-cross win on? |
| Aggregate sma-cross net_pnl − always-up net_pnl | Total dollar gap across all 100k candles |
| Difference of grace_rates, with z-test | Is the grace_rate gap > 2σ noise? |

A two-proportion z-test on aggregate counts:

```
z = (p1 - p2) / sqrt( p_pool * (1 - p_pool) * (1/n1 + 1/n2) )
```

where `p1, n1` are sma-cross grace/papers, `p2, n2` are
always-up. `|z| > 2` ≈ "different at p < 0.05". `|z| > 3` ≈
"different at p < 0.003".

Proof 003 reports `z` and the per-window win-count. No
hand-waving; the SQL is in the doc.

---

## E — What this proof will establish

1. **Whether sma-cross's edge over always-up generalizes.** If
   sma-cross's net_pnl beats always-up's in ≥ 7 of 10 windows
   AND the aggregate z > 2, the edge is regime-robust.
2. **Variance of the lifecycle response.** If grace_rate ranges
   from 0.05 to 0.30 across windows for sma-cross, the
   simulator is regime-sensitive — we'll need regime-aware
   thinkers eventually.
3. **The base rate of always-up under different regimes.** Does
   always-up grace-rate stay at 0.0 across all 10 windows
   (deadlines always hit)? Or does it occasionally produce
   Grace in strong-uptrend windows? This bounds what "Up
   conviction always" actually buys you.

---

## F — What this proof will NOT establish

- **That sma-cross is a profitable trader.** Net P&L is still
  expected to be negative in raw cosine-residue units — there's
  no learned predictor yet. The gap, not the sign, is what
  matters here.
- **6-year-stream behavior.** Still sampling. Proof 004 takes
  the full 652k contiguous.
- **Effect of the predictor.** Both thinkers use the same
  `cosine-vs-corners` predictor. Proof 005 will swap in a
  learning predictor.
- **Calendar effects.** Windows are stride-evenly-spaced, not
  regime-balanced. Bull / bear / chop counts may be uneven.

---

## G — How to reproduce (when shipped)

```bash
cd /home/watmin/work/holon/holon-lab-trading
cargo test --release --features proof-003 --test proof_003 -- --nocapture
```

Two SQLite databases land under `runs/`:
`proof-003-always-up-<epoch>.db` and `proof-003-sma-cross-<epoch>.db`.
Each holds 10 run_names, one per window.

Then the proof's anchoring queries:

```sql
-- per-window summary, sma-cross
SELECT run_name,
       COUNT(*)              AS papers,
       SUM(state='Grace')    AS grace,
       SUM(state='Violence') AS violence,
       ROUND(SUM(residue), 4) - ROUND(SUM(loss), 4) AS net_pnl
FROM paper_resolutions
GROUP BY run_name
ORDER BY run_name;

-- aggregate, both DBs
SELECT 'sma-cross' AS thinker, COUNT(*) AS papers,
       SUM(state='Grace') AS grace, SUM(state='Violence') AS violence,
       ROUND(SUM(residue) - SUM(loss), 4) AS net_pnl
FROM paper_resolutions
UNION ALL
SELECT 'always-up', ...;  -- against the other DB
```

The proof doc post-execution embeds these tables.

---

## H — Closing

Proof 002 said "the lifecycle responds to vocabulary." Proof 003
asks "does it respond *consistently* across regimes?" The answer
either justifies the always-up vs sma-cross hierarchy or
collapses it into noise.

Either answer is a foothold for proof 005.

PERSEVERARE.
