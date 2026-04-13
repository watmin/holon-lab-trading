# Proposal 049 — The Phase Labeler

**Scope:** userland

**Replaces:** 044-048's conviction-based pivot detection with
structural phase labeling from price.

## The thought

The machine needs a thing that looks at closes and says one
of three words: **valley**, **peak**, **transition**.

Every candle. One label. That's its only job.

```
price:  ___/‾‾‾\___/‾‾\__/‾‾‾‾‾\____
label:  VVV TTTTT PPP TTT VV TTT PPPPP TTTT
```

Not a predictor. Not a learner. Not a trader. A CLASSIFIER.
A pure function of recent closes. It labels the present moment
into one of three phases. The label flows downstream. Whoever
needs it reads it.

## What it takes

A window of recent closes. That's all. The labeler looks at
the window and maps out a sequence of phases.

```scheme
(define (label-phases closes smoothing)
  ;; Input: Vec<f64> — recent close prices
  ;; Output: Vec<PhaseRecord> — the sequence of phases
  ;;
  ;; The smoothing determines the minimum swing size.
  ;; Moves smaller than the smoothing are noise.
  ;; Only confirmed turns produce phase boundaries.
  ...)
```

The smoothing is the only parameter. It determines what
counts as a "real" turn vs noise. ATR-based makes it breathe
with the market. A fixed percentage is simpler.

## What it produces

A sequence of phases. Each phase has attributes:

```scheme
(struct phase-record
  label           ;; :valley, :peak, or :transition
  direction       ;; :up or :down (transitions only, None for peaks/valleys)
  start-candle    ;; when this phase began
  end-candle      ;; when this phase ended (None if current)
  duration        ;; candles in this phase
  close-min       ;; lowest close during this phase
  close-max       ;; highest close during this phase
  close-avg       ;; average close
  close-open      ;; close at start of phase
  close-final     ;; close at end of phase (or current close)
  volume-avg      ;; average volume during this phase
  )
```

The sequence alternates: valley → transition-up → peak →
transition-down → valley → ...

Each phase's attributes are FACTS. All encodable as atoms.
The exit observer thinks about them. The broker thinks about
them. The reckoner discovers which phase attributes predict.

## The three labels

**Valley:** price is near a confirmed local low. The smoothed
price was falling and has now reversed upward by more than the
smoothing threshold. The valley zone is the period around the
confirmed low — the candles where the price was within the
smoothing distance of the minimum.

**Peak:** price is near a confirmed local high. The smoothed
price was rising and has now reversed downward by more than
the smoothing threshold. The peak zone is the period around
the confirmed high.

**Transition:** price is moving directionally between a
confirmed valley and a confirmed peak (up) or between a
confirmed peak and a confirmed valley (down). The directional
move. The trend. The part between the turning points.

## The smoothing

The smoothing determines the minimum swing size. Moves smaller
than the smoothing are ignored — they're noise within a phase.

```scheme
;; Option A: ATR-based. Breathes with the market.
;; A turn must exceed 1× ATR to be confirmed.
(define smoothing (* 1.0 (current-atr)))

;; Option B: percentage. Simple. A parameter.
;; A turn must exceed 0.5% to be confirmed.
(define smoothing (* 0.005 current-close))

;; Option C: adaptive. A percentile of recent swing sizes.
;; The smoothing IS what the market has been doing.
(define smoothing (percentile recent-swing-sizes 0.50))
```

## The detection algorithm

```scheme
(define (update-labeler labeler close volume candle-num)
  (let ((state (:state labeler))
        (threshold (:smoothing labeler)))

    (cond
      ;; Currently tracking a potential PEAK
      ;; (price was rising, watching for reversal)
      ((eq? (:tracking state) :high)
       (cond
         ;; New high — extend the peak tracking
         ((> close (:extreme state))
          (set-extreme! state close candle-num))

         ;; Fallen enough from the high — CONFIRM the peak
         ;; The turn is real. Close the peak phase. Open transition-down.
         ((> (- (:extreme state) close) threshold)
          (confirm-peak! labeler state candle-num)
          (begin-transition! labeler :down close candle-num))

         ;; Still near the high — extend the peak zone
         (else
          (extend-current-phase! state close volume))))

      ;; Currently tracking a potential VALLEY
      ;; (price was falling, watching for reversal)
      ((eq? (:tracking state) :low)
       (cond
         ;; New low — extend the valley tracking
         ((< close (:extreme state))
          (set-extreme! state close candle-num))

         ;; Risen enough from the low — CONFIRM the valley
         ((> (- close (:extreme state)) threshold)
          (confirm-valley! labeler state candle-num)
          (begin-transition! labeler :up close candle-num))

         ;; Still near the low — extend the valley zone
         (else
          (extend-current-phase! state close volume))))

      ;; Currently in TRANSITION
      ;; Watch for the next extreme
      ((eq? (:label (:current-phase state)) :transition)
       (if (eq? (:direction (:current-phase state)) :up)
         ;; Transition up — track the running high
         (if (> close (:extreme state))
           (set-extreme! state close candle-num)
           ;; Fallen from the running high — potential peak forming
           (when (> (- (:extreme state) close) threshold)
             (close-transition! labeler state candle-num)
             (begin-peak! labeler state candle-num)
             (set! (:tracking state) :high)))
         ;; Transition down — track the running low
         (if (< close (:extreme state))
           (set-extreme! state close candle-num)
           ;; Risen from the running low — potential valley forming
           (when (> (- close (:extreme state)) threshold)
             (close-transition! labeler state candle-num)
             (begin-valley! labeler state candle-num)
             (set! (:tracking state) :low))))))))
```

## Where it lives

The labeler is a pure computation on closes. It needs:
- A window of recent closes (already on the candle stream)
- A smoothing parameter (ATR or fixed)
- Internal state (current phase, extreme tracking)

It could live:
1. **On the indicator bank** — like RSI, like ATR. One more
   streaming computation. The Candle gains a `phase` field.
   Every observer sees it.
2. **On the pivot tracker program** — replaces the conviction-
   based detection with price-structure detection.
3. **On each broker** — if each broker's window differs.

## The phase series as thoughts

The sequence of phases IS the pivot biography from 044 — but
now built from confirmed price structure, not conviction
spikes. The vocabulary from 044 applies directly:

```scheme
;; Each phase is a thought
(define (phase-thought phase)
  (bundle
    (bind (atom "phase") (atom (:label phase)))      ;; valley/peak/transition
    (bind (atom "phase-direction") 
      (if (:direction phase) 
        (atom (:direction phase)) 
        (atom "none")))
    (log "phase-duration" (:duration phase))
    (linear "phase-range" 
      (/ (- (:close-max phase) (:close-min phase)) 
         (:close-avg phase)) 
      1.0)
    (linear "phase-volume" (:volume-avg phase) 1.0)
    (linear "phase-move" 
      (/ (- (:close-final phase) (:close-open phase)) 
         (:close-open phase)) 
      1.0)))

;; The series — Sequential encoding, left to right
(sequential
  (phase-thought valley-1)
  (phase-thought transition-up-1)
  (phase-thought peak-1)
  (phase-thought transition-down-1)
  (phase-thought valley-2)
  ...)
```

The phase series scalars from 044 map directly:
- **valley-to-valley trend** — are the valleys rising?
- **peak-to-peak trend** — are the peaks compressing?
- **transition duration trend** — are the moves getting shorter?
- **range trend** — are the swings expanding or contracting?

All relative. All from confirmed structure. Not from
conviction spikes.

## What this replaces

The conviction-based pivot detection from 045 (80th percentile
of conviction history) produced ~1 pivot per 1000 candles.
Too sparse. Too trigger-happy on individual high-conviction
candles rather than structural turns.

The phase labeler produces structural phases — valleys, peaks,
and transitions confirmed by price reversal exceeding a
smoothing threshold. The phases are ZONES, not candles. They
have duration, range, volume. The pivot tracker program (047)
stays — the program pattern is right. The DETECTION inside it
changes from conviction-threshold to price-structure.

## Questions for strategy designers (Seykota, Van Tharp, Wyckoff)

1. **The smoothing parameter:** ATR-based (breathes with
   market), fixed percentage, or adaptive (percentile of
   recent swings)? How many ATRs? What percentage?

2. **Peak/valley zone definition:** how close to the confirmed
   extreme does the price need to be to still count as "in the
   zone" vs having transitioned? Is the zone the smoothing
   distance? Half of it?

3. **What attributes of each phase matter most?** Duration,
   range, volume, the move (open to close of phase), the
   speed (move / duration)? What else does a trader see in
   each phase?

4. **The transition's character:** a slow grind up vs a sharp
   spike up are both transitions. What atoms distinguish them?
   Speed? Volume profile? Internal retracements?

## Questions for architecture designers (Hickey, Beckman)

5. **Where does the labeler live?** Indicator bank (one per
   asset, on the Candle), pivot tracker program (replaces
   conviction detection), or standalone?

6. **The smoothing state:** the labeler needs memory (running
   extreme, current phase, confirmed history). Is this
   indicator-bank state (like RSI's accumulator) or is it
   richer than a streaming indicator?
