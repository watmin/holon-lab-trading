;; wat/encoding/indicator-bank/persistence.wat — Hurst, autocorrelation,
;; vwap-distance.
;;
;; Lab arc 026 slice 9 (2026-04-25). Direct port of
;; archived/pre-wat-native/src/domain/indicator_bank.rs:785-849
;; (hurst_exponent, autocorrelation_lag1) + 1228-1239
;; (compute_vwap_distance).
;;
;; First statistical-estimator slice. The math is non-trivial; ported
;; line-by-line against the archive. Hurst R/S analysis: returns →
;; mean → cumulative deviations → range / stddev → ln-ratio. The
;; cumulative-deviations step needs scan-with-running-state, expressed
;; here as a foldl over (acc-vec, running) tuples (no `scan` primitive
;; in the substrate; defer the uplift until a second site reaches
;; for it).
;;
;; Diverges from BACKLOG sketch — the sketched `HurstState` struct
;; wrapping a return-buf is over-engineered. Archive's pattern is
;; pure compute functions over a close-buf RingBuffer held at the
;; IndicatorBank level (one buffer, two consumers: Hurst +
;; autocorrelation). Faithful to archive.
;;
;; Substrate uplifts consumed: `:wat::std::math::sqrt` (slice 4
;; carry-along), `:wat::std::math::ln`, polymorphic arithmetic.
;;
;; Explicit:
;;   :trading::encoding::compute-hurst                :Vec<f64> -> :f64
;;   :trading::encoding::compute-autocorrelation-lag1 :Vec<f64> -> :f64
;;
;;   :trading::encoding::VwapState::fresh           -> VwapState
;;   :trading::encoding::VwapState::update state close volume -> VwapState
;;   :trading::encoding::VwapState::distance state close -> :f64

(:wat::load-file! "primitives.wat")


;; ─── Internal helpers ────────────────────────────────────────────
;;
;; persistence::mean / persistence::variance lifted to wat-rs as
;; :wat::std::stat::mean / :wat::std::stat::variance / ::stddev (the
;; substrate's universal-stats namespace). Lab callers below
;; consume those directly. The sites that previously called the
;; local mean now match-with-impossible-None on the substrate's
;; Option<f64> result; this slice's compute helpers gate on
;; sufficient data first, so the None arm is unreachable.

;; Build the simple-returns vector from a closes vector.
;; returns[i] = (closes[i+1] - closes[i]) / closes[i], or 0 if
;; closes[i] = 0. Length = n - 1.
(:wat::core::define
  (:trading::encoding::persistence::returns
    (closes :Vec<f64>)
    -> :Vec<f64>)
  (:wat::core::let*
    (((n :i64) (:wat::core::length closes)))
    (:wat::core::if (:wat::core::< n 2) -> :Vec<f64>
      (:wat::core::vec :f64)
      (:wat::core::map
        (:wat::core::range 0 (:wat::core::- n 1))
        (:wat::core::lambda ((i :i64) -> :f64)
          (:wat::core::let*
            (((cur :f64)
              (:wat::core::match (:wat::core::get closes i) -> :f64
                ((Some v) v) (:None 0.0)))
             ((nxt :f64)
              (:wat::core::match
                (:wat::core::get closes (:wat::core::+ i 1)) -> :f64
                ((Some v) v) (:None 0.0))))
            (:wat::core::if (:wat::core::= cur 0.0) -> :f64
              0.0
              (:wat::core::/ (:wat::core::- nxt cur) cur))))))))


;; Cumulative deviations: scan x → x - mu, accumulating the running
;; sum at each index. Implemented via foldl over (acc-vec, running)
;; tuples since the substrate has no `scan`. The lambda body returns
;; (vec ++ [running'], running') so the final acc-vec is the scan.
(:wat::core::define
  (:trading::encoding::persistence::cum-deviations
    (xs :Vec<f64>)
    (mu :f64)
    -> :Vec<f64>)
  (:wat::core::first
    (:wat::core::foldl xs
      (:wat::core::tuple (:wat::core::vec :f64) 0.0)
      (:wat::core::lambda
        ((acc :(Vec<f64>,f64)) (x :f64)
         -> :(Vec<f64>,f64))
        (:wat::core::let*
          (((vec :Vec<f64>) (:wat::core::first acc))
           ((running :f64) (:wat::core::second acc))
           ((new-running :f64) (:wat::core::+ running (:wat::core::- x mu))))
          (:wat::core::tuple
            (:wat::core::conj vec new-running)
            new-running))))))


;; ─── Hurst exponent via R/S analysis ──────────────────────────────

(:wat::core::define
  (:trading::encoding::compute-hurst
    (closes :Vec<f64>)
    -> :f64)
  (:wat::core::let*
    (((n :i64) (:wat::core::length closes)))
    (:wat::core::if (:wat::core::< n 8) -> :f64
      0.5
      (:wat::core::let*
        (((returns :Vec<f64>)
          (:trading::encoding::persistence::returns closes))
         ((rn :i64) (:wat::core::length returns))
         ((rn-f64 :f64) (:wat::core::i64::to-f64 rn))
         ;; mu / variance via the substrate's :wat::std::stat::*.
         ;; Empty arm unreachable: outer gate already caught n < 8 →
         ;; rn >= 7, returns Vec is non-empty.
         ((mu :f64)
          (:wat::core::match (:wat::std::stat::mean returns) -> :f64
            ((Some v) v) (:None 0.0)))
         ((cum-dev :Vec<f64>)
          (:trading::encoding::persistence::cum-deviations returns mu))
         ;; Range of cum-dev. min/max return Option<f64>; at this
         ;; gate we know n >= 8 → rn >= 7 → cum-dev nonempty. Sentinels
         ;; unreachable.
         ((cd-max :f64)
          (:wat::core::match
            (:wat::core::f64::max-of cum-dev) -> :f64
            ((Some v) v) (:None 0.0)))
         ((cd-min :f64)
          (:wat::core::match
            (:wat::core::f64::min-of cum-dev) -> :f64
            ((Some v) v) (:None 0.0)))
         ((r :f64) (:wat::core::- cd-max cd-min))
         ;; Stddev of returns (population) via substrate.
         ((s :f64)
          (:wat::core::match (:wat::std::stat::stddev returns) -> :f64
            ((Some v) v) (:None 0.0))))
        (:wat::core::if (:wat::core::= s 0.0) -> :f64
          0.5
          (:wat::core::let*
            (((rs :f64) (:wat::core::/ r s)))
            (:wat::core::if (:wat::core::<= rs 0.0) -> :f64
              0.5
              (:wat::core::/
                (:wat::std::math::ln rs)
                (:wat::std::math::ln rn-f64)))))))))


;; ─── Autocorrelation at lag 1 ─────────────────────────────────────

(:wat::core::define
  (:trading::encoding::compute-autocorrelation-lag1
    (xs :Vec<f64>)
    -> :f64)
  (:wat::core::let*
    (((n :i64) (:wat::core::length xs)))
    (:wat::core::if (:wat::core::< n 3) -> :f64
      0.0
      (:wat::core::let*
        (;; Empty arms unreachable: outer gate caught n < 3.
         ((mu :f64)
          (:wat::core::match (:wat::std::stat::mean xs) -> :f64
            ((Some v) v) (:None 0.0)))
         ((var :f64)
          (:wat::core::match (:wat::std::stat::variance xs) -> :f64
            ((Some v) v) (:None 0.0))))
        (:wat::core::if (:wat::core::= var 0.0) -> :f64
          0.0
          (:wat::core::let*
            (;; cov = sum over i in 0..n-1 of (xs[i] - mu)*(xs[i+1] - mu),
             ;; divided by (n-1).
             ((cov-sum :f64)
              (:wat::core::foldl
                (:wat::core::range 0 (:wat::core::- n 1))
                0.0
                (:wat::core::lambda ((acc :f64) (i :i64) -> :f64)
                  (:wat::core::let*
                    (((xi :f64)
                      (:wat::core::match (:wat::core::get xs i) -> :f64
                        ((Some v) v) (:None 0.0)))
                     ((xj :f64)
                      (:wat::core::match
                        (:wat::core::get xs (:wat::core::+ i 1)) -> :f64
                        ((Some v) v) (:None 0.0))))
                    (:wat::core::+ acc
                      (:wat::core::*
                        (:wat::core::- xi mu)
                        (:wat::core::- xj mu)))))))
             ((cov :f64)
              (:wat::core::/ cov-sum
                (:wat::core::i64::to-f64 (:wat::core::- n 1)))))
            (:wat::core::/ cov var)))))))


;; ─── VWAP distance ────────────────────────────────────────────────

(:wat::core::struct :trading::encoding::VwapState
  (cum-pv  :f64)   ;; cumulative price·volume
  (cum-vol :f64))  ;; cumulative volume


(:wat::core::define
  (:trading::encoding::VwapState::fresh
    -> :trading::encoding::VwapState)
  (:trading::encoding::VwapState/new 0.0 0.0))


(:wat::core::define
  (:trading::encoding::VwapState::update
    (state :trading::encoding::VwapState)
    (close :f64)
    (volume :f64)
    -> :trading::encoding::VwapState)
  (:trading::encoding::VwapState/new
    (:wat::core::+
      (:trading::encoding::VwapState/cum-pv state)
      (:wat::core::* close volume))
    (:wat::core::+
      (:trading::encoding::VwapState/cum-vol state)
      volume)))


;; (close - vwap) / close. Defensive 0.0 fallbacks on cum-vol=0 (no
;; data) or close=0.
(:wat::core::define
  (:trading::encoding::VwapState::distance
    (state :trading::encoding::VwapState)
    (close :f64)
    -> :f64)
  (:wat::core::let*
    (((cum-vol :f64) (:trading::encoding::VwapState/cum-vol state))
     ((cum-pv :f64) (:trading::encoding::VwapState/cum-pv state)))
    (:wat::core::if (:wat::core::= cum-vol 0.0) -> :f64
      0.0
      (:wat::core::if (:wat::core::= close 0.0) -> :f64
        0.0
        (:wat::core::let*
          (((vwap :f64) (:wat::core::/ cum-pv cum-vol)))
          (:wat::core::/ (:wat::core::- close vwap) close))))))
