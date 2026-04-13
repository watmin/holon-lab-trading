# Proposal 037 — Journey Threshold Mechanism

**Scope:** userland

**Depends on:** Proposal 036 (exit journey learning)

## The current state

Proposal 036 was approved. Per-candle journey grading with residue
weights. The error ratio (actual vs optimal distance) determines
whether a candle was Grace or Violence. The question 036 left open:
what threshold separates Grace from Violence?

The designers rejected fixed thresholds (50%). Both said: let the
threshold be self-calibrating.

## The problem

The error ratio is a continuous value. The `is_grace` field is a
bool — the rolling window needs a binary label to compute grace_rate.
The binary label requires a threshold. The threshold determines the
Grace/Violence balance of the exit observer's training data.

A fixed threshold is a magic number. Too tight: everything is
Violence. Too loose: everything is Grace (the current lie). The
threshold must adapt to the distribution of errors the exit observer
actually produces.

## The proposed change

An EMA of observed error ratios, maintained per broker. The EMA
tracks what "typical" management quality looks like. A candle with
error below the EMA is Grace (better than typical). A candle with
error above the EMA is Violence (worse than typical).

```scheme
;; Per broker: track the running average of error ratios.
(let ((ema-error 0.5)       ;; initial: assume 50% error
      (alpha 0.01))         ;; slow EMA — adapts over ~100 observations
  (for-each (lambda (batch-entry)
    (let* ((actual (:distances batch-entry))
           (optimal (:optimal batch-entry))
           (trail-err (/ (abs (- (:trail actual) (:trail optimal)))
                         (max (:trail optimal) 0.0001)))
           (stop-err (/ (abs (- (:stop actual) (:stop optimal)))
                        (max (:stop optimal) 0.0001)))
           (error (/ (+ trail-err stop-err) 2.0))
           (is-grace (< error ema-error)))

      ;; Update EMA
      (set! ema-error (+ (* (- 1 alpha) ema-error) (* alpha error)))

      ;; Send with journey grade
      (send exit-learn-tx
        (make-exit-learn
          :exit-thought (:thought batch-entry)
          :optimal (:optimal batch-entry)
          :weight (:excursion batch-entry)   ;; residue-based
          :is-grace is-grace
          :residue (:excursion batch-entry)))))
    batch-entries))
```

## The algebraic question

The EMA is a scalar accumulator — the same mechanism the enterprise
uses everywhere (ScalarAccumulator, noise subspace EMA, broker P&L
EMA). It composes with the existing fold. It's a value that threads
through the candle loop. No new algebraic structure.

The EMA lives on the broker. Each broker tracks its own error
distribution — no contamination between brokers. The same isolation
principle as each observer owning its own scales.

## The simplicity question

The EMA is simple. One float. One alpha. One comparison. The
alternative (sorted vec for true median) is more complex and slower.
The EMA is not the median — it's the mean. But for this purpose:
"better than average = Grace, worse than average = Violence" is
an honest threshold that self-calibrates.

The initial value (0.5 = 50% error) means early candles are graded
against a generous threshold. As the EMA converges, the threshold
tightens to the actual distribution. Cold start is loose. Warm
start is honest.

## Questions for designers

1. Is the EMA the right tracker, or should we use a true running
   median? The EMA is simpler but sensitive to outliers. The median
   is robust but requires maintaining a sorted buffer.

2. Should each broker maintain its own EMA, or should there be one
   per exit observer? Per-broker means 24 independent thresholds.
   Per-exit means 4 (one per lens). The isolation principle says
   per-broker. The sample size says per-exit.

3. Should the alpha (0.01) be fixed or learned? A slower alpha
   (0.001) tracks the long-term distribution. A faster alpha (0.05)
   reacts to regime changes. The market doesn't stay still.

4. The initial EMA value (0.5) is a guess. Should it be seeded from
   the first N observations instead?
