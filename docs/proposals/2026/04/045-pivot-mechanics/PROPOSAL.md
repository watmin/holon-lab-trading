# Proposal 045 — Pivot Mechanics

**Scope:** userland

**Depends on:** Proposal 044 (pivot biography)

## The two unknowns from 044

Proposal 044 designed the vocabulary — what pivots ARE, what
atoms they produce, how the series encodes. This proposal
resolves the two implementation questions 044 left open.

## Unknown 1: Conviction as a learned threshold

The market observer produces conviction every candle. Some
candles are pivots. Most are not. What separates them?

A fixed threshold is a magic number. An adaptive threshold
is a measurement. The conviction distribution itself is
observable — the machine can build an intuition for what
to trust.

```scheme
;; The conviction is a stream. The stream has a distribution.
;; The machine learns the distribution over time.
;; A pivot is a conviction that exceeds what the machine
;; has learned to expect.

(define (is-pivot? conviction conviction-history)
  ;; The conviction history is a rolling window.
  ;; The threshold is a percentile of that window.
  ;; High percentile = rare = pivot.
  ;; The threshold breathes with the market.
  ;;
  ;; Trending market: conviction is often high → threshold rises.
  ;; Choppy market: conviction is often low → threshold drops.
  ;; The pivot is always RELATIVE to recent experience.
  (> conviction (percentile conviction-history 0.80)))
```

The 80th percentile means: this candle's conviction is higher
than 80% of recent candles. That IS a pivot — something
unusual is happening relative to what we've been seeing.

The rolling window is the same bounded mechanism from Proposal
043 (the journey grading window). A VecDeque of the last N
conviction values. N=500 (about 42 hours at 5-minute candles)
gives enough history to establish a baseline without being
too sticky.

### Who owns the conviction history?

The market observer produces conviction. The exit observer
consumes the pivot classification. The broker routes between
them. Who maintains the conviction history and detects pivots?

The market observer doesn't know about pivots. It predicts
direction. That's its job.

The broker doesn't track pivots either. The broker's concern
is whether the (market, exit) pair produces Grace. The broker
composes their thoughts and grades the pairing.

**The exit observer owns the pivot state.** The exit observer
receives the market chain every candle — including the market
observer's conviction. The exit observer is the one who ACTS
on pivots — managing trades, setting distances, tracking the
series. The exit observer maintains:

1. The conviction history (rolling window for threshold)
2. The current period state (pivot or gap, with running stats)
3. The pivot memory (bounded VecDeque of completed periods)
4. The Sequential series encoding

The exit observer asks: "is this candle a pivot?" and tracks
the answer over time. The pivot vocabulary — the series atoms,
the trade biography, all of it — lives on the exit observer
because the exit observer is the one thinking about WHEN to
act and WHAT the action pattern looks like.

## Unknown 2: The exit observer's pivot state machine

The exit observer needs to know: am I currently in a pivot
period or a gap period? When did this period start? What are
the running stats?

```scheme
(struct current-period
  kind            ;; :pivot or :gap
  direction       ;; :up or :down (pivots only, None for gaps)
  start-candle    ;; when this period began
  close-sum       ;; running sum of close prices
  volume-sum      ;; running sum of volume
  high            ;; highest close in this period
  low             ;; lowest close in this period
  count)          ;; candles in this period

(struct pivot-record
  kind            ;; :pivot or :gap
  direction       ;; :up or :down (pivots only)
  candle-start    ;; when it began
  candle-end      ;; when it ended
  duration        ;; candles
  close-avg       ;; average close price
  volume-avg      ;; average volume
  high            ;; highest close
  low             ;; lowest close
  conviction-avg) ;; average conviction during this period (pivots only)
```

The state machine:

```scheme
(define (exit-on-candle exit candle conviction direction)
  (let ((threshold (percentile (:conviction-history exit) 0.80)))

    ;; Update conviction history
    (push! (:conviction-history exit) conviction)

    (cond
      ;; Currently in a gap, conviction rises above threshold → new pivot begins
      ((and (eq? (:kind (:current-period exit)) :gap)
            (> conviction threshold))
       ;; Close the gap, record it
       (push! (:pivot-memory exit) (finalize-period (:current-period exit)))
       ;; Start a new pivot
       (set! (:current-period exit)
         (new-period :pivot direction candle close volume)))

      ;; Currently in a pivot, conviction drops below threshold → gap begins
      ((and (eq? (:kind (:current-period exit)) :pivot)
            (<= conviction threshold))
       ;; Close the pivot, record it
       (push! (:pivot-memory exit) (finalize-period (:current-period exit)))
       ;; Start a new gap
       (set! (:current-period exit)
         (new-period :gap #f candle close volume)))

      ;; Currently in a pivot, conviction still high → extend the pivot
      ((eq? (:kind (:current-period exit)) :pivot)
       (extend-period! (:current-period exit) candle close volume conviction))

      ;; Currently in a gap, conviction still low → extend the gap
      (else
       (extend-period! (:current-period exit) candle close volume 0.0)))))
```

The pivot memory is bounded at 20 entries (10 pivots + 10 gaps
roughly). When it fills, the oldest drops off. The Sequential
encoding walks the memory left to right — oldest to newest.

## The exit observer's new fields

```scheme
(struct exit-observer
  ;; ... existing fields ...

  ;; NEW — pivot tracking (Proposal 045)
  conviction-history    ;; VecDeque<f64>, bounded at 500
  current-period        ;; CurrentPeriod — what we're in right now
  pivot-memory          ;; VecDeque<PivotRecord>, bounded at 20
)
```

## The broker's role

The broker does NOT track pivots. The broker's concern is
accountability — does this (market, exit) pair produce Grace?

The broker receives the market chain (with conviction and
direction). The broker passes it to the exit observer through
the existing chain. The exit observer tracks pivots internally
and produces:

1. Trail/stop distances (existing)
2. Pivot series atoms (new — from 044)
3. Trade biography atoms (new — per active paper)

The broker composes the exit's output with the market's output
and grades the pairing. The broker doesn't know about pivots.
The broker knows about Grace and Violence.

The portfolio biography atoms (044) — active-trade-count,
oldest-trade-pivots, etc. — these DO live on the broker because
they describe the broker's portfolio of papers. But they are
computed FROM the exit observer's pivot classification. The
exit tells the broker "this is a pivot" through the atoms it
produces. The broker reads the atoms. The broker doesn't
detect pivots.

## The ownership question

The proposal places pivot detection on the exit observer. But
the builder asks: should the BROKER detect pivots and signal
back to the exits?

The argument for the exit observer owning it: the exit is the
one who ACTS on pivots — managing trades, setting distances.
The pivot vocabulary is about exit management.

The argument for the broker owning it: the broker sees BOTH
the conviction (from the market chain) AND the active papers
(its portfolio). The broker knows "this is a pivot AND I have
3 trades running AND the oldest is 5 pivots deep." The exit
observer sees one trade at a time — it doesn't see the
broker's portfolio shape.

The argument for a separate component: pivot detection is
about MARKET STRUCTURE — neither exit management nor pair
accountability. It's a third concern. Maybe it lives on its
own, feeds both the exit and the broker.

This question is open. The designers should argue it.

## Questions for strategy designers (Seykota, Van Tharp, Wyckoff)

1. **The percentile threshold (80th):** is this the right
   level? Higher = fewer pivots, more selective. Lower = more
   pivots, more noise. Should this be fixed or should each
   exit observer discover its own threshold?

2. **The conviction window (N=500):** is 500 candles the right
   baseline? Too short and the threshold is noisy. Too long
   and it's sticky. Should it match the market observer's
   recalibration interval?

3. **Direction changes within a pivot:** conviction stays high
   but direction flips (Up becomes Down). Is this one pivot or
   two? Should a direction change force a new period even if
   conviction stays above threshold?

4. **The gap minimum duration:** should a single candle below
   threshold start a gap? Or should the conviction stay below
   threshold for N candles before a gap is declared? A
   minimum prevents flickering.

## Questions for architecture designers (Hickey, Beckman)

5. **Who owns pivot detection?** Three candidates:
   (a) The exit observer — it acts on pivots.
   (b) The broker — it sees conviction AND the portfolio.
   (c) A separate component — pivot detection is market
   structure, a third concern distinct from exit management
   and pair accountability. Where does it live?

6. **The conviction history as a rolling percentile:** this is
   the same bounded-window mechanism from Proposal 043 (journey
   grading). Should it be extracted into a reusable primitive
   (`RollingPercentile` struct) that both the journey grading
   and the pivot detection share?
