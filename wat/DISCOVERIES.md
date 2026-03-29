# Wat Discoveries

Ideas, findings, and improvements encountered while backfilling the wat specifications.
Append-only. Each entry dated. The act of writing specifications reveals gaps.

---

## 2026-03-29: Writing manager.wat

1. **The manager's temporal encoding was wrong.** Used `encode_log(hour)` — a scalar
   where hour 3 and 4 are "close." Should be named atoms: `(bind hour-of-day h20)`.
   Fixed in code. The act of writing the wat spec caught the bug.

2. **The manager's `day-of-week` atom actually binds to session, not day.** We encode
   `(bind day-of-week asian-session)` not `(bind day-of-week monday)`. The session is
   more market-relevant than the calendar day. But the atom name is misleading. Should
   we rename to `trading-session`? Or keep both?

3. **The `motion` fact bundles delta with the snapshot.** The final thought is
   `bundle(snapshot, delta)`. Is this the right composition? The delta is a different
   KIND of information than the snapshot — it's about change, not state. Should it be
   bound with a role atom instead of just bundled? e.g. `(bind change-atom delta)`
   rather than raw bundle? Currently the delta IS bound with `panel-delta` atom so
   this is already correct.

4. **Panel coherence uses expert THOUGHT vectors, not convictions.** The cosine between
   two expert thought vectors measures how similar their VIEWS of the market are, not
   how similar their opinions are. Two experts could see the market differently
   (low coherence) but agree on direction (high agreement). These are distinct signals.
   Both are in the manager's vocabulary. Good.

5. **Missing: the manager doesn't know HOW proven each expert is.** The gate is binary
   (proven/not). But an expert at 55% accuracy is more reliable than one at 52.1%.
   Should the manager encode a `reliability` scalar per proven expert? This would let
   the discriminant weight experts by quality, not just presence.

6. **Missing: the manager doesn't know how LONG each expert has been proven.** An expert
   that just opened its gate (100 resolved predictions) is less trustworthy than one
   that's been open for 5000. Tenure as a fact?

## 2026-03-29: Writing expert specs

7. **eval_advanced is shared across 3 experts.** Momentum, structure, AND regime all
   see DFA alpha, entropy rate, fractal dimension, etc. The manager sees these regime
   indicators through 3 different experts' signed convictions. Should regime OWN these
   exclusively? Momentum and structure have their own primary vocabularies. Giving
   regime exclusive ownership of abstract indicators would make the experts more
   distinct and reduce redundant signal to the manager.

8. **Volume is the thinnest expert.** Only 3 eval methods. Appeared proven once in 100k
   (at 50k candle mark). Questions: is it inherently less predictive, or is the
   vocabulary too thin? Should we add: OBV divergence, VWAP, money flow, buying/selling
   volume? Should price action (inside bar, gaps) move to structure?

9. **Narrative duplicates the manager's temporal encoding.** The narrative expert
   encodes calendar as part of its thought (bundled with segments). The manager also
   encodes calendar as separate context atoms. The manager gets time signal twice:
   once from narrative's conviction (which incorporates calendar) and once from its
   own temporal atoms. Redundancy vs reinforcement — need to test.

10. **Structure is the most window-sensitive expert.** PELT, range position, fibonacci
    all change meaning with window size. Structure might benefit from a NARROWER
    window sampling range than other experts. Could the sampler learn an optimal range
    per expert? The structure expert needs 3-8 PELT segments to be meaningful — too
    few (large window) or too many (small window) degrades.

11. **Regime survived gates because of abstraction.** DFA alpha, entropy, fractal dim
    measure SERIES PROPERTIES not specific candle values. These are stable across
    window sizes. The other experts' facts depend on specific candle values in the
    window — different sampled windows give different facts. Regime's abstraction is
    its strength. This suggests: MORE abstract indicators for regime, FEWER window-
    dependent indicators shared with others.

12. **Expert vocabulary boundaries need revision.** The current assignment is ad-hoc:
    - Comparisons in momentum AND structure
    - eval_advanced in momentum AND structure AND regime
    - Price action in volume (but inside bars are geometric = structure?)
    A principled redesign: each expert should have EXCLUSIVE facts that no other
    expert sees, plus SHARED facts that provide common ground. The exclusive facts
    define the expert's unique perspective. The shared facts enable comparison.

## 2026-03-29: Exclusive vocabularies + enriched manager results

13. **Exclusive vocabularies doubled throughput.** 138/s up from 80/s. Less duplication =
    less compute. eval_advanced running once (regime) instead of 3x.

14. **The generalist proved itself for the first time with exclusive vocabularies.**
    Previously redundant (same signal with or without). Now the gap between generalist's
    holistic view (150 facts) and each specialist's narrow view (30-40 facts) is wider.
    The generalist IS adding information the specialists can't.

15. **Manager curve peaks at mid-conviction (53.0%) not high conviction (50.1%).** The
    manager is most accurate when moderately sure. At high conviction it may be
    overfitting to strong patterns that don't generalize. This is why the Kelly fit
    (which expects monotonic increase) doesn't validate as the action trigger.

16. **The generalist's curve is inverted: 41.3% at high conviction.** This is the
    strongest reversal signal in the system. The flip IS emerging in the manager's
    geometry — it reads the generalist's high conviction and learns it means the
    opposite. The generalist at 41.3% = 58.7% when flipped.

17. **Implemented per-expert reliability + tenure.** Each proven expert now contributes
    3 facts: signed conviction, accuracy level, resolved count. Addresses the
    mid-conviction peak — the manager can now distinguish reliable veterans from
    barely-proven newcomers. ~27 facts per candle, up from 6 original.

18. **The action trigger needs rethinking.** Kelly exponential fit assumes monotonic
    conviction→accuracy. The manager's actual curve peaks at mid-conviction. Need a
    different proof mechanism: "is there ANY conviction range where accuracy exceeds X%?"
    or a binned accuracy check instead of exponential fit.

## 2026-03-29: Scalar encoding mismatch

19. **encode_log was compressing expert convictions into noise.** Expert cosines range
    0-0.3. encode_log (designed for 1-10M packet rates) mapped the entire range to 15%
    of the rotation. The manager couldn't distinguish 0.05 from 0.20 — cosine similarity
    ~0.64 between them. This explains why the curve flattened at scale: the discriminant
    couldn't find boundaries when all inputs looked the same.

20. **Linear encoding with scale=1.0 for all [0,1] fractions.** The theoretical range
    of cosine magnitude is [0,1]. Scale=1.0 makes 0 and 1 orthogonal. No empirical
    tuning. No observed-data dependency. Initial attempt used scale=0.5 and 0.3 based
    on observed ranges — that's the same "magic number from data" anti-pattern.
    Scale=1.0 from the theoretical range is principled.

21. **Encoding rule: match the encoder to the value's nature.**
    - [0,1] fractions → encode-linear scale=1.0
    - Orders of magnitude → encode-log
    - Named categories → atom lookup
    - Below noise floor → silence
    This should be in the primitives spec.

22. **Named action atoms replaced permute.** bind(expert, bind(buy, magnitude)) instead
    of bind(permute(expert,1), magnitude). Named composition is readable and unbindable.
    But we haven't proven this produces better or worse signal than permute — it's a
    clarity improvement, not necessarily a signal improvement. Need to test both.

23. **The accuracy sweet spot scales with 1/sqrt(dims).** Peak accuracy at 0.06-0.10
    conviction = ~5-10σ where σ=1/sqrt(dims). Above noise floor (3σ) but below
    overconfidence. The discriminant amplifies both signal and error at high conviction.
    The sweet spot is where enough facts align to be above noise but not enough to
    amplify the discriminant's errors.

    At 20k dims: sweet spot ≈ 0.035-0.071
    At 10k dims: sweet spot ≈ 0.05-0.10
    At 4k dims:  sweet spot ≈ 0.08-0.16

    This means the swap conviction threshold is derivable: ~5/sqrt(dims).
    Not a tuned parameter. A geometric property. The manager should act
    when conviction is in the sweet spot, not at the extremes.
