;; wat/encoding/indicator-bank/bank.wat — IndicatorBank orchestration.
;;
;; Lab arc 026 slice 12 (2026-04-25). The integrating struct.
;; Holds every per-indicator state from slices 1-11 + arc 025's
;; ATR/PhaseState. `tick(bank, ohlcv) -> (bank, candle)` advances
;; every state and produces a fully-populated `:trading::types::Candle`.
;;
;; Direct port of archive's IndicatorBank::feed_candle (line 1635-
;; 1951). Values-up: input bank → output bank + candle. No mutation.
;;
;; Time-of-day fields populated as 0.0 sentinels in v1 — time-string
;; parsing (parse-minute/hour/day-of-week etc. from archive's
;; parse_*) is a deferred follow-up. The Time sub-struct's fields
;; appear in the Candle with zeros until that slice ships.
;;
;; Cached_phase_history optimization (archive lines 1370-1371,
;; 1862-1866) skipped in the wat port — phase_state.history is
;; already pull-on-access via the auto-generated accessor.
;;
;; Auto-generated accessors per field. Explicit:
;;   :trading::encoding::IndicatorBank::fresh -> IndicatorBank
;;   :trading::encoding::IndicatorBank::tick bank ohlcv ->
;;     :(IndicatorBank, trading::types::Candle)

(:wat::load-file! "primitives.wat")
(:wat::load-file! "oscillators.wat")
(:wat::load-file! "trend.wat")
(:wat::load-file! "volatility.wat")
(:wat::load-file! "volume.wat")
(:wat::load-file! "rate.wat")
(:wat::load-file! "timeframe.wat")
(:wat::load-file! "ichimoku.wat")
(:wat::load-file! "persistence.wat")
(:wat::load-file! "regime.wat")
(:wat::load-file! "divergence.wat")
(:wat::load-file! "price-action.wat")
(:wat::load-file! "../atr.wat")
(:wat::load-file! "../atr-window.wat")
(:wat::load-file! "../phase-state.wat")
(:wat::load-file! "../../types/candle.wat")


;; ─── IndicatorBank — the integrating struct ──────────────────────

(:wat::core::struct :trading::encoding::IndicatorBank
  ;; Moving averages
  (sma20            :trading::encoding::SmaState)
  (sma50            :trading::encoding::SmaState)
  (sma200           :trading::encoding::SmaState)
  (ema20            :trading::encoding::EmaState)
  ;; Volatility
  (bollinger        :trading::encoding::BollingerState)
  (keltner          :trading::encoding::KeltnerState)
  ;; Oscillators
  (rsi              :trading::encoding::RsiState)
  (macd             :trading::encoding::MacdState)
  (dmi              :trading::encoding::DmiState)
  (atr              :trading::encoding::AtrState)
  (atr-window       :trading::encoding::AtrWindow)
  (stoch            :trading::encoding::StochState)
  (cci              :trading::encoding::CciState)
  (mfi              :trading::encoding::MfiState)
  (obv              :trading::encoding::ObvState)
  (volume-accel     :trading::encoding::VolumeAccelState)
  ;; ROC + range positions
  (roc-buf          :trading::encoding::RingBuffer)
  (range-high-12    :trading::encoding::RingBuffer)
  (range-low-12     :trading::encoding::RingBuffer)
  (range-high-24    :trading::encoding::RingBuffer)
  (range-low-24     :trading::encoding::RingBuffer)
  (range-high-48    :trading::encoding::RingBuffer)
  (range-low-48     :trading::encoding::RingBuffer)
  ;; ATR history (chop sum window — archive's chop_buf is reused
  ;; here; ATR-history-12 buffer also retained for any other
  ;; consumers; both at period 14)
  (chop-buf         :trading::encoding::RingBuffer)
  (chop-atr-sum     :f64)
  ;; Multi-timeframe
  (tf-1h-buf        :trading::encoding::RingBuffer)
  (tf-1h-high       :trading::encoding::RingBuffer)
  (tf-1h-low        :trading::encoding::RingBuffer)
  (tf-4h-buf        :trading::encoding::RingBuffer)
  (tf-4h-high       :trading::encoding::RingBuffer)
  (tf-4h-low        :trading::encoding::RingBuffer)
  ;; Ichimoku
  (ichimoku         :trading::encoding::IchimokuState)
  ;; Persistence
  (close-buf-48     :trading::encoding::RingBuffer)
  (vwap             :trading::encoding::VwapState)
  ;; Regime
  (kama-er-buf      :trading::encoding::RingBuffer)
  (dfa-buf          :trading::encoding::RingBuffer)
  (var-ratio-buf    :trading::encoding::RingBuffer)
  (entropy-buf      :trading::encoding::RingBuffer)
  (aroon-high-buf   :trading::encoding::RingBuffer)
  (aroon-low-buf    :trading::encoding::RingBuffer)
  (fractal-buf      :trading::encoding::RingBuffer)
  ;; Divergence
  (rsi-peak-buf     :trading::encoding::RingBuffer)
  (price-peak-buf   :trading::encoding::RingBuffer)
  ;; Cross deltas
  (prev-tk-spread   :f64)
  (prev-stoch-kd    :f64)
  ;; Price action
  (consecutive      :trading::encoding::ConsecutiveState)
  ;; Phase labeler
  (phase-state      :trading::encoding::PhaseState)
  ;; Previous values
  (prev-close       :f64)
  ;; Counter
  (count            :i64))


;; ─── fresh ────────────────────────────────────────────────────────
;;
;; Default periods match archive (sma20/50/200, ema20, rsi14, atr14,
;; etc.). The 50-arg constructor is unavoidable for a struct of this
;; size; readability comes from the comments next to each line.

(:wat::core::define
  (:trading::encoding::IndicatorBank::fresh
    -> :trading::encoding::IndicatorBank)
  (:trading::encoding::IndicatorBank/new
    (:trading::encoding::SmaState::fresh 20)         ;; sma20
    (:trading::encoding::SmaState::fresh 50)         ;; sma50
    (:trading::encoding::SmaState::fresh 200)        ;; sma200
    (:trading::encoding::EmaState::fresh 20)         ;; ema20
    (:trading::encoding::BollingerState::fresh 20)   ;; bollinger
    (:trading::encoding::KeltnerState::fresh 20)     ;; keltner
    (:trading::encoding::RsiState::fresh 14)         ;; rsi
    (:trading::encoding::MacdState::fresh 12 26 9)   ;; macd
    (:trading::encoding::DmiState::fresh 14)         ;; dmi
    (:trading::encoding::AtrState::fresh 14)         ;; atr
    (:trading::encoding::AtrWindow::fresh 2016)      ;; atr-window (1-week)
    (:trading::encoding::StochState::fresh 14 3)     ;; stoch
    (:trading::encoding::CciState::fresh 20)         ;; cci
    (:trading::encoding::MfiState::fresh 14)         ;; mfi
    (:trading::encoding::ObvState::fresh 12)         ;; obv
    (:trading::encoding::VolumeAccelState::fresh 20) ;; volume-accel
    (:trading::encoding::RingBuffer::fresh 12)       ;; roc-buf
    (:trading::encoding::RingBuffer::fresh 12)       ;; range-high-12
    (:trading::encoding::RingBuffer::fresh 12)       ;; range-low-12
    (:trading::encoding::RingBuffer::fresh 24)       ;; range-high-24
    (:trading::encoding::RingBuffer::fresh 24)       ;; range-low-24
    (:trading::encoding::RingBuffer::fresh 48)       ;; range-high-48
    (:trading::encoding::RingBuffer::fresh 48)       ;; range-low-48
    (:trading::encoding::RingBuffer::fresh 14)       ;; chop-buf
    0.0                                              ;; chop-atr-sum
    (:trading::encoding::RingBuffer::fresh 12)       ;; tf-1h-buf
    (:trading::encoding::RingBuffer::fresh 12)       ;; tf-1h-high
    (:trading::encoding::RingBuffer::fresh 12)       ;; tf-1h-low
    (:trading::encoding::RingBuffer::fresh 48)       ;; tf-4h-buf
    (:trading::encoding::RingBuffer::fresh 48)       ;; tf-4h-high
    (:trading::encoding::RingBuffer::fresh 48)       ;; tf-4h-low
    (:trading::encoding::IchimokuState::fresh)       ;; ichimoku
    (:trading::encoding::RingBuffer::fresh 48)       ;; close-buf-48
    (:trading::encoding::VwapState::fresh)           ;; vwap
    (:trading::encoding::RingBuffer::fresh 10)       ;; kama-er-buf
    (:trading::encoding::RingBuffer::fresh 48)       ;; dfa-buf
    (:trading::encoding::RingBuffer::fresh 30)       ;; var-ratio-buf
    (:trading::encoding::RingBuffer::fresh 30)       ;; entropy-buf
    (:trading::encoding::RingBuffer::fresh 25)       ;; aroon-high-buf
    (:trading::encoding::RingBuffer::fresh 25)       ;; aroon-low-buf
    (:trading::encoding::RingBuffer::fresh 30)       ;; fractal-buf
    (:trading::encoding::RingBuffer::fresh 20)       ;; rsi-peak-buf
    (:trading::encoding::RingBuffer::fresh 20)       ;; price-peak-buf
    0.0                                              ;; prev-tk-spread
    0.0                                              ;; prev-stoch-kd
    (:trading::encoding::ConsecutiveState::fresh)    ;; consecutive
    (:trading::encoding::PhaseState::fresh)          ;; phase-state
    0.0                                              ;; prev-close
    0))                                              ;; count


;; ─── tick — advance every state and assemble Candle ───────────────
;;
;; The waterfall: pull (h, l, c, v) from ohlcv; advance each per-
;; indicator state values-up; compute every derived Candle field;
;; build the 11 sub-structs; assemble the Candle. Returns a tuple of
;; the new bank + the candle.

(:wat::core::define
  (:trading::encoding::IndicatorBank::tick
    (bank :trading::encoding::IndicatorBank)
    (ohlcv :trading::types::Ohlcv)
    -> :(trading::encoding::IndicatorBank,trading::types::Candle))
  (:wat::core::let*
    (((o :f64) (:trading::types::Ohlcv/open ohlcv))
     ((h :f64) (:trading::types::Ohlcv/high ohlcv))
     ((l :f64) (:trading::types::Ohlcv/low ohlcv))
     ((c :f64) (:trading::types::Ohlcv/close ohlcv))
     ((v :f64) (:trading::types::Ohlcv/volume ohlcv))

     ;; ── 1. Step every per-indicator state ─────────────────────
     ((sma20'   :trading::encoding::SmaState)
      (:trading::encoding::SmaState::update
        (:trading::encoding::IndicatorBank/sma20 bank) c))
     ((sma50'   :trading::encoding::SmaState)
      (:trading::encoding::SmaState::update
        (:trading::encoding::IndicatorBank/sma50 bank) c))
     ((sma200'  :trading::encoding::SmaState)
      (:trading::encoding::SmaState::update
        (:trading::encoding::IndicatorBank/sma200 bank) c))
     ((ema20'   :trading::encoding::EmaState)
      (:trading::encoding::EmaState::update
        (:trading::encoding::IndicatorBank/ema20 bank) c))
     ((boll'    :trading::encoding::BollingerState)
      (:trading::encoding::BollingerState::update
        (:trading::encoding::IndicatorBank/bollinger bank) c))
     ((kelt'    :trading::encoding::KeltnerState)
      (:trading::encoding::KeltnerState::update
        (:trading::encoding::IndicatorBank/keltner bank) c))
     ((rsi'     :trading::encoding::RsiState)
      (:trading::encoding::RsiState::update
        (:trading::encoding::IndicatorBank/rsi bank) c))
     ((macd'    :trading::encoding::MacdState)
      (:trading::encoding::MacdState::update
        (:trading::encoding::IndicatorBank/macd bank) c))
     ((dmi'     :trading::encoding::DmiState)
      (:trading::encoding::DmiState::update
        (:trading::encoding::IndicatorBank/dmi bank) h l c))
     ((atr'     :trading::encoding::AtrState)
      (:trading::encoding::AtrState::update
        (:trading::encoding::IndicatorBank/atr bank) h l c))
     ;; AtrWindow updates only after ATR is ready (matches arc 025's
     ;; smoothing-warmup intent).
     ((atr-window' :trading::encoding::AtrWindow)
      (:wat::core::if (:trading::encoding::AtrState::ready? atr') -> :trading::encoding::AtrWindow
        (:trading::encoding::AtrWindow::push
          (:trading::encoding::IndicatorBank/atr-window bank)
          (:trading::encoding::AtrState::value atr'))
        (:trading::encoding::IndicatorBank/atr-window bank)))
     ((stoch'   :trading::encoding::StochState)
      (:trading::encoding::StochState::update
        (:trading::encoding::IndicatorBank/stoch bank) h l c))
     ((cci'     :trading::encoding::CciState)
      (:trading::encoding::CciState::update
        (:trading::encoding::IndicatorBank/cci bank) h l c))
     ((mfi'     :trading::encoding::MfiState)
      (:trading::encoding::MfiState::update
        (:trading::encoding::IndicatorBank/mfi bank) h l c v))
     ((obv'     :trading::encoding::ObvState)
      (:trading::encoding::ObvState::update
        (:trading::encoding::IndicatorBank/obv bank) c v))
     ((volume-accel' :trading::encoding::VolumeAccelState)
      (:trading::encoding::VolumeAccelState::update
        (:trading::encoding::IndicatorBank/volume-accel bank) v))
     ((roc-buf' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/roc-buf bank) c))
     ((rh12' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/range-high-12 bank) h))
     ((rl12' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/range-low-12 bank) l))
     ((rh24' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/range-high-24 bank) h))
     ((rl24' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/range-low-24 bank) l))
     ((rh48' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/range-high-48 bank) h))
     ((rl48' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/range-low-48 bank) l))

     ;; Choppiness: ATR sum with peek-and-subtract on eviction.
     ((chop-buf-prev :trading::encoding::RingBuffer)
      (:trading::encoding::IndicatorBank/chop-buf bank))
     ((chop-was-full? :bool)
      (:trading::encoding::RingBuffer::full? chop-buf-prev))
     ((chop-evicted :f64)
      (:wat::core::if chop-was-full? -> :f64
        (:wat::core::match
          (:trading::encoding::RingBuffer::get
            chop-buf-prev
            (:wat::core::-
              (:trading::encoding::RingBuffer::len chop-buf-prev) 1))
          -> :f64
          ((Some x) x) (:None 0.0))
        0.0))
     ((chop-buf' :trading::encoding::RingBuffer)
      (:wat::core::if (:trading::encoding::AtrState::ready? atr')
                      -> :trading::encoding::RingBuffer
        (:trading::encoding::RingBuffer::push
          chop-buf-prev
          (:trading::encoding::AtrState::value atr'))
        chop-buf-prev))
     ((chop-atr-sum' :f64)
      (:wat::core::if (:trading::encoding::AtrState::ready? atr') -> :f64
        (:wat::core::+
          (:wat::core::- (:trading::encoding::IndicatorBank/chop-atr-sum bank)
                         chop-evicted)
          (:trading::encoding::AtrState::value atr'))
        (:trading::encoding::IndicatorBank/chop-atr-sum bank)))

     ;; Multi-timeframe buffers
     ((tf-1h'      :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/tf-1h-buf bank) c))
     ((tf-1h-hi'   :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/tf-1h-high bank) h))
     ((tf-1h-lo'   :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/tf-1h-low bank) l))
     ((tf-4h'      :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/tf-4h-buf bank) c))
     ((tf-4h-hi'   :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/tf-4h-high bank) h))
     ((tf-4h-lo'   :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/tf-4h-low bank) l))

     ;; Ichimoku
     ((ichi'  :trading::encoding::IchimokuState)
      (:trading::encoding::IchimokuState::update
        (:trading::encoding::IndicatorBank/ichimoku bank) h l))
     ;; Persistence
     ((cb48' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/close-buf-48 bank) c))
     ((vwap'  :trading::encoding::VwapState)
      (:trading::encoding::VwapState::update
        (:trading::encoding::IndicatorBank/vwap bank) c v))

     ;; Regime
     ((ke-buf' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/kama-er-buf bank) c))
     ((dfa-buf' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/dfa-buf bank) c))
     ((vr-buf' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/var-ratio-buf bank) c))
     ;; Entropy: discretize the return into a bin BEFORE pushing.
     ((entropy-ret :f64)
      (:wat::core::if (:wat::core::= (:trading::encoding::IndicatorBank/prev-close bank)
                                     0.0) -> :f64
        0.0
        (:wat::core::/
          (:wat::core::- c (:trading::encoding::IndicatorBank/prev-close bank))
          (:trading::encoding::IndicatorBank/prev-close bank))))
     ((entropy-bin :f64) (:trading::encoding::compute-entropy-bin entropy-ret))
     ((entropy-buf' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/entropy-buf bank) entropy-bin))
     ((aroon-h' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/aroon-high-buf bank) h))
     ((aroon-l' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/aroon-low-buf bank) l))
     ((fractal-buf' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/fractal-buf bank) c))

     ;; Divergence buffers — push close + current RSI value.
     ((rsi-peak' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/rsi-peak-buf bank)
        (:trading::encoding::RsiState::value rsi')))
     ((price-peak' :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IndicatorBank/price-peak-buf bank) c))

     ;; Price action
     ((cons' :trading::encoding::ConsecutiveState)
      (:trading::encoding::ConsecutiveState::update
        (:trading::encoding::IndicatorBank/consecutive bank) c))

     ;; Phase labeler — smoothing = 2·ATR (Proposal 052; v1 doesn't
     ;; gate on ATR-window's median yet — that's an arc 025 slice 4
     ;; concern. Use 2·current-ATR which works once ATR is ready.).
     ((smoothing :f64)
      (:wat::core::* 2.0 (:trading::encoding::AtrState::value atr')))
     ((next-count :i64)
      (:wat::core::+ (:trading::encoding::IndicatorBank/count bank) 1))
     ((phase'   :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step
        (:trading::encoding::IndicatorBank/phase-state bank)
        c v next-count smoothing))

     ;; ── 2. Compute Candle field values ─────────────────────────

     ;; SMA values (post-update)
     ((sma20-val :f64) (:trading::encoding::SmaState::value sma20'))
     ((sma50-val :f64) (:trading::encoding::SmaState::value sma50'))
     ((sma200-val :f64) (:trading::encoding::SmaState::value sma200'))

     ;; Bollinger
     ((bb-width-val :f64) (:trading::encoding::BollingerState::width boll'))
     ((bb-pos-val :f64) (:trading::encoding::BollingerState::pos boll' c))

     ;; Keltner
     ((atr-val :f64) (:trading::encoding::AtrState::value atr'))
     ((kelt-upper-val :f64)
      (:trading::encoding::KeltnerState::upper kelt' atr-val))
     ((kelt-lower-val :f64)
      (:trading::encoding::KeltnerState::lower kelt' atr-val))
     ((kelt-pos-val :f64)
      (:trading::encoding::KeltnerState::pos kelt' atr-val c))
     ;; Squeeze: bb-width / kelt-width-as-fraction-of-close.
     ((kelt-range :f64) (:wat::core::- kelt-upper-val kelt-lower-val))
     ((kelt-width-ratio :f64)
      (:wat::core::if (:wat::core::= c 0.0) -> :f64
        0.0
        (:wat::core::/ kelt-range c)))
     ((squeeze-val :f64)
      (:trading::encoding::compute-squeeze bb-width-val kelt-width-ratio))
     ((atr-ratio-val :f64) (:trading::encoding::compute-atr-ratio atr-val c))

     ;; RSI / MACD / DMI
     ((rsi-val :f64) (:trading::encoding::RsiState::value rsi'))
     ((macd-hist-val :f64) (:trading::encoding::MacdState::hist-value macd'))
     ((plus-di-val :f64) (:trading::encoding::DmiState::plus-di dmi'))
     ((minus-di-val :f64) (:trading::encoding::DmiState::minus-di dmi'))
     ((adx-val :f64) (:trading::encoding::DmiState::adx dmi'))

     ;; Stochastic + Williams %R
     ((stoch-k-val :f64) (:trading::encoding::StochState::k stoch'))
     ((stoch-d-val :f64) (:trading::encoding::StochState::d stoch'))
     ((williams-val :f64) (:trading::encoding::compute-williams-r stoch' c))

     ;; CCI / MFI / OBV / Volume Accel
     ((cci-val :f64) (:trading::encoding::CciState::value cci'))
     ((mfi-val :f64) (:trading::encoding::MfiState::value mfi'))
     ((obv-slope-val :f64) (:trading::encoding::ObvState::slope obv'))
     ((vol-accel-val :f64) (:trading::encoding::VolumeAccelState::value volume-accel'))

     ;; ROC
     ((roc-1-val :f64) (:trading::encoding::compute-roc roc-buf' 1))
     ((roc-3-val :f64) (:trading::encoding::compute-roc roc-buf' 3))
     ((roc-6-val :f64) (:trading::encoding::compute-roc roc-buf' 6))
     ((roc-12-val :f64) (:trading::encoding::compute-roc roc-buf' 12))

     ;; Range positions
     ((rp-12 :f64) (:trading::encoding::compute-range-pos rh12' rl12' c))
     ((rp-24 :f64) (:trading::encoding::compute-range-pos rh24' rl24' c))
     ((rp-48 :f64) (:trading::encoding::compute-range-pos rh48' rl48' c))

     ;; Multi-timeframe
     ((tf-1h-ret-val :f64) (:trading::encoding::compute-tf-ret tf-1h'))
     ((tf-1h-body-val :f64) (:trading::encoding::compute-tf-body tf-1h'))
     ((tf-4h-ret-val :f64) (:trading::encoding::compute-tf-ret tf-4h'))
     ((tf-4h-body-val :f64) (:trading::encoding::compute-tf-body tf-4h'))
     ((tf-agree :f64)
      (:trading::encoding::compute-tf-agreement
        (:trading::encoding::IndicatorBank/prev-close bank)
        c tf-1h' tf-4h'))

     ;; Ichimoku
     ((tenkan :f64) (:trading::encoding::IchimokuState::tenkan ichi'))
     ((kijun :f64) (:trading::encoding::IchimokuState::kijun ichi'))
     ((cloud-top-val :f64) (:trading::encoding::IchimokuState::cloud-top ichi'))
     ((cloud-bottom-val :f64) (:trading::encoding::IchimokuState::cloud-bottom ichi'))

     ;; Cross deltas
     ((tk-spread :f64) (:wat::core::- tenkan kijun))
     ((tk-delta :f64)
      (:wat::core::- tk-spread (:trading::encoding::IndicatorBank/prev-tk-spread bank)))
     ((stoch-kd :f64) (:wat::core::- stoch-k-val stoch-d-val))
     ((stoch-delta :f64)
      (:wat::core::- stoch-kd (:trading::encoding::IndicatorBank/prev-stoch-kd bank)))

     ;; Persistence
     ((cb48-vals :Vec<f64>) (:trading::encoding::RingBuffer/values cb48'))
     ((hurst-val :f64) (:trading::encoding::compute-hurst cb48-vals))
     ((autocorr-val :f64)
      (:trading::encoding::compute-autocorrelation-lag1 cb48-vals))
     ((vwap-val :f64) (:trading::encoding::VwapState::distance vwap' c))

     ;; Regime
     ((ke-vals :Vec<f64>) (:trading::encoding::RingBuffer/values ke-buf'))
     ((kama-er-val :f64)
      (:wat::core::if (:trading::encoding::RingBuffer::full? ke-buf') -> :f64
        (:trading::encoding::compute-kama-er ke-vals)
        0.5))
     ((chop-val :f64)
      (:wat::core::if (:trading::encoding::RingBuffer::full? chop-buf') -> :f64
        (:trading::encoding::compute-choppiness chop-atr-sum' rh12' rl12')
        50.0))
     ((dfa-vals :Vec<f64>) (:trading::encoding::RingBuffer/values dfa-buf'))
     ((dfa-val :f64) (:trading::encoding::compute-dfa-alpha dfa-vals))
     ((vr-vals :Vec<f64>) (:trading::encoding::RingBuffer/values vr-buf'))
     ((vr-val :f64) (:trading::encoding::compute-variance-ratio vr-vals))
     ((entropy-vals :Vec<f64>) (:trading::encoding::RingBuffer/values entropy-buf'))
     ((entropy-val :f64) (:trading::encoding::compute-entropy-rate entropy-vals))
     ((aroon-h-vals :Vec<f64>) (:trading::encoding::RingBuffer/values aroon-h'))
     ((aroon-up-val :f64)
      (:wat::core::if (:trading::encoding::RingBuffer::full? aroon-h') -> :f64
        (:trading::encoding::compute-aroon-up aroon-h-vals)
        50.0))
     ((aroon-l-vals :Vec<f64>) (:trading::encoding::RingBuffer/values aroon-l'))
     ((aroon-down-val :f64)
      (:wat::core::if (:trading::encoding::RingBuffer::full? aroon-l') -> :f64
        (:trading::encoding::compute-aroon-down aroon-l-vals)
        50.0))
     ((fractal-vals :Vec<f64>) (:trading::encoding::RingBuffer/values fractal-buf'))
     ((fractal-val :f64) (:trading::encoding::compute-fractal-dim fractal-vals))

     ;; Divergence
     ((price-peak-vals :Vec<f64>)
      (:trading::encoding::RingBuffer/values price-peak'))
     ((rsi-peak-vals :Vec<f64>)
      (:trading::encoding::RingBuffer/values rsi-peak'))
     ((divergence-pair :(f64,f64))
      (:trading::encoding::detect-divergence price-peak-vals rsi-peak-vals))
     ((div-bull :f64) (:wat::core::first divergence-pair))
     ((div-bear :f64) (:wat::core::second divergence-pair))

     ;; Price action
     ((range-ratio-val :f64) (:trading::encoding::compute-range-ratio h l))
     ((gap-val :f64)
      (:trading::encoding::compute-gap o
        (:trading::encoding::IndicatorBank/prev-close bank)))
     ((cons-up-val :f64)
      (:wat::core::i64::to-f64 (:trading::encoding::ConsecutiveState::up cons')))
     ((cons-down-val :f64)
      (:wat::core::i64::to-f64 (:trading::encoding::ConsecutiveState::down cons')))

     ;; Phase
     ((phase-label :trading::types::PhaseLabel)
      (:trading::encoding::PhaseState/current-label phase'))
     ((phase-direction :trading::types::PhaseDirection)
      (:trading::encoding::PhaseState/current-direction phase'))
     ((phase-duration :i64)
      (:trading::encoding::PhaseState/count phase'))
     ((phase-history :trading::types::PhaseRecords)
      (:trading::encoding::PhaseState/phase-history phase'))

     ;; ── 3. Build sub-structs ──────────────────────────────────

     ((trend-sub :trading::types::Candle::Trend)
      (:trading::types::Candle::Trend/new
        sma20-val sma50-val sma200-val
        tenkan kijun
        cloud-top-val cloud-bottom-val))

     ((volatility-sub :trading::types::Candle::Volatility)
      (:trading::types::Candle::Volatility/new
        bb-width-val bb-pos-val
        kelt-upper-val kelt-lower-val kelt-pos-val
        squeeze-val atr-ratio-val))

     ((momentum-sub :trading::types::Candle::Momentum)
      (:trading::types::Candle::Momentum/new
        rsi-val macd-hist-val
        plus-di-val minus-di-val adx-val
        stoch-k-val stoch-d-val
        williams-val cci-val mfi-val
        obv-slope-val vol-accel-val))

     ((divergence-sub :trading::types::Candle::Divergence)
      (:trading::types::Candle::Divergence/new
        div-bull div-bear tk-delta stoch-delta))

     ((roc-sub :trading::types::Candle::RateOfChange)
      (:trading::types::Candle::RateOfChange/new
        roc-1-val roc-3-val roc-6-val roc-12-val
        rp-12 rp-24 rp-48))

     ((persistence-sub :trading::types::Candle::Persistence)
      (:trading::types::Candle::Persistence/new
        hurst-val autocorr-val vwap-val))

     ((regime-sub :trading::types::Candle::Regime)
      (:trading::types::Candle::Regime/new
        kama-er-val chop-val dfa-val vr-val entropy-val
        aroon-up-val aroon-down-val fractal-val))

     ((price-action-sub :trading::types::Candle::PriceAction)
      (:trading::types::Candle::PriceAction/new
        range-ratio-val gap-val cons-up-val cons-down-val))

     ((timeframe-sub :trading::types::Candle::Timeframe)
      (:trading::types::Candle::Timeframe/new
        tf-1h-ret-val tf-1h-body-val
        tf-4h-ret-val tf-4h-body-val
        tf-agree))

     ;; Time fields are 0.0 sentinels in v1 (time-string parsing
     ;; deferred; see header comment).
     ((time-sub :trading::types::Candle::Time)
      (:trading::types::Candle::Time/new 0.0 0.0 0.0 0.0 0.0))

     ((phase-sub :trading::types::Candle::Phase)
      (:trading::types::Candle::Phase/new
        phase-label phase-direction phase-duration phase-history))

     ;; Build the Candle.
     ((candle :trading::types::Candle)
      (:trading::types::Candle/new
        ohlcv
        trend-sub volatility-sub momentum-sub
        divergence-sub roc-sub persistence-sub
        regime-sub price-action-sub timeframe-sub
        time-sub phase-sub))

     ;; ── 4. Build new bank ────────────────────────────────────

     ((bank' :trading::encoding::IndicatorBank)
      (:trading::encoding::IndicatorBank/new
        sma20' sma50' sma200' ema20'
        boll' kelt'
        rsi' macd' dmi' atr' atr-window'
        stoch' cci' mfi' obv' volume-accel'
        roc-buf'
        rh12' rl12' rh24' rl24' rh48' rl48'
        chop-buf' chop-atr-sum'
        tf-1h' tf-1h-hi' tf-1h-lo'
        tf-4h' tf-4h-hi' tf-4h-lo'
        ichi'
        cb48' vwap'
        ke-buf' dfa-buf' vr-buf' entropy-buf'
        aroon-h' aroon-l' fractal-buf'
        rsi-peak' price-peak'
        tk-spread        ;; prev-tk-spread for next tick
        stoch-kd         ;; prev-stoch-kd for next tick
        cons'
        phase'
        c                ;; prev-close for next tick
        next-count)))

    (:wat::core::tuple bank' candle)))
