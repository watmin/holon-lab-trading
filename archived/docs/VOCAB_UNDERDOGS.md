Underdog vocab spec saved in task notification above. Key summary:

# Underdog Expert Vocabularies — 78 new atoms

## TD Sequential (12 atoms)
Exhaustion counting. 9 consecutive closes above/below close[i-4] = reversal signal.
Zones: inactive, building, mature, exhausted, perfected.
KEY INSIGHT: This is what our conviction flip discovers empirically. TD Sequential names it explicitly.

## Choppiness Index (11 atoms)
Trending vs ranging measurement. CI = 100 * log(sum_ATR / range) / log(period).
Zones: strong-trend (<38.2), transition (50-61.8), choppy (>61.8).
KEY INSIGHT: Our worst epoch (2023, 50.1%) was choppy. This thought could have gated those trades.

## Hurst Exponent (10 atoms)
Trend persistence measurement. H>0.5=trending, H<0.5=mean-reverting, H=0.5=random.
Zones: strong-mean-revert (<0.35), random (0.45-0.55), strong-persist (>0.65).
KEY INSIGHT: Our conviction flip bets on mean reversion. Hurst tells us when that bet is valid.

## Aroon (13 atoms)
Trend freshness. "How long ago was the most recent high/low?"
Zones: strong-up, strong-down, emerging, consolidating, contested.
KEY INSIGHT: Stale highs/lows = exhaustion signal. Complements TD Sequential.

## Vortex Indicator (12 atoms)
Directional thrust. Leads moving average crosses by 2-4 bars.
Zones: strong-bull, neutral, strong-bear. Predicates: widening, narrowing, tangled.
KEY INSIGHT: Early trend detection. Vortex cross happens BEFORE the SMA cross.

## Chaikin Money Flow (15 atoms)
Accumulation/distribution pressure. Where close sits within the bar's range × volume.
Zones: strong-buy-pressure, neutral, strong-sell-pressure.
KEY INSIGHT: CMF divergence = institutional distribution hiding behind rising prices.

## Cross-Expert Confluence (5 atoms)
Multi-expert agreement signals:
- confluence_reversal_top: TD exhausted + CMF divergence + Aroon stale + Hurst extreme
- confluence_reversal_bottom: same pattern, opposite direction
- confluence_trend_birth: Vortex cross + Aroon fresh + Chop entering-trend + Hurst persistent
- confluence_no_trade: Chop extreme + Hurst random + Vortex tangled + Aroon weak
- confluence_regime_shift: Hurst shift + Chop change + Vortex cross within 3 bars

## Implementation: all computable from 48-candle OHLCV window, no DB changes.
