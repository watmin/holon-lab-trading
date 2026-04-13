# Market Lenses: Pring

Three observers plus one generalist. Not six.

## Lens 1 — Impulse (momentum leading price)

```scheme
(define (market-lens-impulse)
  (list
    (roc-1) (roc-6) (roc-12)
    (macd-hist)
    (di-spread) (adx)))
```

Six atoms. The question: is momentum turning before price? ROC across
three timeframes gives the derivative stack. MACD-hist is the second
derivative. DI-spread and ADX tell you if the turn has conviction.
This is accumulation detection.

## Lens 2 — Confirmation (volume validates momentum)

```scheme
(define (market-lens-confirmation)
  (list
    (obv-slope) (volume-ratio) (mfi)
    (rsi-divergence-bull) (rsi-divergence-bear)
    (rsi) (tf-agreement)))
```

Seven atoms. The question: is the move real? OBV and volume-ratio
confirm smart money. MFI confirms flow. RSI divergences detect
distribution — momentum lying about price. TF-agreement checks
whether higher frames agree.

## Lens 3 — Regime (trending or noise)

```scheme
(define (market-lens-regime)
  (list
    (kama-er) (hurst)
    (adx) (choppiness) (squeeze)))
```

Five atoms. Not an observer — context for all? No. Regime IS an
observer. It answers a different question: should we trade at all?
Low efficiency + low Hurst + high choppiness = stay out. That
prediction has its own conviction curve, its own reckoner, its
own accountability. Regime earns its lens.

ADX appears in both Impulse and Regime. That is correct. Impulse
reads ADX as conviction. Regime reads ADX as trend existence.
Same atom, different question.

## Generalist

All 20 atoms. The reckoner decides what matters. Proven in the
current architecture — generalist stays.

## The grid

3 lenses + 1 generalist = 4 market observers.
4 market x 2 exit = 8 brokers per post.

Down from 6 x 2 = 12. More data per broker. Faster convergence.

## Why not two (lean + full)?

Exit worked with 2 because all three voices agreed on the SAME
atoms. Market atoms cluster into distinct questions. Impulse and
Confirmation ask different things about the same candle. Collapsing
them loses the disagreement signal — and disagreement between
momentum and volume IS the divergence signal.
