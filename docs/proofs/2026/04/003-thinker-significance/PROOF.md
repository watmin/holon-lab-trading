# Proof 003 — Thinker Significance

**Date:** opened 2026-04-25.
**Status:** **ready** (lab arc 029 closed 2026-04-25 — RunDb service shipped). Per-call `run_name` lives on `:lab::rundb::log-paper-resolved` (the slice-1 shim refactor); the slice-2 `:lab::rundb::Service` provides CacheService-style batched send+ack so multiple window-runners can fan in to one connection under distinct run_names. Pair file forthcoming.
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

## B — Schema reuse, one DB

The `paper_resolutions` table from arc 027 is reused unchanged.
**Per arc 029 Q8 (one DB per run, many tables/columns inside),
proof 003 writes a single file** at `runs/proof-003-<epoch>.db`.
Inside, 20 sub-runs (2 thinkers × 10 windows) ride two
distinguishing columns:

- `thinker` column — `"always-up"` vs `"sma-cross"`.
- `run_name` column — `"<thinker>-w<i>-<iso>"` (e.g.,
  `"always-up-w0-2026-04-25T...Z"`, ..., `"sma-cross-w9-..."`).

Cross-thinker queries: `GROUP BY thinker`.
Cross-window queries: `GROUP BY run_name`.
Both: `GROUP BY thinker, run_name`.

No `ATTACH DATABASE` dance, no two-file split. Arc 029 makes
`run_name` a per-message field on `log-paper`; the
`:lab::rundb::Service` driver fans in 20 different run_names
through one connection.

---

## C — One deftest, one DB, twenty sub-runs

Per arc 029:
- **Q8** — one deftest per proof, one DB per run, all variants distinguished by columns.
- **Q9** — communication unit is `:lab::log::LogEntry::PaperResolved`.
- **Q10** — confirmed batch with ack; one primitive (`Service/batch-log`).

```scheme
(:deftest :trading::test::proofs::003::thinker-significance
  (:wat::core::let*
    (((path :String) "data/btc_5m_raw.parquet")
     ((cfg :trading::sim::Config) (:trading::sim::Config/new 288 0.01 35.0 14))
     ((now :wat::time::Instant) (:wat::time::now))
     ((epoch-str :String) (:wat::core::i64::to-string
                            (:wat::time::epoch-seconds now)))
     ((iso-str :String) (:wat::time::to-iso8601 now 3))
     ((db-path :String)
      (:wat::core::string::concat "runs/proof-003-" epoch-str ".db"))
     ;; Spawn :lab::rundb::Service with N=1 client (single-thread
     ;; deftest; future multi-thread version pops N>1 handles).
     ((tup ...) (:lab::rundb::Service db-path 1))
     ((pool ...) (:wat::core::first tup))
     ((driver ...) (:wat::core::second tup))
     ((req-tx ...) (:wat::kernel::HandlePool::pop pool))
     ((_ :()) (:wat::kernel::HandlePool::finish pool))
     ;; Client owns one ack channel reused across every batch.
     ((ack-pair ...) (:wat::kernel::make-bounded-queue :() 1))
     ((ack-tx ...) (:wat::core::first ack-pair))
     ((ack-rx ...) (:wat::core::second ack-pair))
     ;; Walk thinkers, walk windows. Each window resolves into a
     ;; Vec<LogEntry::PaperResolved>, batch-log'd with one ack.
     ;; Natural batch boundary = one window (per the message at
     ;; the top of arc 029 Q10: "all outcomes of one window").
     ((_run :())
      (:wat::core::foldl
        (:wat::core::vec :(String, :trading::sim::Thinker)
          (:wat::core::tuple "always-up" (:trading::sim::always-up-thinker))
          (:wat::core::tuple "sma-cross" (:trading::sim::sma-cross-thinker)))
        ()
        (:wat::core::lambda
          ((acc :()) (pair :(String, :trading::sim::Thinker)) -> :())
          (:trading::test::proofs::003::run-thinker-windows
            req-tx ack-tx ack-rx path cfg pair iso-str))))
     ((_ :()) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))
```

Same Config as proof 002:
`(:trading::sim::Config/new 288 0.01 35.0 14)` —
288-candle deadline, 1% peak/valley thresholds, 35-candle
lookback, 14-candle min life.

The supporting program ships two helpers:
- `run-thinker-windows req-tx ack-tx ack-rx path cfg (thinker-name, thinker) iso-str`
  — foldl over the 10 window starts; for each, calls
  `run-window-and-log`.
- `run-window-and-log req-tx ack-tx ack-rx path start n cfg thinker predictor thinker-name run-name`
  — opens the bounded stream, skips to `start`, runs
  `:trading::sim::run-loop`, **maps** `SimState/outcomes` to a
  `Vec<:lab::log::LogEntry>` of `PaperResolved` variants
  (one per Outcome), then calls
  `(:lab::rundb::Service/batch-log req-tx ack-tx ack-rx entries)`
  once per window — one ack per window batch, ~30-40 entries
  per batch.

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

ONE SQLite database lands under `runs/`: `proof-003-<epoch>.db`.
Inside, 20 sub-runs (2 thinkers × 10 windows) ride two
distinguishing columns (`thinker`, `run_name`).

The proof's anchoring queries:

```sql
-- per-thinker aggregate (one query, no ATTACH needed)
SELECT thinker,
       COUNT(*)                                    AS papers,
       SUM(state='Grace')                           AS grace,
       SUM(state='Violence')                        AS violence,
       ROUND(SUM(state='Grace')*1.0/COUNT(*), 4)    AS grace_rate,
       ROUND(SUM(residue), 4)                       AS total_residue,
       ROUND(SUM(loss), 4)                          AS total_loss,
       ROUND(SUM(residue) - SUM(loss), 4)           AS net_pnl
FROM paper_resolutions
GROUP BY thinker
ORDER BY thinker;

-- per-window per-thinker breakdown
SELECT thinker, run_name,
       COUNT(*)              AS papers,
       SUM(state='Grace')    AS grace,
       SUM(state='Violence') AS violence,
       ROUND(SUM(residue) - SUM(loss), 4) AS net_pnl
FROM paper_resolutions
GROUP BY thinker, run_name
ORDER BY thinker, run_name;

-- per-window winner: did sma-cross beat always-up on this window?
SELECT
  s.run_name AS window_id,
  ROUND(s.net_pnl - a.net_pnl, 4) AS sx_minus_au
FROM
  (SELECT SUBSTR(run_name, INSTR(run_name, '-w')) AS w,
          run_name,
          SUM(residue) - SUM(loss) AS net_pnl
   FROM paper_resolutions WHERE thinker='sma-cross'
   GROUP BY run_name) s
JOIN
  (SELECT SUBSTR(run_name, INSTR(run_name, '-w')) AS w,
          SUM(residue) - SUM(loss) AS net_pnl
   FROM paper_resolutions WHERE thinker='always-up'
   GROUP BY run_name) a
ON s.w = a.w
ORDER BY window_id;
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
