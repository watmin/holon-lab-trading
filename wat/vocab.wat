;; ── vocab.wat — the contract for thought vocabulary modules ──────
;;
;; Data in. Data out. The module doesn't know about vectors.
;; The encoder doesn't know about indicators. Fact is the interface.
;;
;; Linux kernel: modules register through a defined interface.
;; The kernel renders. The module computes. No wrappers.
;;
;; Clojure core: functions compose through data.
;; (-> candles eval-regime encode-facts). Pure pipeline.
;;
;; The wat machine follows both: vocab modules are pure functions
;; that return named facts as data. The encoder turns data into
;; geometry. The module never touches a vector. The encoder never
;; computes an indicator.

;; ── The Fact ────────────────────────────────────────────────────
;;
;; A Fact is what a vocab module says about a candle window.
;; Four kinds. Each maps to one encoding pattern.

;; Zone: "this indicator is in this state"
;; (at indicator zone)
;; Example: (at dfa-alpha persistent-dfa)
;; Encoding: bind(at, bind(indicator-atom, zone-atom))
(deftype Zone [indicator zone])

;; Comparison: "A is above/below B"
;; (above A B) or (below A B)
;; Example: (above close tenkan-sen)
;; Encoding: bind(pred-atom, bind(a-atom, b-atom))
(deftype Comparison [predicate a b])

;; Scalar: "this indicator has this continuous value"
;; (indicator value)
;; Example: (williams-r -45.2)
;; Encoding: bind(indicator-atom, encode-linear(value, scale))
(deftype Scalar [indicator value scale])

;; Bare: "this named condition is present"
;; (condition)
;; Example: (roc-accelerating)
;; Encoding: atom lookup — the condition IS the vector
(deftype Bare [label])

;; ── The Contract ────────────────────────────────────────────────
;;
;; A vocab module is a pure function:
;;   (fn [candles] -> [Fact])
;;
;; It takes a window of candle data.
;; It returns a list of facts.
;; It has no side effects.
;; It does not import holon.
;; It does not create vectors.
;; It does not know about the encoder.
;;
;; The encoder has ONE render method:
;;   (fn [facts] -> [Vector])
;;
;; It takes facts from any module.
;; It turns them into bound vectors via the algebra.
;; It does not know what the facts mean.
;; It does not compute indicators.
;;
;; Adding a new module:
;;   1. Write eval_foo(candles) -> Vec<Fact>
;;   2. Add one line to the profile dispatch
;;   3. The encoder never changes

;; ── Expert profiles ─────────────────────────────────────────────
;;
;; Each expert is a list of modules. The dispatch calls each module
;; and pipes the facts through the encoder. The expert doesn't know
;; how encoding works. The encoder doesn't know which expert called.
;;
;; (defprofile "momentum"
;;   [eval-oscillators eval-momentum eval-divergence])
;;
;; (defprofile "regime"
;;   [eval-regime eval-persistence])
;;
;; (defprofile "structure"
;;   [eval-ichimoku eval-fibonacci eval-keltner])
;;
;; The profile IS the expert's vocabulary.
;; The vocabulary IS the program.
;; The curve judges the program.

;; ── Why this matters ────────────────────────────────────────────
;;
;; When a new thought arrives — "I want a microstructure expert" —
;; the answer is:
;;   1. Create vocab/microstructure.rs
;;   2. fn eval_microstructure(candles) -> Vec<Fact>
;;   3. Add one line to the profile dispatch
;;
;; No wrapper. No boilerplate. No touching the encoder.
;; The environment invites good thoughts by making them cheap.
;;
;; "I'd rather have more things hanging nice, straight down,
;;  not twisted together, than just a couple of things tied
;;  in a knot." — Rich Hickey
