# Debate: Proposal 043 — Broker Survival

Three voices reviewed. Three CONDITIONAL verdicts. Unanimous on
papers-never-stop. Divergent on mechanism.

## The tensions

### Tension 1: Gate mechanism

- **Seykota:** Remove the lock. Papers always register. Gate controls
  funded proposals only. No new states, no new parameters. Maximum
  simplicity. "You are removing the lock from the practice court."

- **Van Tharp:** Three-state gate: Proving → Active → Suspended.
  Suspended means zero capital, continued observation, path back to
  Active after 50-trade re-evaluation window. Minimum 200 trades
  before EV-gating activates. 500 before declaring dead.

- **Wyckoff:** Valve, not switch. Negative EV throttles paper
  registration proportionally. Deep negative = fewer papers.
  Slightly negative = nearly full rate. Never zero.

The question: do papers register at FULL rate always (Seykota),
at REDUCED rate when negative (Wyckoff), or at full rate but with
a state machine governing capital (Van Tharp)?

### Tension 2: Journey grading mechanism

- **Seykota:** Per-broker EMA. The struct already has the fields.
  Use them. Simple.

- **Van Tharp:** Replace EMA entirely with rolling percentile
  (keep last N=200 error ratios, threshold at 50th percentile).
  Bounded window. Cannot collapse under volume.

- **Wyckoff:** Fix the volume imbalance first — per-broker grading.
  If volume is balanced, the EMA may work fine. Don't replace the
  mechanism until you've fixed the distribution.

The question: keep the EMA but make it per-broker (Seykota/Wyckoff),
or replace with rolling percentile (Van Tharp)?

### Tension 3: Market observer independence

- **Seykota:** Market observer should learn from directional accuracy,
  not trade profitability. Different signal, different learning path.
  This is a deeper change but fixes the root wiring problem.

- **Van Tharp:** Solved naturally if papers never stop. Not urgent as
  a separate change. Worth considering later.

- **Wyckoff:** Market observer learning must decouple from broker EV.
  Every paper resolution teaches the market observer regardless of
  broker survival. Independent learning path.

The question: is decoupling market observer learning a required change
(Seykota/Wyckoff) or a natural consequence of papers-never-stop that
doesn't need explicit wiring (Van Tharp)?

## For the debaters

You have read each other's reviews. Respond to the specific tensions.
Where do you concede? Where do you hold? Where does the other voice
change your position? Arrive at a concrete recommendation the builder
can implement.
