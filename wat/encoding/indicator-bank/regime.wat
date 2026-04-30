;; wat/encoding/indicator-bank/regime.wat — Regime classifiers.
;;
;; Lab arc 026 slice 10 (2026-04-25). Direct port of archive's
;; regime indicator family:
;;   - kama_efficiency_ratio (line 990-1005)
;;   - choppiness_index      (line 1007-1017)
;;   - dfa_alpha             (line 902-922)
;;   - variance_ratio        (line 933-966)
;;   - entropy_rate          (line 968-987 + step_entropy 1579-1597)
;;   - aroon_up / aroon_down (line 1019-1050)
;;   - fractal_dimension     (line 1052-1066) + higuchi_length (1068-1092)
;;
;; **Biggest single slice in the arc** (~600 LOC including tests).
;; Eight indicators, several with statistical-estimator algorithms.
;; Internal helpers: linear-detrend, dfa-fluctuation, higuchi-length,
;; compute-entropy-bin (used by IndicatorBank's per-tick step).
;;
;; Substrate uplifts consumed: `:wat::std::stat::*` (mean, variance,
;; stddev — all shipped in service of this slice + slice 9), `sqrt`,
;; `ln`, polymorphic arithmetic. No new uplifts surfaced.
;;
;; All compute-* functions are pure — no state structs. The
;; IndicatorBank holds the relevant RingBuffers and feeds .values
;; into these per tick.
;;
;; Explicit:
;;   :trading::encoding::compute-kama-er         :Vec<f64> -> :wat::core::f64
;;   :trading::encoding::compute-choppiness      :wat::core::f64 :RingBuffer :RingBuffer -> :wat::core::f64
;;   :trading::encoding::compute-dfa-alpha       :Vec<f64> -> :wat::core::f64
;;   :trading::encoding::compute-variance-ratio  :Vec<f64> -> :wat::core::f64
;;   :trading::encoding::compute-entropy-rate    :Vec<f64> -> :wat::core::f64
;;   :trading::encoding::compute-entropy-bin     :wat::core::f64 -> :wat::core::f64
;;   :trading::encoding::compute-aroon-up        :Vec<f64> -> :wat::core::f64
;;   :trading::encoding::compute-aroon-down      :Vec<f64> -> :wat::core::f64
;;   :trading::encoding::compute-fractal-dim     :Vec<f64> -> :wat::core::f64

(:wat::load-file! "primitives.wat")
(:wat::load-file! "persistence.wat")    ;; for cum-deviations


;; ─── KAMA Efficiency Ratio ────────────────────────────────────────
;;
;; |last - first| / sum(|consecutive diffs|). Range [0, 1]; 1 = pure
;; trend, 0 = pure noise. Returns 0.5 on under-2 input, 1.0 on zero
;; volatility (matches archive).

(:wat::core::define
  (:trading::encoding::compute-kama-er
    (closes :Vec<f64>)
    -> :wat::core::f64)
  (:wat::core::let*
    (((n :wat::core::i64) (:wat::core::length closes)))
    (:wat::core::if (:wat::core::< n 2) -> :wat::core::f64
      0.5
      (:wat::core::let*
        (((first :wat::core::f64)
          (:wat::core::match (:wat::core::get closes 0) -> :wat::core::f64
            ((Some v) v) (:None 0.0)))
         ((last :wat::core::f64)
          (:wat::core::match
            (:wat::core::get closes (:wat::core::- n 1)) -> :wat::core::f64
            ((Some v) v) (:None 0.0)))
         ((direction :wat::core::f64) (:wat::core::f64::abs (:wat::core::- last first)))
         ;; Sum of consecutive |diffs| via foldl over (i: 0..n-1).
         ((volatility :wat::core::f64)
          (:wat::core::foldl
            (:wat::core::range 0 (:wat::core::- n 1))
            0.0
            (:wat::core::lambda ((acc :wat::core::f64) (i :wat::core::i64) -> :wat::core::f64)
              (:wat::core::let*
                (((a :wat::core::f64)
                  (:wat::core::match (:wat::core::get closes i) -> :wat::core::f64
                    ((Some v) v) (:None 0.0)))
                 ((b :wat::core::f64)
                  (:wat::core::match
                    (:wat::core::get closes (:wat::core::+ i 1)) -> :wat::core::f64
                    ((Some v) v) (:None 0.0))))
                (:wat::core::+ acc
                  (:wat::core::f64::abs (:wat::core::- b a))))))))
        (:wat::core::if (:wat::core::= volatility 0.0) -> :wat::core::f64
          1.0
          (:wat::core::/ direction volatility))))))


;; ─── Choppiness Index ────────────────────────────────────────────
;;
;; 100 · log10(atr_sum / range) / log10(N=14).
;; Note: archive uses ln then divides by ln(14) — equivalent to log10
;; (the base cancels). Returns 50.0 on degenerate cases.

(:wat::core::define
  (:trading::encoding::compute-choppiness
    (atr-sum :wat::core::f64)
    (high-buf :trading::encoding::RingBuffer)
    (low-buf :trading::encoding::RingBuffer)
    -> :wat::core::f64)
  (:wat::core::let*
    (((highest :wat::core::f64)
      (:wat::core::match
        (:trading::encoding::RingBuffer::max high-buf) -> :wat::core::f64
        ((Some v) v) (:None 0.0)))
     ((lowest :wat::core::f64)
      (:wat::core::match
        (:trading::encoding::RingBuffer::min low-buf) -> :wat::core::f64
        ((Some v) v) (:None 0.0)))
     ((range-val :wat::core::f64) (:wat::core::- highest lowest)))
    (:wat::core::if (:wat::core::or
                      (:wat::core::= range-val 0.0)
                      (:wat::core::<= atr-sum 0.0)) -> :wat::core::f64
      50.0
      (:wat::core::/
        (:wat::core::* 100.0
          (:wat::std::math::ln (:wat::core::/ atr-sum range-val)))
        (:wat::std::math::ln 14.0)))))


;; ─── DFA — Detrended Fluctuation Analysis ────────────────────────

;; Subtract best-fit line from xs. Pure function over Vec<f64>.
(:wat::core::define
  (:trading::encoding::regime::linear-detrend
    (xs :Vec<f64>)
    -> :Vec<f64>)
  (:wat::core::let*
    (((n :wat::core::i64) (:wat::core::length xs)))
    (:wat::core::if (:wat::core::< n 2) -> :Vec<f64>
      xs
      (:wat::core::let*
        (((nf :wat::core::f64) (:wat::core::i64::to-f64 n))
         ((x-mean :wat::core::f64) (:wat::core::/ (:wat::core::- nf 1.0) 2.0))
         ((y-mean :wat::core::f64)
          (:wat::core::match (:wat::std::stat::mean xs) -> :wat::core::f64
            ((Some v) v) (:None 0.0)))
         ;; num + den via single foldl over indexed pairs.
         ((indexed :Vec<(i64,f64)>)
          (:wat::core::map
            (:wat::core::range 0 n)
            (:wat::core::lambda ((i :wat::core::i64) -> :(i64,f64))
              (:wat::core::tuple
                i
                (:wat::core::match (:wat::core::get xs i) -> :wat::core::f64
                  ((Some v) v) (:None 0.0))))))
         ((num+den :(f64,f64))
          (:wat::core::foldl indexed
            (:wat::core::tuple 0.0 0.0)
            (:wat::core::lambda
              ((acc :(f64,f64)) (pair :(i64,f64))
               -> :(f64,f64))
              (:wat::core::let*
                (((num :wat::core::f64) (:wat::core::first acc))
                 ((den :wat::core::f64) (:wat::core::second acc))
                 ((i :wat::core::i64) (:wat::core::first pair))
                 ((y :wat::core::f64) (:wat::core::second pair))
                 ((dx :wat::core::f64) (:wat::core::- (:wat::core::i64::to-f64 i) x-mean)))
                (:wat::core::tuple
                  (:wat::core::+ num (:wat::core::* dx (:wat::core::- y y-mean)))
                  (:wat::core::+ den (:wat::core::* dx dx)))))))
         ((num :wat::core::f64) (:wat::core::first num+den))
         ((den :wat::core::f64) (:wat::core::second num+den))
         ((slope :wat::core::f64)
          (:wat::core::if (:wat::core::= den 0.0) -> :wat::core::f64
            0.0
            (:wat::core::/ num den)))
         ((intercept :wat::core::f64) (:wat::core::- y-mean (:wat::core::* slope x-mean))))
        ;; Subtract best-fit line.
        (:wat::core::map indexed
          (:wat::core::lambda ((pair :(i64,f64)) -> :wat::core::f64)
            (:wat::core::let*
              (((i :wat::core::i64) (:wat::core::first pair))
               ((y :wat::core::f64) (:wat::core::second pair))
               ((fit :wat::core::f64)
                (:wat::core::+ intercept
                  (:wat::core::* slope (:wat::core::i64::to-f64 i)))))
              (:wat::core::- y fit))))))))


;; DFA fluctuation at given segment length. Iterate over segments,
;; detrend each, take variance, return sqrt(mean variance).
(:wat::core::define
  (:trading::encoding::regime::dfa-fluctuation
    (cum-dev :Vec<f64>)
    (seg-len :wat::core::i64)
    -> :wat::core::f64)
  (:wat::core::let*
    (((n :wat::core::i64) (:wat::core::length cum-dev))
     ((num-segs :wat::core::i64) (:wat::core::/ n seg-len)))
    (:wat::core::if (:wat::core::= num-segs 0) -> :wat::core::f64
      0.0
      (:wat::core::let*
        (;; Per-segment variances. Build via map over segment indices.
         ((variances :Vec<f64>)
          (:wat::core::map
            (:wat::core::range 0 num-segs)
            (:wat::core::lambda ((s :wat::core::i64) -> :wat::core::f64)
              (:wat::core::let*
                (((start :wat::core::i64) (:wat::core::* s seg-len))
                 ((segment :Vec<f64>)
                  (:wat::core::map
                    (:wat::core::range 0 seg-len)
                    (:wat::core::lambda ((i :wat::core::i64) -> :wat::core::f64)
                      (:wat::core::match
                        (:wat::core::get cum-dev (:wat::core::+ start i)) -> :wat::core::f64
                        ((Some v) v) (:None 0.0)))))
                 ((detrended :Vec<f64>)
                  (:trading::encoding::regime::linear-detrend segment)))
                (:wat::core::match
                  (:wat::std::stat::variance detrended) -> :wat::core::f64
                  ((Some v) v) (:None 0.0))))))
         ((mean-var :wat::core::f64)
          (:wat::core::match (:wat::std::stat::mean variances) -> :wat::core::f64
            ((Some v) v) (:None 0.0))))
        (:wat::std::math::sqrt mean-var)))))


;; DFA alpha exponent. ln(F(8)/F(4)) / ln(2). Returns 0.5 fallback.
(:wat::core::define
  (:trading::encoding::compute-dfa-alpha
    (closes :Vec<f64>)
    -> :wat::core::f64)
  (:wat::core::let*
    (((n :wat::core::i64) (:wat::core::length closes)))
    (:wat::core::if (:wat::core::< n 16) -> :wat::core::f64
      0.5
      (:wat::core::let*
        (((mu :wat::core::f64)
          (:wat::core::match (:wat::std::stat::mean closes) -> :wat::core::f64
            ((Some v) v) (:None 0.0)))
         ;; cum_dev with leading 0 (matches archive's push(0.0) before loop).
         ((cum-tail :Vec<f64>)
          (:trading::encoding::persistence::cum-deviations closes mu))
         ((cum-dev :Vec<f64>)
          (:wat::core::conj
            (:wat::core::vec :wat::core::f64 0.0)
            ;; Concat: prepend 0.0 by pushing onto a singleton, then folding.
            ;; Substrate has no concat; emulate via foldl.
            ;; Here: just pre-pend via foldl into a new vec.
            0.0))   ;; placeholder; replaced next line via foldl below
         ((cum-dev :Vec<f64>)
          (:wat::core::foldl cum-tail
            (:wat::core::vec :wat::core::f64 0.0)
            (:wat::core::lambda ((acc :Vec<f64>) (x :wat::core::f64) -> :Vec<f64>)
              (:wat::core::conj acc x))))
         ((f1 :wat::core::f64)
          (:trading::encoding::regime::dfa-fluctuation cum-dev 4))
         ((f2 :wat::core::f64)
          (:trading::encoding::regime::dfa-fluctuation cum-dev 8)))
        (:wat::core::if (:wat::core::or
                          (:wat::core::<= f1 0.0)
                          (:wat::core::<= f2 0.0)) -> :wat::core::f64
          0.5
          (:wat::core::/
            (:wat::std::math::ln (:wat::core::/ f2 f1))
            (:wat::std::math::ln 2.0)))))))


;; ─── Variance Ratio ──────────────────────────────────────────────
;;
;; var(5-step log returns) / (5 · var(1-step log returns)).
;; Returns 1.0 on degenerate / under-10 input.

(:wat::core::define
  (:trading::encoding::compute-variance-ratio
    (closes :Vec<f64>)
    -> :wat::core::f64)
  (:wat::core::let*
    (((n :wat::core::i64) (:wat::core::length closes)))
    (:wat::core::if (:wat::core::< n 10) -> :wat::core::f64
      1.0
      (:wat::core::let*
        (((returns-1 :Vec<f64>)
          (:wat::core::map
            (:wat::core::range 0 (:wat::core::- n 1))
            (:wat::core::lambda ((i :wat::core::i64) -> :wat::core::f64)
              (:wat::core::let*
                (((cur :wat::core::f64)
                  (:wat::core::match (:wat::core::get closes i) -> :wat::core::f64
                    ((Some v) v) (:None 0.0)))
                 ((nxt :wat::core::f64)
                  (:wat::core::match
                    (:wat::core::get closes (:wat::core::+ i 1)) -> :wat::core::f64
                    ((Some v) v) (:None 0.0))))
                (:wat::core::if (:wat::core::= cur 0.0) -> :wat::core::f64
                  0.0
                  (:wat::std::math::ln (:wat::core::/ nxt cur)))))))
         ((returns-5 :Vec<f64>)
          (:wat::core::map
            (:wat::core::range 0 (:wat::core::- n 5))
            (:wat::core::lambda ((i :wat::core::i64) -> :wat::core::f64)
              (:wat::core::let*
                (((cur :wat::core::f64)
                  (:wat::core::match (:wat::core::get closes i) -> :wat::core::f64
                    ((Some v) v) (:None 0.0)))
                 ((nxt :wat::core::f64)
                  (:wat::core::match
                    (:wat::core::get closes (:wat::core::+ i 5)) -> :wat::core::f64
                    ((Some v) v) (:None 0.0))))
                (:wat::core::if (:wat::core::= cur 0.0) -> :wat::core::f64
                  0.0
                  (:wat::std::math::ln (:wat::core::/ nxt cur)))))))
         ((var-1 :wat::core::f64)
          (:wat::core::match (:wat::std::stat::variance returns-1) -> :wat::core::f64
            ((Some v) v) (:None 0.0)))
         ((var-5 :wat::core::f64)
          (:wat::core::match (:wat::std::stat::variance returns-5) -> :wat::core::f64
            ((Some v) v) (:None 0.0))))
        (:wat::core::if (:wat::core::= var-1 0.0) -> :wat::core::f64
          1.0
          (:wat::core::/ var-5 (:wat::core::* 5.0 var-1)))))))


;; ─── Entropy ─────────────────────────────────────────────────────

;; Discretize a return into one of {-2, -1, 0, 1, 2}. Used at the
;; IndicatorBank's per-tick step to pre-discretize values pushed
;; into the entropy buffer.
(:wat::core::define
  (:trading::encoding::compute-entropy-bin
    (ret :wat::core::f64)
    -> :wat::core::f64)
  (:wat::core::if (:wat::core::< ret -0.005) -> :wat::core::f64
    -2.0
    (:wat::core::if (:wat::core::< ret -0.001) -> :wat::core::f64
      -1.0
      (:wat::core::if (:wat::core::< ret 0.001) -> :wat::core::f64
        0.0
        (:wat::core::if (:wat::core::< ret 0.005) -> :wat::core::f64
          1.0
          2.0)))))


;; Entropy of discretized returns. Values are bin tags from
;; compute-entropy-bin; entropy = -sum(p · ln(p)) over the 5 bins.
(:wat::core::define
  (:trading::encoding::compute-entropy-rate
    (vals :Vec<f64>)
    -> :wat::core::f64)
  (:wat::core::let*
    (((n :wat::core::i64) (:wat::core::length vals)))
    (:wat::core::if (:wat::core::< n 5) -> :wat::core::f64
      1.0
      (:wat::core::let*
        (((nf :wat::core::f64) (:wat::core::i64::to-f64 n))
         ((bins :Vec<f64>) (:wat::core::vec :wat::core::f64 -2.0 -1.0 0.0 1.0 2.0)))
        (:wat::core::foldl bins
          0.0
          (:wat::core::lambda ((acc :wat::core::f64) (b :wat::core::f64) -> :wat::core::f64)
            (:wat::core::let*
              (((count :wat::core::i64)
                (:wat::core::length
                  (:wat::core::filter vals
                    (:wat::core::lambda ((v :wat::core::f64) -> :wat::core::bool)
                      (:wat::core::= v b)))))
               ((cf :wat::core::f64) (:wat::core::i64::to-f64 count)))
              (:wat::core::if (:wat::core::> cf 0.0) -> :wat::core::f64
                (:wat::core::let*
                  (((p :wat::core::f64) (:wat::core::/ cf nf)))
                  (:wat::core::- acc (:wat::core::* p (:wat::std::math::ln p))))
                acc))))))))


;; ─── Aroon ───────────────────────────────────────────────────────
;;
;; Aroon-up: 100 · index-of-max / (n-1).
;; Aroon-down: 100 · index-of-min / (n-1).
;; Returns 50.0 fallback on empty.
;;
;; Archive's "find most-recent index of max/min" iterates and
;; overwrites idx when v == max_val; effectively returns the last
;; (highest-index) match. Implemented here via foldl over enumerated
;; pairs that tracks (best-value, best-index) and updates on >= /
;; <= so later occurrences of equal extremes win the index.

(:wat::core::define
  (:trading::encoding::regime::index-of-last-extreme
    (xs :Vec<f64>)
    (predicate-better :fn(f64,f64)->bool)
    -> :wat::core::i64)
  (:wat::core::let*
    (((indexed :Vec<(i64,f64)>)
      (:wat::core::map
        (:wat::core::range 0 (:wat::core::length xs))
        (:wat::core::lambda ((i :wat::core::i64) -> :(i64,f64))
          (:wat::core::tuple
            i
            (:wat::core::match (:wat::core::get xs i) -> :wat::core::f64
              ((Some v) v) (:None 0.0))))))
     ((seed :(f64,i64))
      ;; Get first element; gated by callers (xs non-empty before call).
      (:wat::core::match (:wat::core::get xs 0) -> :(f64,i64)
        ((Some v) (:wat::core::tuple v 0))
        (:None (:wat::core::tuple 0.0 0))))
     ((result :(f64,i64))
      (:wat::core::foldl indexed seed
        (:wat::core::lambda
          ((acc :(f64,i64)) (pair :(i64,f64))
           -> :(f64,i64))
          (:wat::core::let*
            (((best :wat::core::f64) (:wat::core::first acc))
             ((i :wat::core::i64) (:wat::core::first pair))
             ((v :wat::core::f64) (:wat::core::second pair)))
            (:wat::core::if (predicate-better v best) -> :(f64,i64)
              (:wat::core::tuple v i)
              acc))))))
    (:wat::core::second result)))


(:wat::core::define
  (:trading::encoding::compute-aroon-up
    (vals :Vec<f64>)
    -> :wat::core::f64)
  (:wat::core::let*
    (((n :wat::core::i64) (:wat::core::length vals)))
    (:wat::core::if (:wat::core::= n 0) -> :wat::core::f64
      50.0
      (:wat::core::let*
        (((idx :wat::core::i64)
          (:trading::encoding::regime::index-of-last-extreme
            vals
            (:wat::core::lambda ((v :wat::core::f64) (best :wat::core::f64) -> :wat::core::bool)
              (:wat::core::>= v best))))
         ((denom :wat::core::i64)
          (:wat::core::if (:wat::core::> n 1) -> :wat::core::i64
            (:wat::core::- n 1)
            1)))
        (:wat::core::/
          (:wat::core::* 100.0 (:wat::core::i64::to-f64 idx))
          (:wat::core::i64::to-f64 denom))))))


(:wat::core::define
  (:trading::encoding::compute-aroon-down
    (vals :Vec<f64>)
    -> :wat::core::f64)
  (:wat::core::let*
    (((n :wat::core::i64) (:wat::core::length vals)))
    (:wat::core::if (:wat::core::= n 0) -> :wat::core::f64
      50.0
      (:wat::core::let*
        (((idx :wat::core::i64)
          (:trading::encoding::regime::index-of-last-extreme
            vals
            (:wat::core::lambda ((v :wat::core::f64) (best :wat::core::f64) -> :wat::core::bool)
              (:wat::core::<= v best))))
         ((denom :wat::core::i64)
          (:wat::core::if (:wat::core::> n 1) -> :wat::core::i64
            (:wat::core::- n 1)
            1)))
        (:wat::core::/
          (:wat::core::* 100.0 (:wat::core::i64::to-f64 idx))
          (:wat::core::i64::to-f64 denom))))))


;; ─── Fractal Dimension via Higuchi ────────────────────────────────

(:wat::core::define
  (:trading::encoding::regime::higuchi-length
    (prices :Vec<f64>)
    (k :wat::core::i64)
    -> :wat::core::f64)
  (:wat::core::let*
    (((n :wat::core::i64) (:wat::core::length prices)))
    (:wat::core::if (:wat::core::or
                      (:wat::core::= k 0)
                      (:wat::core::<= n k)) -> :wat::core::f64
      0.0
      (:wat::core::let*
        (;; For each m in 0..k, compute one segment length L_m.
         ((per-m-lengths :Vec<f64>)
          (:wat::core::map
            (:wat::core::range 0 k)
            (:wat::core::lambda ((m :wat::core::i64) -> :wat::core::f64)
              (:wat::core::let*
                (((num-steps :wat::core::i64)
                  (:wat::core::/
                    (:wat::core::- (:wat::core::- n 1) m)
                    k)))
                (:wat::core::if (:wat::core::= num-steps 0) -> :wat::core::f64
                  -1.0  ;; sentinel: skipped (matches archive's `continue`)
                  (:wat::core::let*
                    (((sum-diffs :wat::core::f64)
                      (:wat::core::foldl
                        (:wat::core::range 0 num-steps)
                        0.0
                        (:wat::core::lambda ((acc :wat::core::f64) (i :wat::core::i64) -> :wat::core::f64)
                          (:wat::core::let*
                            (((idx-a :wat::core::i64)
                              (:wat::core::+ m (:wat::core::* i k)))
                             ((idx-b :wat::core::i64)
                              (:wat::core::+ m (:wat::core::* (:wat::core::+ i 1) k)))
                             ((a :wat::core::f64)
                              (:wat::core::match (:wat::core::get prices idx-a) -> :wat::core::f64
                                ((Some v) v) (:None 0.0)))
                             ((b :wat::core::f64)
                              (:wat::core::match (:wat::core::get prices idx-b) -> :wat::core::f64
                                ((Some v) v) (:None 0.0))))
                            (:wat::core::+ acc
                              (:wat::core::f64::abs (:wat::core::- b a)))))))
                     ;; L = sum * (n-1) / (num-steps * k * k)
                     ((denom :wat::core::i64)
                      (:wat::core::* num-steps (:wat::core::* k k))))
                    (:wat::core::/
                      (:wat::core::* sum-diffs (:wat::core::i64::to-f64 (:wat::core::- n 1)))
                      (:wat::core::i64::to-f64 denom))))))))
         ;; Filter out -1.0 sentinels (segments where num-steps==0).
         ((kept :Vec<f64>)
          (:wat::core::filter per-m-lengths
            (:wat::core::lambda ((x :wat::core::f64) -> :wat::core::bool)
              (:wat::core::>= x 0.0)))))
        (:wat::core::match (:wat::std::stat::mean kept) -> :wat::core::f64
          ((Some v) v) (:None 0.0))))))


(:wat::core::define
  (:trading::encoding::compute-fractal-dim
    (closes :Vec<f64>)
    -> :wat::core::f64)
  (:wat::core::let*
    (((n :wat::core::i64) (:wat::core::length closes)))
    (:wat::core::if (:wat::core::< n 10) -> :wat::core::f64
      1.5
      (:wat::core::let*
        (((l1 :wat::core::f64)
          (:trading::encoding::regime::higuchi-length closes 1))
         ((l4 :wat::core::f64)
          (:trading::encoding::regime::higuchi-length closes 4)))
        (:wat::core::if (:wat::core::or
                          (:wat::core::<= l1 0.0)
                          (:wat::core::<= l4 0.0)) -> :wat::core::f64
          1.5
          (:wat::core::let*
            (((d :wat::core::f64)
              (:wat::core::/
                (:wat::std::math::ln (:wat::core::/ l1 l4))
                (:wat::std::math::ln 4.0))))
            (:wat::core::f64::clamp d 1.0 2.0)))))))
