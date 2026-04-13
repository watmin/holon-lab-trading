# Debate: Van Tharp

I have read Seykota's review and Wyckoff's review alongside my own. Three
CONDITIONAL verdicts. Unanimous on papers-never-stop. The divergences are
real and they matter. Let me address each tension honestly.

---

## Tension 1: Gate mechanism

**Seykota:** Full-rate always. No new states. No new parameters.
**Van Tharp (me):** Three-state machine: Proving, Active, Suspended.
**Wyckoff:** Proportional valve. Never zero. Throttle by EV magnitude.

### Where I concede

Seykota is right about one thing: papers should register at full rate,
always. My three-state machine was solving the wrong problem. If papers
are free, there is no reason to throttle them. I was importing position
sizing logic into a domain where there is no position. A paper trade
costs nothing. Throttling a zero-cost observation is waste, not
prudence.

I withdraw the three-state machine as applied to papers.

Wyckoff's proportional valve is elegant in theory but adds a parameter
(the proportionality function) that will need tuning, and the system
already has too many parameters that interact in ways we do not yet
understand. What is the function? Linear? Sigmoid? Log? Each choice is
a decision we make instead of letting the data make it.

### Where I hold

The three-state distinction still matters for **funded proposals**. A
broker that has only seen 200 trades should not propose capital
allocation. A broker that was once profitable and is now in drawdown
should not be treated identically to a broker that was never profitable.
These are different conditions and they deserve different labels.

But Seykota's point lands: the labels already exist in the data. EV is
positive or negative. Trade count is above or below threshold. The gate
function can express Proving/Active/Suspended as a pure function of
(trade_count, ev) without adding a state machine or new fields. No enum.
No transitions. Just arithmetic.

### Recommendation

**Papers register at full rate, always. No throttle. No state machine.
The gate controls funded proposals only.** The gate function for funded
proposals is:

- trade_count < 200: no funded proposals (Proving)
- trade_count >= 200 AND ev > 0: funded proposals allowed (Active)
- trade_count >= 200 AND ev <= 0: no funded proposals (Suspended)

This is Seykota's simplicity with my sample-size floor. It is a
function, not a state machine. Two parameters: the trade count threshold
(200) and zero. Zero is not a parameter. 200 is the only knob.

Wyckoff's valve applies to capital sizing, not paper registration. When
the broker IS proposing funded trades, Kelly or fractional-Kelly already
modulates size by edge. The valve is already there. It lives in the
treasury, not the gate.

---

## Tension 2: Journey grading mechanism

**Seykota:** Per-broker EMA. The struct already supports it. Simple.
**Van Tharp (me):** Replace EMA with rolling percentile. Bounded. Robust.
**Wyckoff:** Fix volume imbalance first. Then decide on the mechanism.

### Where I concede

Wyckoff is right about sequencing. The EMA collapsed because 4 brokers
pumped 73,000 observations into a shared grader while 18 pumped zero.
That is a volume problem, not an EMA problem. If every broker grades
its own journey independently, no single broker can drown the others,
and the EMA's effective window of ~200 observations becomes appropriate
again.

Per-broker grading may be sufficient. I was prescribing a mechanism
change when the real disease was a distribution problem.

### Where I hold

The EMA has a structural weakness that per-broker grading mitigates but
does not eliminate. An EMA never forgets. Every observation it has ever
seen is in there, exponentially decayed but present. A broker that was
terrible for 2,000 trades and then becomes good will carry the ghost
of those 2,000 terrible trades in its EMA for hundreds more observations.
The rolling percentile has a hard cutoff: observation 201 falls off
the window completely.

But I concede this is a second-order effect. The first-order effect is
the volume imbalance. Fix that first.

### Recommendation

**Per-broker journey grading first. Keep the EMA. Measure after 100k
candles. If the per-broker EMA still collapses or fails to track regime
changes, replace with rolling percentile then.**

This is Wyckoff's sequencing with my fallback. Do not change two things
at once. Change the distribution (per-broker). Run the benchmark.
Measure. If the EMA still fails under per-broker grading, we know the
EMA itself is the problem and the rolling percentile is the fix.

Seykota and Wyckoff are both right that the struct already has
`journey_ema` and `journey_count` per broker. The implementation cost
is near zero. Do the cheap thing first, measure, then decide if the
expensive thing is needed.

---

## Tension 3: Market observer independence

**Seykota:** Decouple explicitly. Market observer learns from directional
accuracy, not trade profitability. Different signal, different path.
**Van Tharp (me):** Solved naturally by papers-never-stop. Not urgent.
**Wyckoff:** Decouple explicitly. Independent learning path.

### Where I concede

Seykota and Wyckoff are right. I was wrong.

My argument was: if papers never stop, resolutions always flow, and
the market observer always learns. Therefore decoupling is automatic.

But that argument only holds if the market observer's LABEL is correct.
The market observer currently learns from broker resolutions. The
broker's resolution reflects the JOINT outcome of market prediction
and exit execution. A market observer that correctly predicted Up, paired
with an exit observer that set a trailing stop too tight and got stopped
out, receives a Violence label. The market observer is told it was wrong
when it was right.

Papers-never-stop ensures the signal keeps flowing. But if the signal
is mislabeled, flowing garbage is still garbage. The market observer
needs to learn from directional accuracy: did the price move in the
predicted direction over the paper's horizon? That is a different
question from: did the trade make money?

This is a wiring problem, not a volume problem. Papers-never-stop does
not fix it. Seykota saw it clearly. The learning signal must match
the learning objective. The market observer's objective is direction.
Its signal must be direction. Not profitability. Not EV. Direction.

### Where I hold

This is a deeper change than the gate fix or the per-broker grading.
It requires the broker to split its learn signal: directional accuracy
goes to the market observer, trade profitability goes to the exit
observer. The broker already knows both facts at resolution time. But
the current wiring sends one composite signal. Splitting it means
changing the broker's resolution logic and the learn channel protocol.

This should be implemented, but it should be sequenced AFTER the gate
fix and per-broker grading. The gate fix is urgent (18 dead brokers).
Per-broker grading is urgent (EMA collapse). Market observer decoupling
is important but not blocking. The market observer already has 59.8%
accuracy despite the bad labels -- it is robust to some amount of
label noise. Fixing the labels will improve it, but it is not dying.

### Recommendation

**Decouple market observer learning from trade profitability. The
market observer learns from directional accuracy (did price move in
the predicted direction?). The exit observer learns from trade outcome
(was the exit profitable?). Implement in the same proposal, sequenced
after the gate fix.**

Seykota is right that this is the root wiring fix. Wyckoff is right
that it must be explicit, not assumed. I was wrong to say papers-never-stop
solves it naturally. It does not. The label is wrong, not the volume.

---

## Summary of positions

| Tension | My original position | My revised position | Who moved me |
|---------|---------------------|--------------------| ------------|
| Gate | Three-state machine | Pure function of (count, ev). Papers full rate. No state machine. | Seykota (simplicity) |
| Journey | Replace EMA with percentile | Per-broker EMA first. Measure. Percentile as fallback. | Wyckoff (sequencing) |
| Observer | Solved by papers-never-stop | Must decouple explicitly. Different labels for different learners. | Seykota (signal clarity) |

## The three changes, in order

1. **Papers always register at full rate.** Gate controls funded proposals only. Funded proposals require trade_count >= 200 and positive EV. No new states. No new parameters beyond the 200 threshold.

2. **Per-broker journey grading.** Each broker grades its own papers against its own EMA. The struct already supports it. No mechanism change yet. Measure after 100k candles. If the EMA still fails, replace with rolling percentile (N=200, 50th percentile threshold).

3. **Market observer learns from direction.** The broker splits its learn signal at resolution time. Market observer receives a directional accuracy label. Exit observer receives a trade outcome label. Different signals for different objectives.

These three changes are independent. They can be implemented and tested
separately. Each one addresses a distinct failure mode. Together they
ensure: no broker starves, no observer is mislabeled, no grading
mechanism is dominated by volume imbalance.

The system does not need new machinery. It needs the existing machinery
wired correctly. Seykota saw that most clearly. I was adding complexity
where simplicity was sufficient. A position sizing expert should know
better -- the best position size for a zero-cost observation is always
full size.
