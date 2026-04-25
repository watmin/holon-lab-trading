# Proof 002 — Thinker Baseline

**Date:** opened 2026-04-25.
**Status:** **ready** (lab arc 027 closed 2026-04-25 — RunDb shim shipped).
**Pair file:** `wat-tests-proof-002/002-thinker-baseline.wat` (to land — write the supporting program against `:lab::rundb::*`).
**Predecessor:** [Proof 001 — The Machine Runs](../001-the-machine-runs/PROOF.md).

What numbers does the v1 simulator actually produce when you run
it? Proof 001 established existence — papers > 0, conservation
holds, finite outputs. Proof 002 measures those numbers and lets
us compare the two v1 thinkers.

> Every proof moves us a step forward. — the user, opening
> proof 001.

This proof's claim is small but load-bearing: **the always-up and
sma-cross thinkers, run on the same 10k-candle window, produce
measurable Grace/Violence distributions**, and the difference
between them tells us whether the simulator's lifecycle is
sensitive to thinker behavior at all.

---

## A — The unblocking arc

This proof requires SQLite-logging from the simulator's resolution
path. The infra ask lives at
[`docs/arc/2026/04/027-rundb-shim/DESIGN.md`](../../../arc/2026/04/027-rundb-shim/DESIGN.md).

The shim's surface — `:lab::rundb::open` and
`:lab::rundb::log-paper` — landed at
[`wat/io/RunDb.wat`](../../../../wat/io/RunDb.wat). One divergence
from the original DESIGN sketch: `close` was dropped (Drop on the
thread-owned cell handles file-handle release; rusqlite
auto-commits on every statement, so there's nothing to flush).
The supporting program below uses `let*` binding scope as the
implicit close point.

---

## B — What the proof will measure

Two runs, identical config, different thinker. Each writes one
row per resolved Outcome to `runs/proof-002-<thinker>.db`.

| Metric | Source |
|--------|--------|
| `papers` (count of resolutions) | `SELECT COUNT(*) FROM paper_resolutions WHERE run_name = ?` |
| `grace-count`, `violence-count` | `GROUP BY state` |
| `grace-rate` | `grace / papers` |
| `total-residue`, `total-loss` | `SUM(residue)`, `SUM(loss)` |
| `mean-residue` (Grace papers) | `AVG(residue) WHERE state='Grace'` |
| `max-residue`, `min-residue` | `MAX/MIN(residue)` |
| `mean-paper-duration` | `AVG(resolved_at - opened_at)` |

Results land in two SQLite databases:
- `runs/proof-002-always-up.db`
- `runs/proof-002-sma-cross.db`

The proof doc embeds the SQL queries and their results as the
established facts. No grepping logs; the tables are queried
directly.

---

## C — The supporting program (sketched)

Will live at `wat-tests-proof-002/002-thinker-baseline.wat`,
behind a `proof-002` Cargo feature gate (same pattern as proof
001's `proof-001` feature). Two deftests, one per thinker:

```scheme
;; Default-prelude — no load needed (shim auto-registers)
(:wat::test::make-deftest :deftest ())

(:deftest :trading::test::proofs::002::always-up-10k
  (:wat::core::let*
    (((stream :lab::candles::Stream)
      (:lab::candles::open-bounded "data/btc_5m_raw.parquet" 10000))
     ((db :lab::rundb::RunDb)
      (:lab::rundb::open "runs/proof-002-always-up.db"
                          "proof-002-always-up-10k"))
     ((cfg :trading::sim::Config)
      (:trading::sim::Config/new 288 0.01 35.0 14))
     ;; A run-with-logging variant of :trading::sim::run that
     ;; calls (:lab::rundb::log-paper db ...) on every Outcome.
     ;; (Maybe ships as a wat-side wrapper, or as an Aggregate-
     ;;  level callback the simulator surfaces.)
     ((agg :trading::sim::Aggregate)
      (:trading::sim::run-and-log
        stream
        (:trading::sim::always-up-thinker)
        (:trading::sim::cosine-vs-corners-predictor)
        cfg
        db))
     ((_ :()) (:lab::rundb::close db)))
    ;; Same conservation invariant as proof 001.
    (:wat::test::assert-eq
      (:wat::core::= (:trading::sim::Aggregate/papers agg)
                     (:wat::core::+ (:trading::sim::Aggregate/grace-count agg)
                                    (:trading::sim::Aggregate/violence-count agg)))
      true)))

;; Symmetric deftest for sma-cross-thinker → runs/proof-002-sma-cross.db
```

The `:trading::sim::run-and-log` wrapper is the seam this proof
needs. Two ways to ship it:

- **Option A — wat wrapper.** A `run-and-log` function in
  `wat/sim/paper.wat` (or a sibling) that wraps `:trading::sim::run`
  and walks the resulting `:Vec<Outcome>` to log each. Requires
  the simulator to expose Outcomes (currently only Aggregate is
  returned — a shape change).
- **Option B — callback parameter.** The simulator's `run`
  signature gains an optional `on-resolution` callback. Each
  Outcome fires the callback before being folded into the
  Aggregate. The callback closure captures the RunDb handle.

Option A keeps `:trading::sim::run`'s signature stable but
requires shape-changing the return type. Option B changes the
signature but keeps the data flow forward-only. Decide at
implementation time; arc 027 doesn't need to pick.

---

## D — What this proof will establish

When the run lands and the SQL queries return:

1. **Concrete aggregate numbers** for both v1 thinkers on a
   real 10k-candle window. No more "papers > 0; details
   unknown."
2. **Whether always-up vs sma-cross differ measurably.** If
   sma-cross's grace-rate ≠ always-up's grace-rate by more than
   noise, the simulator's lifecycle is sensitive to thinker
   behavior — the prerequisite for any future "thinker A beats
   thinker B" claim.
3. **The Grace/Violence residue distribution shape.** Mean,
   min, max per state. Proof 001 established residue is finite;
   proof 002 names what range it actually occupies.
4. **Paper duration distribution.** Are most papers resolving
   at deadline (Violence by timeout) or earlier (Grace at
   Peak/Valley)? The mean of `(resolved_at - opened_at)` tells
   us.

---

## E — What this proof will NOT establish

- **That sma-cross's signal is REAL** (vs. statistical noise on
  a single 10k window). A multi-window run + significance test
  is a future proof.
- **6-year-stream behavior.** Proof 002 stays at 10k for fast
  iteration; proof 004 takes the full stream.
- **Effect of any optimization.** Cache, concurrency, learned
  Predictors — all still unwired. This proof measures the same
  unoptimized baseline as proof 001.
- **Win-rate intuition matching trader experience.** The numbers
  ARE the numbers; whether they reflect "good trading" is a
  separate evaluative question.

---

## F — How to reproduce (when unblocked)

Once arc 027 closes:

```bash
cargo test --release --features proof-002 --test proof_002

# After the run:
sqlite3 runs/proof-002-always-up.db <<EOF
SELECT
  COUNT(*) AS papers,
  SUM(state='Grace') AS grace,
  SUM(state='Violence') AS violence,
  ROUND(SUM(state='Grace') * 1.0 / COUNT(*), 4) AS grace_rate,
  ROUND(SUM(residue), 4) AS total_residue,
  ROUND(SUM(loss), 4) AS total_loss
FROM paper_resolutions;
EOF

# And the symmetric query against runs/proof-002-sma-cross.db
```

The proof doc post-execution embeds the actual table outputs as
the established facts.

---

## G — The next proofs queued behind this one

- **Proof 003** — `sma-cross vs always-up` significance: do they
  differ across 10 windows of 10k? Or is the difference within
  noise? Adds a multi-window runner.
- **Proof 004** — Full 6-year stream. Same metrics over 652k
  candles. Probably runs in ~33 minutes. The aggregate's
  long-horizon shape (drawdown, deepest residue, max-paper-life).
- **Proof 005** — A richer thinker that uses 5+ indicators
  (RSI, MACD-hist, ADX, kama-er, choppiness) projected into the
  outcome × direction basis. First step toward reproducing
  Chapter 1's 59% directional accuracy.

Each proof is its own dir + own feature + own supporting
program. The pattern from proof 001 holds.

---

## Closing

Proof 001 said "the machine runs." Proof 002 will say "here's
what the machine produces." That's enough for one proof.

When arc 027 closes, this stub becomes a real proof.

PERSEVERARE.
