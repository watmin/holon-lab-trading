# Review: Van Tharp

Verdict: CONDITIONAL

## The expectancy diagnosis

Your current system has negative expectancy. Let me show you why holding fixes the math and where it doesn't.

Current scalp: E = (0.68 × 0.21%) - (0.32 × 0.49%) - 0.70% = 0.143% - 0.157% - 0.70% = **-0.71% per trade**. Every trade destroys capital. The fee is 3.3× the average win. This is not a trading problem. This is an arithmetic problem.

Proposed hold: E = (0.68 × 4.3%) - (0.32 × R_loss) - 0.70%. If R_loss is a 2% stop, E = 2.924% - 0.64% - 0.70% = **+1.58% per trade**. Positive. The fee drops from 333% of the win to 16% of the win. Holding changes the ratio of signal to friction.

## The five questions

**1. Discrete vs continuous exit.** Continuous. "Hold or exit" is a binary that throws away magnitude. A wider predicted distance naturally extends holding period AND gives you a stop distance — which defines 1R. Without 1R you cannot size.

**2. Threshold registration vs every candle.** Threshold. Every-candle registration at 0.70% round-trip is financial suicide. If the machine registers 50 papers per move, that's 50 × 0.70% = 35% in fees to capture a 5% move. Register when conviction exceeds the fee-adjusted breakeven. Fewer entries, larger per-entry allocation, same total exposure.

**3. Treasury as portfolio manager.** Yes, but with hard constraints. The treasury must enforce maximum concurrent exposure. N simultaneous positions at 1/N sizing each. The treasury IS the position sizing model.

**4. Learnable holding value.** Proxy. ATR-scaled expected move, decaying over holding duration. The exit observer can learn this curve from resolved trades — plot residue-at-exit vs candles-held, fit the decay. It's not predicting the future. It's learning the typical shape of moves it has seen.

**5. Higher lows as deployment signal.** Same observer, sustained conviction. A new readiness signal creates a new thing to calibrate. Sustained conviction above threshold from the existing observer is simpler and testable.

## The R-multiple challenge

A hold trade with a 2% stop and a 5% target captures 2.5R. Current scalps capture roughly 0.3R before fees, negative after. The R-multiple improvement is ~8×. But 1R must be defined by the stop distance, not the entry. If the exit observer sets stops, it defines R. Good.

## The 50-entry accumulation

50 entries × 0.70% = 35% fee load. On a 5% move, you lose 30% to fees. **Do not deploy 50 times.** Deploy 3-5 times at high-conviction moments. Each deployment: 2-5% of capital. Total exposure: 10-25% of capital on one thesis. The accumulation model works only if each entry independently has positive expectancy after its own fee.

Each entry must satisfy: expected_capture > 0.70%. If you deploy at +1% into a 5% move, expected remaining capture is 4%. Fee is 0.70%. E > 0. Good. If you deploy at +4% into a 5% move, expected remaining capture is 1%. Fee is 0.70%. Marginal. The later entries have worse expectancy. The treasury must know this.

## Position sizing

Fixed fractional. Risk 1-2% of capital per deployment. If stop distance is 2%, position size = (capital × 0.02) / 0.02 = 1× capital per entry. With 5 entries maximum: 5× capital committed, 10% of capital at risk total. This is aggressive but bounded. Kelly fraction at 68% win rate and 2.5R payoff: f* = (0.68 × 2.5 - 0.32) / 2.5 = 0.55. Half-Kelly: 0.275. You have room.

## Condition for approval

Prove one broker achieves E > 0 after fees on 100k candles with the hold architecture. Not 24 brokers. One. Then scale.
