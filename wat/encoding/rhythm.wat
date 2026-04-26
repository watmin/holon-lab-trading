;; wat/encoding/rhythm.wat — Phase 3.4 (2026-04-22).
;;
;; Port of archived/pre-wat-native/src/encoding/rhythm.rs. One
;; function per indicator, produces a rhythm AST: a Bundle of
;; bigram-pairs of trigrams over holons derived from the candle
;; window. Each fact carries both the value (Thermometer) and the
;; delta-from-previous (Bundle'd with an Atom("delta") bind).
;;
;; Archive flow:
;;   1. Trim values to last (sqrt(dims) + 3) to cap AST size.
;;   2. For each value: Thermometer(value, vmin, vmax); for i>0
;;      also Bundle with Bind(Atom("delta"), Thermometer(delta,
;;      -delta-range, delta-range)).
;;   3. Trigrams — sliding window of 3 holons, Bind-chain with
;;      Permute for positional identity:
;;        Bind(Bind(f0, Permute(f1, 1)), Permute(f2, 2))
;;   4. Bigram-pairs — sliding window of 2 trigrams, Bind.
;;   5. Trim pairs to budget = sqrt(dims).
;;   6. Bundle(pairs), Bind with Atom(name).
;;
;; Returns Result — Bundle fires :error capacity on overflow. Since
;; step 5 trims to budget, success is the norm; callers still match.
;; Empty-window returns Ok of empty Bundle (the archive's fallback
;; for <4 values).
;;
;; Budget derives from committed dims at runtime:
;;   (:wat::core::f64::to-i64 (:wat::holon::sqrt-dims)) ... except
;; sqrt-dims isn't a form. We derive via fl(sqrt(dims-as-f64)).

;; Budget helper — sqrt(dims) floored to i64.
(:wat::core::define
  (:trading::encoding::rhythm::budget -> :i64)
  (:wat::core::match
    (:wat::core::f64::to-i64
      (:wat::core::* 1.0
        (:wat::core::i64::to-f64 (:wat::config::dims))))
    -> :i64
    ;; f64::to-i64 returns Option; on Some use it, on None fall back
    ;; (unreachable at any reasonable dims).
    ((Some n) (:trading::encoding::rhythm::isqrt n))
    (:None 32)))

;; Integer sqrt via Newton's method — keeps dependency to just
;; i64 arithmetic (no f64::sqrt primitive in wat). Called rarely
;; (once per indicator_rhythm call); small cost.
(:wat::core::define
  (:trading::encoding::rhythm::isqrt (n :i64) -> :i64)
  (:wat::core::if (:wat::core::<= n 1) -> :i64
    n
    (:trading::encoding::rhythm::isqrt-loop n (:wat::core::/ n 2))))

(:wat::core::define
  (:trading::encoding::rhythm::isqrt-loop (n :i64) (x :i64) -> :i64)
  (:wat::core::let*
    (((x-next :i64)
      (:wat::core::/
        (:wat::core::+ x (:wat::core::/ n x))
        2)))
    (:wat::core::if (:wat::core::>= x-next x) -> :i64
      x
      (:trading::encoding::rhythm::isqrt-loop n x-next))))

;; ─── build a single fact at index i ────────────────────────────

(:wat::core::define
  (:trading::encoding::rhythm::value-fact
    (value :f64)
    (vmin :f64)
    (vmax :f64)
    -> :wat::holon::HolonAST)
  (:wat::holon::Thermometer value vmin vmax))

(:wat::core::define
  (:trading::encoding::rhythm::delta-fact
    (value :f64)
    (prev :f64)
    (delta-range :f64)
    -> :wat::holon::BundleResult)
  (:wat::core::let*
    (((delta :f64) (:wat::core::- value prev))
     ((neg-range :f64) (:wat::core::- 0.0 delta-range)))
    (Ok
      (:wat::holon::Bind
        (:wat::holon::Atom "delta")
        (:wat::holon::Thermometer delta neg-range delta-range)))))

;; Build the fact at index i. i==0: just the Thermometer. i>0:
;; Bundle of (value-fact, delta-fact). Returns Result because
;; Bundle does.
(:wat::core::define
  (:trading::encoding::rhythm::build-fact
    (i :i64)
    (values :Vec<f64>)
    (vmin :f64)
    (vmax :f64)
    (delta-range :f64)
    -> :wat::holon::BundleResult)
  (:wat::core::let*
    (((value :f64)
      (:wat::core::match (:wat::core::get values i) -> :f64
        ((Some v) v)
        (:None    0.0)))
     ((v-fact :wat::holon::HolonAST)
      (:trading::encoding::rhythm::value-fact value vmin vmax)))
    (:wat::core::if (:wat::core::= i 0)
                    -> :wat::holon::BundleResult
      (Ok v-fact)
      (:wat::core::let*
        (((prev :f64)
          (:wat::core::match
            (:wat::core::get values (:wat::core::- i 1)) -> :f64
            ((Some v) v)
            (:None    0.0)))
         ((d-fact :wat::holon::BundleResult)
          (:trading::encoding::rhythm::delta-fact value prev delta-range))
         ((d-holon :wat::holon::HolonAST)
          (:wat::core::try d-fact)))
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST v-fact d-holon))))))

;; ─── build-holons: map over all indices ─────────────────────────

(:wat::core::define
  (:trading::encoding::rhythm::build-holons
    (values :Vec<f64>)
    (vmin :f64)
    (vmax :f64)
    (delta-range :f64)
    -> :Result<wat::holon::Holons,wat::holon::CapacityExceeded>)
  (:trading::encoding::rhythm::build-holons-loop
    values vmin vmax delta-range 0
    (:wat::core::length values)
    (:wat::core::vec :wat::holon::HolonAST)))

(:wat::core::define
  (:trading::encoding::rhythm::build-holons-loop
    (values :Vec<f64>)
    (vmin :f64)
    (vmax :f64)
    (delta-range :f64)
    (i :i64)
    (n :i64)
    (acc :wat::holon::Holons)
    -> :Result<wat::holon::Holons,wat::holon::CapacityExceeded>)
  (:wat::core::if (:wat::core::>= i n)
                  -> :Result<wat::holon::Holons,wat::holon::CapacityExceeded>
    (Ok acc)
    (:wat::core::let*
      (((f :wat::holon::HolonAST)
        (:wat::core::try
          (:trading::encoding::rhythm::build-fact
            i values vmin vmax delta-range))))
      (:trading::encoding::rhythm::build-holons-loop
        values vmin vmax delta-range
        (:wat::core::+ i 1) n
        (:wat::core::conj acc f)))))

;; ─── build-trigrams: sliding window of 3 holons ─────────────────

(:wat::core::define
  (:trading::encoding::rhythm::build-trigrams
    (holons :wat::holon::Holons)
    -> :wat::holon::Holons)
  (:wat::core::let*
    (((n :i64) (:wat::core::length holons))
     ((last-start :i64) (:wat::core::- n 3)))
    (:wat::core::if (:wat::core::< last-start 0) -> :wat::holon::Holons
      (:wat::core::vec :wat::holon::HolonAST)
      (:trading::encoding::rhythm::build-trigrams-loop
        holons 0 last-start
        (:wat::core::vec :wat::holon::HolonAST)))))

(:wat::core::define
  (:trading::encoding::rhythm::build-trigrams-loop
    (holons :wat::holon::Holons)
    (i :i64)
    (last-start :i64)
    (acc :wat::holon::Holons)
    -> :wat::holon::Holons)
  (:wat::core::if (:wat::core::> i last-start) -> :wat::holon::Holons
    acc
    (:wat::core::let*
      (((f0 :wat::holon::HolonAST)
        (:wat::core::match (:wat::core::get holons i) -> :wat::holon::HolonAST
          ((Some h) h)
          (:None    (:wat::holon::Atom "unreachable"))))
       ((f1 :wat::holon::HolonAST)
        (:wat::core::match (:wat::core::get holons (:wat::core::+ i 1))
                           -> :wat::holon::HolonAST
          ((Some h) h)
          (:None    (:wat::holon::Atom "unreachable"))))
       ((f2 :wat::holon::HolonAST)
        (:wat::core::match (:wat::core::get holons (:wat::core::+ i 2))
                           -> :wat::holon::HolonAST
          ((Some h) h)
          (:None    (:wat::holon::Atom "unreachable"))))
       ((trigram :wat::holon::HolonAST)
        (:wat::holon::Bind
          (:wat::holon::Bind f0 (:wat::holon::Permute f1 1))
          (:wat::holon::Permute f2 2))))
      (:trading::encoding::rhythm::build-trigrams-loop
        holons (:wat::core::+ i 1) last-start
        (:wat::core::conj acc trigram)))))

;; ─── build-pairs: sliding window of 2 trigrams ─────────────────

(:wat::core::define
  (:trading::encoding::rhythm::build-pairs
    (trigrams :wat::holon::Holons)
    -> :wat::holon::Holons)
  (:wat::core::let*
    (((n :i64) (:wat::core::length trigrams))
     ((last-start :i64) (:wat::core::- n 2)))
    (:wat::core::if (:wat::core::< last-start 0) -> :wat::holon::Holons
      (:wat::core::vec :wat::holon::HolonAST)
      (:trading::encoding::rhythm::build-pairs-loop
        trigrams 0 last-start
        (:wat::core::vec :wat::holon::HolonAST)))))

(:wat::core::define
  (:trading::encoding::rhythm::build-pairs-loop
    (trigrams :wat::holon::Holons)
    (i :i64)
    (last-start :i64)
    (acc :wat::holon::Holons)
    -> :wat::holon::Holons)
  (:wat::core::if (:wat::core::> i last-start) -> :wat::holon::Holons
    acc
    (:wat::core::let*
      (((t0 :wat::holon::HolonAST)
        (:wat::core::match (:wat::core::get trigrams i) -> :wat::holon::HolonAST
          ((Some h) h)
          (:None    (:wat::holon::Atom "unreachable"))))
       ((t1 :wat::holon::HolonAST)
        (:wat::core::match (:wat::core::get trigrams (:wat::core::+ i 1))
                           -> :wat::holon::HolonAST
          ((Some h) h)
          (:None    (:wat::holon::Atom "unreachable"))))
       ((pair :wat::holon::HolonAST) (:wat::holon::Bind t0 t1)))
      (:trading::encoding::rhythm::build-pairs-loop
        trigrams (:wat::core::+ i 1) last-start
        (:wat::core::conj acc pair)))))

;; ─── trim-tail: keep last N items of a Vec ─────────────────────

(:wat::core::define
  (:trading::encoding::rhythm::trim-tail<T>
    (xs :Vec<T>)
    (n :i64)
    -> :Vec<T>)
  (:wat::core::let*
    (((len :i64) (:wat::core::length xs)))
    (:wat::core::if (:wat::core::<= len n) -> :Vec<T>
      xs
      (:wat::core::drop xs (:wat::core::- len n)))))

;; ─── indicator-rhythm: the orchestrator ────────────────────────

(:wat::core::define
  (:trading::encoding::rhythm::indicator-rhythm
    (name :String)
    (values :Vec<f64>)
    (vmin :f64)
    (vmax :f64)
    (delta-range :f64)
    -> :wat::holon::BundleResult)
  (:wat::core::let*
    (((budget :i64) (:trading::encoding::rhythm::budget))
     ((max-holons :i64) (:wat::core::+ budget 3))
     ;; Step 1: trim input to cap AST size
     ((trimmed :Vec<f64>)
      (:trading::encoding::rhythm::trim-tail values max-holons))
     ((len :i64) (:wat::core::length trimmed)))
    (:wat::core::if (:wat::core::< len 4)
                    -> :wat::holon::BundleResult
      ;; Short-window fallback. Per arc 057's quote-all-the-way-down,
      ;; `(quote ())` lowers to an empty Bundle (algebra's identity
      ;; element = zero vector) which dies under Bind composition. Use
      ;; a named keyword sentinel instead — Symbol leaf has its own
      ;; identity vector and composes cleanly under Bind.
      (:wat::core::let*
        (((empty-bundle :wat::holon::HolonAST)
          (:wat::core::try
            (:wat::holon::Bundle
              (:wat::core::vec :wat::holon::HolonAST
                (:wat::holon::Atom (:wat::core::quote :short-window-sentinel)))))))
        (Ok
          (:wat::holon::Bind (:wat::holon::Atom name) empty-bundle)))
      ;; Normal path: holons → trigrams → pairs → bundle
      (:wat::core::let*
        (((holons :wat::holon::Holons)
          (:wat::core::try
            (:trading::encoding::rhythm::build-holons
              trimmed vmin vmax delta-range)))
         ((trigrams :wat::holon::Holons)
          (:trading::encoding::rhythm::build-trigrams holons))
         ((pairs :wat::holon::Holons)
          (:trading::encoding::rhythm::build-pairs trigrams))
         ((budget-trimmed :wat::holon::Holons)
          (:trading::encoding::rhythm::trim-tail pairs budget))
         ((raw :wat::holon::HolonAST)
          (:wat::core::try
            (:wat::holon::Bundle budget-trimmed))))
        (Ok
          (:wat::holon::Bind (:wat::holon::Atom name) raw))))))
