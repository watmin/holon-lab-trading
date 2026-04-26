# Proof 002 — Thinker Baseline

**Date:** opened 2026-04-25, shipped 2026-04-25.
**Status:** **SHIPPED.** Both deftests pass; SQLite databases populated; SQL queries below capture the established facts.
**Pair file:** [`wat-tests-integ/proof/002-thinker-baseline/002-thinker-baseline.wat`](../../../../wat-tests-integ/proof/002-thinker-baseline/002-thinker-baseline.wat).
**Predecessor:** [Proof 001 — The Machine Runs](../001-the-machine-runs/PROOF.md).

What numbers does the v1 simulator actually produce when you run
it? Proof 001 established existence — papers > 0, conservation
holds, finite outputs. Proof 002 measures those numbers and
compares the two v1 thinkers.

> Every proof moves us a step forward. — the user, opening
> proof 001.

This proof's claim was small but load-bearing: **the always-up and
sma-cross thinkers, run on the same 10k-candle window, produce
measurable Grace/Violence distributions**, and the difference
between them tells us whether the simulator's lifecycle is
sensitive to thinker behavior at all.

It is. Below are the numbers.

---

## A — The unblocking arcs

Two arcs paved the way:

- [`docs/arc/2026/04/027-rundb-shim/`](../../../arc/2026/04/027-rundb-shim/DESIGN.md) shipped `:lab::rundb::open` / `:lab::rundb::log-paper` — the SQLite-logging seam. `close` was dropped (Drop on the thread-owned cell handles file-handle release; rusqlite auto-commits per statement).
- [`wat-rs` arc 056](../../../../../wat-rs/docs/arc/2026/04/056-time-instant/BACKLOG.md) shipped `:wat::time::*` primitives — `(:wat::time::now)`, `epoch-seconds`, `to-iso8601`. The pair file uses these to mint unique-per-execution DB filenames so re-runs accumulate (`runs/proof-002-<thinker>-<epoch>.db`) rather than PK-violate.

The seam exposed by the simulator: per-paper Outcomes weren't on `:trading::sim::run`'s return type — only the rolled-up Aggregate. The pair file drops to `:trading::sim::run-loop` + `SimState/outcomes` (both already public) and walks the resulting `:Outcomes` vec via `foldl` for the side effect of logging. No simulator-side change required.

---

## B — How the proof was reproduced

```bash
cd /home/watmin/work/holon/holon-lab-trading
cargo test --release --features proof-002 --test proof_002 -- --nocapture
```

Both deftests passed in ~30s each on a 10k-candle BTC window
(`data/btc_5m_raw.parquet`). Each test wrote one row per resolved
Outcome to a fresh timestamped database under `runs/`.

Schema (per arc 027):

```sql
CREATE TABLE paper_resolutions (
  run_name     TEXT NOT NULL,
  thinker      TEXT NOT NULL,
  predictor    TEXT NOT NULL,
  paper_id     INTEGER NOT NULL,
  direction    TEXT NOT NULL,
  opened_at    INTEGER NOT NULL,
  resolved_at  INTEGER NOT NULL,
  state        TEXT NOT NULL,    -- 'Grace' | 'Violence'
  residue      REAL NOT NULL,    -- positive for Grace, 0 for Violence
  loss         REAL NOT NULL,    -- 0 for Grace, abs(final-residue) for Violence
  PRIMARY KEY (run_name, paper_id)
);
```

---

## C — What the numbers say

### Always-up thinker (`runs/proof-002-always-up-1777160871.db`)

```sql
SELECT COUNT(*)                                   AS papers,
       SUM(state='Grace')                          AS grace,
       SUM(state='Violence')                       AS violence,
       ROUND(SUM(state='Grace')*1.0/COUNT(*), 4)   AS grace_rate,
       ROUND(SUM(residue), 4)                      AS total_residue,
       ROUND(SUM(loss), 4)                         AS total_loss,
       ROUND(AVG(resolved_at - opened_at), 2)      AS mean_paper_duration_candles
FROM paper_resolutions;
```

| papers | grace | violence | grace_rate | total_residue | total_loss | mean_duration |
|-------:|------:|---------:|-----------:|--------------:|-----------:|--------------:|
| 34     | 0     | 34       | 0.0000     | 0.0           | 0.6498     | 288.00        |

Direction breakdown: **34 Up / 0 Down** (always-up only proposes Up — by construction).

### SMA-cross thinker (`runs/proof-002-sma-cross-1777160902.db`)

| papers | grace | violence | grace_rate | total_residue | total_loss | mean_duration |
|-------:|------:|---------:|-----------:|--------------:|-----------:|--------------:|
| 34     | 5     | 29       | 0.1471     | 0.1561        | 0.4352     | 280.12        |

Direction × state breakdown:

| direction | state    | count |
|-----------|----------|------:|
| Up        | Grace    | 3     |
| Up        | Violence | 15    |
| Down      | Grace    | 2     |
| Down      | Violence | 14    |

Grace residue stats (sma-cross): mean 0.0312, max 0.0471.

---

## D — What this proof established

1. **Concrete aggregate numbers** for both v1 thinkers on the
   same 10k-candle BTC window. Both produced 34 papers each
   (same Config: 288-candle deadline = 24h, 1% peak/valley
   thresholds, 35 lookback, 14 min-life).
2. **The simulator's lifecycle is sensitive to thinker
   behavior.** Always-up: 0% grace-rate, 100% papers deadline
   out at exactly 288 candles. SMA-cross: 14.71% grace-rate,
   mean duration 280.12 (some early Grace exits at peak/valley).
   This is the prerequisite for any future "thinker A beats
   thinker B" claim.
3. **Direction diversity matters.** Always-up only opens Up
   papers (by construction). SMA-cross opens both: 18 Up + 16
   Down. The Down side has Grace too — the lifecycle is
   symmetric.
4. **Net P&L per thinker.** Always-up: residue − loss = 0 −
   0.6498 = **−0.6498**. SMA-cross: 0.1561 − 0.4352 =
   **−0.2791**. Both lose on raw cosine residue with no
   predictor learning, but sma-cross loses less than half of
   what always-up does — direction selection plus early Grace
   exits both contribute.
5. **Conservation invariant holds** on real data: papers ==
   grace + violence (34 == 0 + 34, 34 == 5 + 29). No "Active"
   leaks at outcome time.

---

## E — What this proof did NOT establish

- **That sma-cross's edge is real.** A single 10k window with
  34 papers per thinker is not statistical significance. Proof
  003 will run multi-window with a difference-of-proportions
  test.
- **6-year-stream behavior.** Stayed at 10k for fast iteration.
  Proof 004 takes the full 652k.
- **Effect of any optimization.** Cache, concurrency, learned
  Predictors all unwired. Same unoptimized baseline as proof
  001.
- **Win-rate intuition matching trader experience.** The
  numbers ARE the numbers; whether they reflect "good trading"
  is a separate evaluative question.

---

## F — How to reproduce

```bash
cd /home/watmin/work/holon/holon-lab-trading
cargo test --release --features proof-002 --test proof_002 -- --nocapture

# Then query the freshest DB per thinker:
ls -t runs/proof-002-always-up-*.db | head -1 | xargs -I{} sqlite3 {} <<EOF
SELECT COUNT(*) papers,
       SUM(state='Grace') grace,
       SUM(state='Violence') violence,
       ROUND(SUM(residue), 4) total_residue,
       ROUND(SUM(loss), 4)    total_loss
FROM paper_resolutions;
EOF
```

Re-runs accumulate; never delete `runs/proof-002-*.db` (per
`feedback_never_delete_runs`).

---

## G — The next proofs queued behind this one

- **Proof 003** — `sma-cross vs always-up` significance: do
  they differ across 10 windows of 10k? Or is the difference
  within noise? Adds a multi-window runner.
- **Proof 004** — Full 6-year stream. Same metrics over 652k
  candles. Long-horizon shape (drawdown, deepest residue,
  max-paper-life).
- **Proof 005** — A richer thinker that uses 5+ indicators
  (RSI, MACD-hist, ADX, kama-er, choppiness) projected into
  the outcome × direction basis. First step toward reproducing
  Chapter 1's 59% directional accuracy.

Each proof is its own dir + own feature + own supporting
program. The pattern from proof 001 holds.

---

## Closing

Proof 001 said "the machine runs." Proof 002 says "here's what
the machine produces — and the two v1 thinkers produce
measurably different numbers."

Always-up: −0.6498. SMA-cross: −0.2791. The lifecycle responds
to vocabulary. That's the foothold every later proof needs.

PERSEVERARE.

---

## Addendum (2026-04-25, mid-arc-029)

The shipped pair file split results across two DB files
(`runs/proof-002-always-up-<epoch>.db` +
`runs/proof-002-sma-cross-<epoch>.db`). User correction
mid-arc-029: **one DB per run, with as many tables/columns
inside as we need.** The schema's `thinker` column was always
there; the file-split simply ignored it.

Arc 029 slice 1 collapses proof 002 to one deftest writing
one DB at `runs/proof-002-<epoch>.db`. The originally-shipped
per-thinker DBs stay on disk as historical artifacts (per
`feedback_never_delete_runs`). The numbers above are
unchanged — they are the numbers the simulator produces; the
storage shape is orthogonal.
