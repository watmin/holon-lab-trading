# Proposal 053 — Reckoner Drift

**Scope:** userland (touches holon-rs internals)

## The finding

The position observer's prediction error INCREASES over time:

```
              Trail Error    Stop Error
First 1000:   0.91 (91%)     0.89 (89%)
Last 1000:    7.22 (722%)    4.79 (479%)
```

The continuous reckoners accumulate experience (132K/143K) but
predictions diverge from optimal. The more they learn, the worse
they get.

## The mechanism

The position observer has a noise subspace (OnlineSubspace /
CCIPCA) that learns the background. It strips the background
from the thought vector, producing the ANOMALY — the part that
is unusual. The anomaly is what the reckoner sees.

The reckoner has 10 bucketed accumulators. Each bucket holds a
prototype (accumulated sum of thought vectors) and a center
(the scalar value this bucket represents). The query finds the
buckets whose prototypes best match the current thought (via
dot product) and interpolates their centers.

The problem: the noise subspace evolves. At candle 1000, the
subspace has absorbed 1000 candles of "normal." The anomaly
vector reflects what is unusual RELATIVE TO 1000 candles of
experience. At candle 10000, the subspace has absorbed 10000
candles. The definition of "normal" has shifted. The anomaly
for the same market state looks DIFFERENT at candle 10000 than
it did at candle 1000.

The reckoner's bucket prototypes were accumulated from anomalies
under old definitions of "normal." The current anomalies don't
match the old prototypes. The dot products between current
thoughts and old bucket prototypes DECREASE. The interpolation
becomes noisier. The predictions drift.

The reckoner decays old observations (0.999 per observation —
effective window ~1000 observations). But the decay only shrinks
the old prototypes. It doesn't realign them with the current
noise subspace's definition of "normal."

## The coupling

```
candle → thought → noise_subspace.strip() → anomaly → reckoner.query()
                         ↓
                   subspace EVOLVES
                   (absorbs more "normal")
                         ↓
                   old anomalies ≠ new anomalies
                         ↓
                   reckoner prototypes misaligned
                         ↓
                   predictions degrade
```

The noise subspace and the reckoner are coupled but evolve at
different rates. The subspace changes what "anomalous" means.
The reckoner's prototypes were learned under old definitions.
The definitions drift apart. The predictions degrade.

## The questions

1. **Is the noise subspace the cause?** Can we verify by running
   WITHOUT noise stripping and measuring whether the error still
   grows? If the error stabilizes without stripping, the subspace
   drift is confirmed.

2. **Should the reckoner see the raw thought instead of the
   anomaly?** The noise subspace was designed to strip "normal"
   so the reckoner only learns from "unusual" signals. But if
   the stripping itself causes drift, maybe the reckoner should
   see the full thought. The raw thought is stable — it doesn't
   depend on the subspace's evolving definition of normal.

3. **Can the reckoner realign?** The decay (0.999) kills old
   prototypes after ~1000 observations. But the prototypes are
   accumulated from anomalies whose definition has shifted. Even
   recent prototypes (last 1000 observations) were accumulated
   under a drifting subspace. Can the reckoner track the drift?

4. **Is this a fundamental tension between stripping and
   learning?** The noise subspace needs time to learn what's
   normal. The reckoner needs stable inputs to learn. The
   subspace's learning makes the reckoner's inputs unstable.
   Are these irreconcilable? Or is there a synchronization
   mechanism?

5. **Does the market observer have the same problem?** The
   market observer also has a noise subspace + reckoner. Does
   its accuracy degrade over time too? The market observer's
   accuracy is measured (recalib_wins/recalib_total). The
   position observer's wasn't until this session.

## For the designers

This may be architectural — a tension in the substrate, not
the application. The panel should consider whether this is
fixable at the application level or requires changes to
holon-rs.
