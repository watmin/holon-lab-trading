# Proposal 043 — Broker Survival

**Scope:** userland

**Depends on:** Proposals 036 (journey learning), 037 (journey threshold),
040 (exit vocabulary), 042 (market lenses)

## The current state

22 brokers. 11 market observers × 2 exit observers. Each broker
registers papers, ticks them against price, resolves them, and
teaches both its market observer and exit observer through learn
channels. The broker has an expected value (EV) computed from
grace and violence outcomes. The broker has a gate — `gate_open()`
— that controls whether new papers are registered.

The journey grading (036/037) uses an EMA (alpha=0.01, seed=0.5)
over error ratios. Each batch training observation is labeled
Grace or Violence based on whether its error is below or above
the EMA threshold.

## The problem

At 10,000 candles, 18 of 22 brokers are dead. Zero papers. Zero
learning. Negative EV. Gates permanently closed.

```
Alive (positive EV, active papers):
  slot  3: dow-volume     × full   EV=+48.17  papers=212
  slot  7: dow-generalist × full   EV=+37.62  papers=226
  slot 11: pring-confirm  × full   EV=+42.33  papers=203
  slot 19: wyckoff-persist × full   EV=+33.56  papers=175

Dead (negative EV, zero papers, gate closed):
  ALL 11 core-exit pairings — dead by candle 1500
  7 of 11 full-exit pairings — dead by candle 2000
```

The cascade:

1. Broker EV goes negative → gate closes → no new papers
2. No new papers → no resolutions → no learning signals
3. No learning signals → exit observer starves
4. Exit-core received ZERO new experience after candle 1500
5. Exit-full receives observations but heavily Violence-skewed
   (the 4 survivors produce 24k grace vs 31k violence)
6. Journey EMA under high volume converges below every new
   observation → everything labeled Violence → grace_rate
   collapses to 0.0

The market observers paired with dead brokers also starve.
wyckoff-position has the best accuracy (59.8%) but BOTH its
brokers are dead. The observer that sees best has no voice.

## The measurements

### Exit observer starvation

```
Window       Core new exp    Full new exp    Core grace_rate   Full grace_rate
0-500        12,479          11,706          0.35              0.43
500-1000      9,307           8,434          0.70              0.66
1000-1500     3,700           5,172          0.77              0.40
1500-2000         0           3,813          0.93 (frozen)     0.32
2000-5000         0          27,959          0.93 (frozen)     0.20
5000-10000        0          42,662          0.93 (frozen)     0.12
```

Core exit died because ALL its brokers died. Full exit survived
because 4 of its brokers survived — but the surviving brokers
feed heavily Violence-skewed journey batches.

### Market observer starvation

Two populations emerged:
- **Frozen** (experience ~2000, 3-4 recalibs): dow-trend, dow-cycle,
  pring-regime, wyckoff-effort, wyckoff-position. ALL their
  brokers are dead. Best accuracy: wyckoff-position at 59.8%.
- **Growing** (experience ~14000, 28 recalibs): dow-volume,
  pring-confirmation, wyckoff-persistence, dow-generalist.
  These are the 4 whose full-exit broker survived.

The growing observers are NOT the best observers. They survived
because their full-exit broker happened to achieve positive EV.
wyckoff-persistence has 0.0% accuracy but 14,011 experience.
wyckoff-position has 59.8% accuracy but 1,876 experience and
is permanently frozen.

### Journey EMA collapse (exit-full)

The EMA (alpha=0.01, seed=0.5) receives ~103,000 observations
over 10k candles. The 4 surviving brokers each send large batch
histories — hundreds of observations per runner closure. The
volume overwhelms the EMA. It converges to a value where nearly
every new observation exceeds the threshold → labeled Violence →
grace_rate drops to 0.0.

## The three problems

### Problem 1: The gate kills learners

The broker gate closes when EV is negative. Once closed, papers
stop. Resolutions stop. Learning stops. The broker cannot recover
because it cannot learn. The gate is a death sentence, not a
pause.

A trader in drawdown doesn't stop trading — they reduce size.
A learner with negative EV doesn't stop learning — they learn
from the negative EV. The gate conflates "unproven" with "dead."

### Problem 2: The survivors aren't the best

The 4 surviving brokers are not paired with the best market
observers. They survived because of exit-side dynamics, not
market-side accuracy. The selection pressure selects for
lucky exit pairings, not good market observers. The best
market observer (wyckoff-position, 59.8%) is silenced.

### Problem 3: The journey EMA collapses under volume

The EMA with alpha=0.01 converges to a stable value under
moderate observation volume. Under high volume (103k
observations from 4 prolific brokers), it converges too low.
Every observation exceeds the threshold. Everything is Violence.
The exit observer's grace_rate collapses to 0.0 and never
recovers.

## Questions for designers

1. **Should the broker gate ever permanently close?** Or should
   a broker always register papers — even with negative EV —
   to keep the learning loop alive? If always open, what
   prevents capital waste? If gated, what reopens a closed gate?

2. **Should papers be decoupled from the gate?** Papers are
   free — they don't cost capital. Only funded trades cost
   capital. If the broker registers papers regardless of EV
   but only PROPOSES funded trades when proven, the learning
   loop stays alive while capital is protected.

3. **The journey EMA alpha (0.01) — should it adapt?** A fixed
   alpha converges differently under 1,000 vs 100,000 observations.
   Should the alpha scale with observation count? Should the
   EMA be replaced with a different threshold mechanism?

4. **Should each broker have its OWN journey EMA?** Currently
   all 22 brokers feed the same 2 exit observers. The 4
   surviving brokers dominate the exit's training distribution.
   Should the journey grading be per-broker to prevent volume
   imbalance?

5. **The starvation cascade — is this a gate problem or a
   wiring problem?** The market observer learns only when
   its broker sends learn signals. If the broker dies, the
   market observer is silenced regardless of its accuracy.
   Should market observers have an independent learning path
   that doesn't depend on broker survival?
