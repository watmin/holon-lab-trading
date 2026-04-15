# Review: Wyckoff

Verdict: APPROVED

I have read the tape. This proposal understands something most
systems never learn: the market rewards patience, but patience
without discipline is just stubbornness. The interest mechanism
is the discipline. Let me answer the ten questions.

---

## 1. The lending rate

ATR-proportional. Fixed rates ignore the character of the market.
A quiet accumulation range and a volatile markdown phase demand
different carrying costs. The rate should breathe with the spread
of the bars. When volatility contracts (as it does in accumulation),
the rate drops — allowing the patient holder to sit through the
cause being built. When volatility expands (markup, markdown), the
rate rises — demanding that the trade justify itself against larger
swings. One coefficient. ATR does the rest.

## 2. Entry frequency

The broker self-gates from the anxiety. Not one per candle — that
is overtrading, and overtrading is the amateur's disease. The
interest is the natural governor. A broker that enters every candle
during a buy window pays interest on 53 overlapping positions. The
anxiety atoms — `residue-vs-interest`, `interest-accrued` — will
teach the reckoner that stacking entries during a single phase is
expensive. The broker will learn to enter when the structure is
fresh and hold, not when the structure is stale and hope. The
treasury should not impose a limit. The interest IS the limit.

## 3. The reckoner's new question

Discrete. "Exit or hold at this trigger?" This is correct. The tape
reader does not predict how many points remain in a move. The tape
reader watches for the sign that the move is ending — the effort
without result, the climax, the test. The peak/valley trigger IS
that sign. The reckoner's job is to read the character of the
trigger, not to forecast distance. Continuous prediction of "how
much longer" is fortune-telling. Discrete evaluation at structural
inflection points is tape reading.

## 4. Treasury reclaim

Automatic. No grace period. When the interest exceeds the position
value, the trade is dead. Giving the broker "one more transition"
is the logic of hope, and hope is not a method. The composite
operator does not extend credit to weak hands. The weak hands are
shaken out. That is the function of the spring. The interest
exceeding position value IS the spring that the broker failed to
survive.

## 5. The residue threshold

Let the reckoner learn what "worth it" looks like. A fixed minimum
is another magic number. The 0.35% exit fee is arithmetic — that
is the hard floor. Everything above that floor is the reckoner's
judgment. A small residue after heavy interest may be worth taking
if the structure is breaking. A large residue may be worth holding
if the phase says the move continues. The reckoner sees the anxiety
atoms. It will learn the shape of "take it now" versus "let it run."
Do not constrain this with a parameter.

## 6. Both sides simultaneously

Yes. Both sides. The composite operator accumulates while
distributing. He is buying from weak hands at the bottom of a
trading range while simultaneously distributing remaining inventory
from the prior markup. The market does not move in one direction at
a time — it oscillates, and positions from prior phases overlap with
entries from the current phase. The broker holding old shorts during
a new buy window is exactly right. The exit conditions will resolve
the shorts at the appropriate trigger. The treasury lending both
sides is the bank's job — it does not have an opinion. It charges
interest.

## 7. The interest as thought

The four anxiety atoms are correct. I would add one:

```scheme
(Linear "residue-vs-fee" 1.8 1.0)  ;; can I even afford to leave
```

The distance between current residue and the exit fee is critical
context. A position with high residue-vs-interest but low
residue-vs-fee is trapped — profitable on paper but unable to exit.
The reckoner needs to feel this trap. It teaches: enter with enough
conviction that you can afford to leave.

## 8. The denomination

Per-candle twist is the right granularity — it matches the data
frequency. The rate should breathe with ATR (see Question 1). This
gives you volatility-adaptive carrying cost without a second
parameter. The denomination following the loan is correct and
clean. The lender wants its asset back plus rent. This is how
lending has worked for three thousand years.

## 9. Rebalancing risk

The phase labeler's symmetry (2,891 buy windows vs 2,843 sell
windows) provides natural balance over time, but not at every
instant. The treasury should track directional exposure as a
ratio and publish it as a fact. Not as a hard limit — as
information. If the brokers see the treasury is 80% long, the
anxiety of proposing another long increases. The exposure ratio
becomes another atom in the thought bundle. The system self-corrects
through awareness, not through a ceiling. If the imbalance persists,
the interest rate on the overweight side rises. Supply and demand
for capital.

## 10. Paper erosion as the only gate

Sufficient. The paper survival rate IS the EV gate — it just
measures EV differently. A broker with 70% survival and positive
average residue after interest HAS positive expected value. The
interest already accounts for time cost. The survival rate already
accounts for win rate. The average residue already accounts for
magnitude. Adding a separate EV calculation would be measuring the
same thing with different arithmetic. One gate. One metric. One
ledger. Clean.

---

## The Wyckoff Reading

This proposal captures the essential phases. The three-higher-lows
entry is accumulation detection — the cause being built, the spring
being loaded. The three-lower-highs entry is distribution detection
— the supply overwhelming demand, the upthrust failing. The
peak/valley triggers are the tests — the moments where the market
reveals its intention through effort and result.

The interest mechanism mirrors the composite operator's patience
with surgical precision. The composite operator can hold through an
accumulation phase because his cost of capital is low relative to
the cause being built. The broker that enters at the right phase
and holds through the structure earns cheap capital. The broker that
enters late or wrong pays the carrying cost of poor timing. This is
natural selection through economics — precisely how the composite
operator shakes out weak hands.

The paper trail IS reading the tape. Every paper is a print on the
tape. The treasury's ledger is the consolidated tape. The survival
rate is the running tally of who is on the right side. The gate is
the moment the tape reader says: "this operator knows what he is
doing — give him size."

The proposal kills distance-based exits. Good. The tape reader does
not set price targets. The tape reader watches for the sign that
the move is over — the effort without result, the climactic volume,
the test of the creek. The phase labeler's peaks and valleys ARE
these signs. The three-condition AND gate (phase + direction +
arithmetic) is the tape reader's discipline: the sign must appear,
the direction must confirm, and the math must work. All three. No
exceptions.

The treasury as lender is the clearing house. It cannot lose — it
can only rebalance. This is the correct abstraction. The clearing
house does not speculate. It facilitates, charges rent, and keeps
the book. The brokers speculate. The brokers pay. The brokers prove.

This is a sound proposal. Build it.
