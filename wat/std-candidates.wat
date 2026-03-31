;; ── std-candidates.wat — forms proving themselves in userland ────────
;;
;; These are defined here as application helpers. If they prove generic
;; across domains (trading, DDoS, MTG), they earn promotion to the
;; wat stdlib via /propose structural.
;;
;; The designers see working code, not aspirational proposals.

(require core/primitives)
(require core/structural)

;; ── Fact constructors (22 phantom runes dissolved if promoted) ──────
;;
;; The bridge between domain vocabulary and the vector algebra.
;; Any wat program that encodes named knowledge uses these four patterns.

(define (fact/zone indicator zone)
  "This indicator is in this state."
  (bind (atom "at") (bind (atom indicator) (atom zone))))

(define (fact/comparison predicate a b)
  "A is above/below/crossing B."
  (bind (atom predicate) (bind (atom a) (atom b))))

(define (fact/scalar indicator value scale)
  "This indicator has this continuous value."
  (bind (atom indicator) (encode-linear value scale)))

(define (fact/bare label)
  "This named condition is present."
  (atom label))

;; ── Statistics (9 phantom runes dissolved if promoted) ──────────────
;;
;; Standard statistical functions over numeric lists.
;; Any program analyzing distributions needs these.

(define (mean xs)
  (if (empty? xs) 0.0
      (/ (fold + 0.0 xs) (len xs))))

(define (variance xs)
  (let ((m (mean xs)))
    (/ (fold (lambda (sum x) (+ sum (* (- x m) (- x m)))) 0.0 xs)
       (len xs))))

(define (stddev xs)
  (sqrt (variance xs)))

(define (skewness xs)
  (let ((m (mean xs))
        (s (stddev xs)))
    (if (<= s 0.0) 0.0
        (/ (fold (lambda (sum x) (+ sum (* (/ (- x m) s) (/ (- x m) s) (/ (- x m) s))))
                 0.0 xs)
           (len xs)))))

;; ── Collection gaps (1 phantom rune dissolved if promoted) ──────────

;; rune:forge(coupling) — zero-vector needs dims because vectors are fixed-dimensionality.
;; (bundle) alone cannot know the size. The Rust creates vec![0.0; dims].
(define (zero-vector dims)
  "The identity element of bundle. dims zeros."
  (list-fill dims 0.0))

;; ── Host language gaps (5 phantom runes) ────────────────────────────
;;
;; These should go in LANGUAGE.md's host section, not stdlib.
;; Tracked here until the next language update.

;; when-let: bind + conditional in one form
;; some?: does any element satisfy the predicate?
;; sort-by: sort with a key function
;; unzip: split list of pairs into pair of lists
;; member?: is this element in the list?

;; ── Questions for designers ──────────────────────────────────────────
;;
;; 1. Should (bundle) with no args be a lazy identity that adopts the
;;    dimensionality of the next bundle call? Currently zero-vector
;;    requires dims because vectors are fixed-size. But if the identity
;;    is lazy, zero-vector becomes (bundle) and dims is unnecessary.
;;    This is an algebra question: does the monoid identity know its size?
;;
;; 2. Fact constructors take bare strings where the domain has distinct
;;    concepts (indicator vs zone, predicate vs operand). Should wat
;;    have tagged strings or newtypes to distinguish them? Or is the
;;    docstring sufficient guard for a specification language?

;; ── Pending promotion inventory ─────────────────────────────────────
;;
;; | Form | Runes dissolved | Generic? | Status |
;; |------|----------------|----------|--------|
;; | fact/zone | 10 | Yes — DDoS, MTG, any domain | Defined above |
;; | fact/scalar | 6 | Yes | Defined above |
;; | fact/comparison | 4 | Yes | Defined above |
;; | fact/bare | 2 | Yes | Defined above |
;; | mean | 3 | Yes — any statistics | Defined above |
;; | stddev | 3 | Yes | Defined above |
;; | variance | 2 | Yes | Defined above |
;; | skewness | 1 | Probably | Defined above |
;; | zero-vector | 1 | Yes — identity element | Defined above |
;; | when-let | 1 | Yes — host gap | Host language |
;; | some? | 1 | Yes — host gap | Host language |
;; | sort-by | 1 | Yes — host gap | Host language |
;; | member? | 1 | Yes — host gap | Host language |
;; | unzip | 1 | Maybe | Host language |
;; |------|----------------|----------|--------|
;; | TOTAL | ~38 | | |
;;
;; Remaining ~102 phantoms are application vocabulary:
;; - expert, module (enterprise structure)
;; - drawdown, win-rate, streak-value (portfolio domain)
;; - sma, ema, wilder-*, roc (candle indicators)
;; - cache-get, vocab-get (thought encoder internals)
;; These stay as application defines. They do NOT earn stdlib.
