;; ── mod/complexity — information-theoretic and geometric measures ────
;;
;; Used by: regime expert
;; Produces: market character facts
;;
;; How chaotic, structured, or predictable is the current price series?

;; ── Currently implemented ───────────────────────────────────────────

(atom "entropy-rate")
(atom "low-entropy-rate")     ; ordered, predictable
(atom "high-entropy-rate")    ; chaotic, unpredictable

(atom "fractal-dim")
(atom "trending-geometry")    ; FD < 1.4 — smooth trends
(atom "random-walk-geometry") ; FD ≈ 1.5 — brownian motion
(atom "mean-reverting-geometry") ; FD > 1.6 — rough, choppy

(atom "gr-bvalue")            ; Gutenberg-Richter b-value
(atom "heavy-tails")          ; small b → extreme moves likely
(atom "light-tails")          ; large b → extreme moves rare

(atom "spectral-slope")       ; frequency domain structure

;; ── NOT YET IMPLEMENTED ─────────────────────────────────────────────

;; Sample Entropy (SampEn) — regularity of the time series
;; Low SampEn = regular/predictable. High SampEn = complex/random.
;; More robust than approximate entropy for short series.
(atom "sample-entropy")
(atom "regular-series")       ; SampEn < 0.5
(atom "complex-series")       ; SampEn > 1.5
;; Facts: zone facts + continuous encoding

;; Permutation Entropy — order statistics of consecutive values
;; Captures the "shape" of local price patterns.
;; Fast to compute, robust to outliers.
(atom "perm-entropy")
(atom "ordered-patterns")     ; low permutation entropy
(atom "random-patterns")      ; high permutation entropy

;; Lyapunov Exponent (estimated) — sensitivity to initial conditions
;; Positive = chaotic. Negative = stable. Near zero = edge of chaos.
(atom "lyapunov")
(atom "chaotic-dynamics")
(atom "stable-dynamics")
(atom "edge-of-chaos")

;; Recurrence Rate — how often the price revisits previous states
;; High recurrence = ranging/consolidating. Low = trending.
(atom "recurrence-rate")
(atom "revisiting")           ; price keeps coming back
(atom "departing")            ; price moving to new territory

;; ── Encoding rule ───────────────────────────────────────────────────
;; All continuous in [0, ~3]. Encode-linear scale=1.0 after normalization.
;; Zone facts: binary atoms from threshold classification.
