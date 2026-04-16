# Review: Hickey (Round 2)

Verdict: APPROVED

---

## Were the conditions met?

Three conditions. Let me take them one at a time.

### 1. Real BTC data proof

Met. `prove_rhythm_real_data.rs` reads 3,000 real 5-minute BTC candles from parquet, runs them through IndicatorBank (real RSI, MACD, ADX, OBV — not synthetic monotone series), builds 50-candle rhythm windows, trains a subspace on the first half, tests on the second half. The result:

```
raw cosine (up vs down):     0.7978
anomaly cosine (up vs down): -0.0910
```

And confirmed at 10,000 candles: -0.0991. The raw cosine drops from ~0.80 to near-orthogonal after stripping. This is not synthetic-data separation. This is real indicator values, real noise, real regime transitions. The subspace finds the signal.

I asked for the adversarial case. This is closer to it than the synthetic proof was. Real markets have pullbacks within uptrends, pauses within selloffs, volume spikes unrelated to direction. The fact that the anomaly cosine goes *negative* — not merely low, but opposed — says the stripped representation actively separates regimes. The subspace learned what "normal rhythm" looks like and the deviation from normal IS the directional signal.

The test methodology is straightforward: classify windows by net price movement (>1% = up, <-1% = down), train on early windows, test on later windows. No lookahead. No cherry-picking. The stride of 10 candles gives overlapping windows, which means the training set has temporal correlation — this is realistic, not a flaw.

Satisfied.

### 2. Delta braiding

Addressed. `prove_delta_braiding.rs` measures both approaches:

```
Braided:   6.10x separation
Separated: 6.89x separation
Margin: 13%
```

The separated approach is better. I said it would be. On synthetic data, the margin is 13%. The proposal acknowledges this and takes the braided approach anyway — "datamancer override, confirmed by measurement."

I raised the concern because two different notions of "previous" braided into one record means the reckoner cannot attend to one without the other. That concern stands. But the measurement shows the cost is 13% on synthetic data where the structure is maximally clean. On real data with noise, the margin will compress. And the simplicity argument has weight: one record, one encoding, no parallel structural-momentum streams to manage.

The datamancer made a judgment call with the measurements in front of him. The 6.10x separation is more than sufficient — the question was never "does braiding kill the signal" but "does braiding leave money on the table." 13% on synthetic, probably less on real. The answer is: some, but not enough to justify the added complexity.

I would have separated them. But I'm not building this. The person who has to live with the code chose the simpler path, with measurements to back the choice. That's how engineering decisions should be made.

Accepted.

### 3. Throughput estimate

Partially addressed. The proposal says "cache handles it (98% hit rate measured). Not proven at rhythm scale yet." This is honest but incomplete. The back-of-envelope math I asked for: 15 indicators times 100 candles = 1,500 fact encodings per market observer per candle. At 98% cache hit rate, that's 30 cold encodings per candle. The thermometer encoding is cheap — fill a vector proportionally, no trig. The bind and bundle are XOR and element-wise add. At D=10,000 with f32, these are memory-bandwidth-limited, not compute-limited.

The proposal doesn't have a wall-clock number. But the architecture doesn't change the candle-rate bottleneck — it changes the per-candle encoding cost. If the current system does 251 candles/second with 33 facts, and the new system does 1,500 facts but 98% are cached, the effective increase is ~1,500 * 0.02 = 30 uncached + 1,500 cached lookups. The cached lookups are HashMap gets. The uncached are thermometer fills + bind. This should be within 2-3x of the current cost, not 40x.

I'll take the 98% cache measurement as evidence the system thought about throughput. The real answer will come from the first benchmark after implementation. If it regresses badly, the proposal has a natural escape: reduce the window size or the indicator count. The trim mechanism is already there.

Accepted with reservation: measure it after implementation. If throughput drops below 100 candles/second, something needs to give.

## What improved since round 1

The atom factoring (Beckman's condition) is the right call. Moving the atom from inside each candle's fact bundle to wrapping the whole rhythm means N candles produce one atom-bind instead of N. Two RSI rhythms (rising vs falling) now differ in their raw progression content, not in N copies of the same atom polluting the bundle. The constant was factored out. Good.

The `circular-rhythm` variant for periodic values (hour, day-of-week) is clean. Circular encoding handles the 23-to-0 wrap. No delta for periodic values — the delta of -23 is meaningless when the true distance is 1. This was Beckman's catch and it's resolved correctly.

The proposal now has seven test files. The layered proof strategy — synthetic first (mechanism works), then real data (mechanism works on actual BTC), then delta braiding (design choice measured) — is how proof should be structured. Each test answers one question. No test tries to prove too much.

## What I'd still watch

**The regime observer naming.** I called it out in round 1: "middleware" is the wrong word for something with a learned subspace. The proposal still calls it "Middleware" in the header. This is a small thing, but names matter. A thing that learns its own normal is an observer, even if it doesn't predict a label.

**Numerical stability at depth.** I flagged this in round 1 as a concern at D=4,096. The proposal moved to D=10,000 minimum (Van Tharp's condition). At 10k dimensions with f32, the noise floor from deep compositions (10 facts -> trigram -> pair -> rhythm -> outer bundle) is low enough. But if anyone tries to run this at D=4,096 in a year, the trigram-of-trigrams depth will degrade. The minimum dimension constraint is the right guardrail.

**The real throughput number.** I accepted the cache argument, but the first 100k benchmark after implementation will tell the truth. Measure it.

## Summary

The proposal went from "this should work" to "this does work, here are the numbers." Real BTC data. Measured delta braiding trade-off. Factored atoms. Circular variant for periodic values. The conditions I set were substantive and the responses were substantive.

The architecture is simple in the way that matters: each layer does one thing, values flow up, the container doesn't order, the content carries its own relations. The noise subspace at each level strips the background appropriate to that level's question. The thermometer encoding gives an exact linear gradient with bounds derived from the indicator's definition.

Ship it.
