;; ── regime expert ──────────────────────────────────────────────────
;;
;; Thinks about: what KIND of market this is, not which direction.
;; Window: sampled from [12, 2016] per candle.
;;
;; (require stdlib)               ; comparisons, zones
;; (require mod/persistence)      ; DFA, Hurst, autocorrelation, ADX, regime transitions
;; (require mod/complexity)       ; entropy, fractal dim, spectral slope, G-R, Lyapunov
;; (require mod/microstructure)   ; choppiness, aroon, DeMark, KAMA-ER, vortex, mass index
;;
;; The regime expert is the most abstract. It doesn't see prices or
;; crosses. It sees PROPERTIES of the price series: "is this market
;; trending or mean-reverting? Orderly or chaotic? Persistent or
;; random?" These characterizations survive window noise better
;; than candle-level patterns.

;; ── Eval methods ────────────────────────────────────────────────────
;; eval_advanced — the ONLY method, but it produces many facts:
;;   - KAMA efficiency ratio → efficient-trend / inefficient-chop
;;   - Choppiness index → chop-trending / chop-choppy / chop-extreme
;;   - DFA alpha → persistent-dfa / anti-persistent-dfa / random-walk-dfa
;;   - Variance ratio → vr-momentum / vr-mean-revert / vr-neutral
;;   - DeMark TD count → td-exhausted / td-mature / td-building / td-inactive
;;   - Aroon → aroon-strong-up / aroon-strong-down / aroon-consolidating
;;   - Fractal dimension → trending-geometry / random-walk / mean-reverting
;;   - Gutenberg-Richter b-value → heavy-tails / light-tails
;;   - Entropy rate → low-entropy / high-entropy
;;   - Spectral slope (quantitative, not zoned)

;; ── Example thoughts ────────────────────────────────────────────────
;;
;; (bundle
;;   (bind at (bind dfa-alpha persistent-dfa))           ; market is trending
;;   (bind at (bind entropy-rate low-entropy-rate))      ; low randomness
;;   (bind at (bind fractal-dim trending-geometry))      ; geometric trend structure
;;   (bind at (bind variance-ratio vr-momentum))         ; momentum regime
;;   (bind at (bind chop chop-trending))                 ; not choppy
;;   (bind at (bind aroon-up aroon-strong-up))           ; aroon says strong uptrend
;;   (bind at (bind td-count td-mature))                 ; DeMark count is mature
;;   (bind at (bind gr-bvalue heavy-tails))              ; extreme moves likely
;;   ...)

;; ── WHY REGIME SURVIVED THE GATES ──────────────────────────────────
;;
;; In the 100k gated run, regime appeared in 4 of 8 gate configurations.
;; Momentum appeared in 7 of 8 but was often paired with others.
;; Regime's vocabulary describes market CHARACTER, not direction.
;; "Is this trending?" doesn't depend on which 48 candles you see —
;; DFA alpha, entropy, fractal dimension measure SERIES PROPERTIES
;; that are more stable across window sizes.
;;
;; The other experts' vocabularies — "close above SMA50," "RSI
;; overbought" — are specific to the candle values in the window.
;; Different sampled windows give different values. Regime's facts
;; are about the NATURE of the sequence, not the values at specific
;; positions. This abstraction is more robust to window noise.

;; ── DISCOVERY ───────────────────────────────────────────────────────
;;
;; 1. Regime shares eval_advanced with momentum and structure.
;;    All three experts see DFA, entropy, fractal dim, etc.
;;    This means the manager sees these regime indicators through
;;    THREE different experts' signed convictions. If regime is the
;;    expert whose VOCABULARY is most aligned with these indicators,
;;    it should OWN them exclusively. Momentum and structure have
;;    their own primary vocabularies — they don't need regime facts.
;;
;; 2. Regime has NO comparisons, NO segments, NO calendar, NO volume.
;;    It's the purest abstract characterization. This purity may be
;;    WHY it's the most gate-stable expert. No window-dependent noise.
;;
;; 3. Should regime get additional abstract properties?
;;    - Autocorrelation of returns (available in holon as autocorrelate)
;;    - Hurst exponent (related to DFA but different computation)
;;    - Market microstructure: bid-ask proxy from wick analysis?
;;    - Correlation with traditional markets (if available)

;; ── What regime does NOT see ────────────────────────────────────────
;; - Comparisons (momentum, structure)
;; - PELT segments (narrative, structure)
;; - Temporal crosses (narrative, momentum)
;; - Oscillators: RSI, stochastic, CCI (momentum)
;; - Cloud / fibonacci / keltner (structure)
;; - Volume (volume)
;; - Calendar (narrative)
;; - Range position (structure)
