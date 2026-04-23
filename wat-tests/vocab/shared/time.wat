;; wat-tests/vocab/shared/time.wat — Lab arc 001 Slice 2.
;;
;; Outstanding tests for :trading::vocab::shared::time — six claims
;; anchored in the module's responsibility:
;;
;; 1. leaves count — encode-time-facts returns 5 facts.
;; 2. composition count — time-facts returns 8 facts (5 leaves + 3 pairs).
;; 3. leaf shape — fact[1] structurally coincides with a hand-built
;;    Bind(Atom("hour"), Circular(rounded-hour, 24.0)).
;; 4. composition shape — fact[5] (minute × hour) structurally
;;    coincides with hand-built Bind(minute-bind, hour-bind).
;; 5. rounding quantizes cache keys — candles with hour=14.7 and
;;    hour=15.1 produce coincident hour-facts (both round to 15).
;; 6. opposite clock points differ — candles with hour=6 and hour=18
;;    produce NON-coincident hour-facts (Circular's angular encoding
;;    distinguishes opposite points on the 24-period sphere).
;;
;; Pattern: each test runs through run-sandboxed-ast with scope =
;; "wat" so the inner program can load types/* + vocab/shared/time.
;; Same shape as wat-tests/encoding/rhythm.wat established in Phase
;; 3.4.

(:wat::config::set-capacity-mode! :error)
(:wat::config::set-dims! 1024)

;; ─── 1. encode-time-facts returns 5 ───────────────────────────────

(:wat::core::define
  (:trading::test::vocab::shared::time::test-encode-time-facts-count
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-capacity-mode! :error)
      (:wat::config::set-dims! 1024)
      (:wat::core::load! :wat::load::file-path "types/enums.wat")
      (:wat::core::load! :wat::load::file-path "types/newtypes.wat")
      (:wat::core::load! :wat::load::file-path "types/ohlcv.wat")
      (:wat::core::load! :wat::load::file-path "types/distances.wat")
      (:wat::core::load! :wat::load::file-path "types/pivot.wat")
      (:wat::core::load! :wat::load::file-path "types/candle.wat")
      (:wat::core::load! :wat::load::file-path "vocab/shared/time.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((t :trading::types::Candle::Time)
            (:trading::types::Candle::Time/new 30.0 14.0 3.0 15.0 6.0))
           ((facts :Vec<wat::holon::HolonAST>)
            (:trading::vocab::shared::time::encode-time-facts t)))
          (:wat::test::assert-eq
            (:wat::core::length facts)
            5))))
    (:wat::core::vec :String)
    (Some "wat")))

;; ─── 2. time-facts returns 8 ──────────────────────────────────────

(:wat::core::define
  (:trading::test::vocab::shared::time::test-time-facts-count
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-capacity-mode! :error)
      (:wat::config::set-dims! 1024)
      (:wat::core::load! :wat::load::file-path "types/enums.wat")
      (:wat::core::load! :wat::load::file-path "types/newtypes.wat")
      (:wat::core::load! :wat::load::file-path "types/ohlcv.wat")
      (:wat::core::load! :wat::load::file-path "types/distances.wat")
      (:wat::core::load! :wat::load::file-path "types/pivot.wat")
      (:wat::core::load! :wat::load::file-path "types/candle.wat")
      (:wat::core::load! :wat::load::file-path "vocab/shared/time.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((t :trading::types::Candle::Time)
            (:trading::types::Candle::Time/new 30.0 14.0 3.0 15.0 6.0))
           ((facts :Vec<wat::holon::HolonAST>)
            (:trading::vocab::shared::time::time-facts t)))
          (:wat::test::assert-eq
            (:wat::core::length facts)
            8))))
    (:wat::core::vec :String)
    (Some "wat")))

;; ─── 3. hour fact coincides with hand-built shape ─────────────────
;;
;; facts[1] must be Bind(Atom("hour"), Circular(rounded, 24.0)).
;; At candle hour = 14.0, rounded = 14.0; hand-build the expected
;; fact and compare via coincident?.

(:wat::core::define
  (:trading::test::vocab::shared::time::test-hour-fact-shape
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-capacity-mode! :error)
      (:wat::config::set-dims! 1024)
      (:wat::core::load! :wat::load::file-path "types/enums.wat")
      (:wat::core::load! :wat::load::file-path "types/newtypes.wat")
      (:wat::core::load! :wat::load::file-path "types/ohlcv.wat")
      (:wat::core::load! :wat::load::file-path "types/distances.wat")
      (:wat::core::load! :wat::load::file-path "types/pivot.wat")
      (:wat::core::load! :wat::load::file-path "types/candle.wat")
      (:wat::core::load! :wat::load::file-path "vocab/shared/time.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((t :trading::types::Candle::Time)
            (:trading::types::Candle::Time/new 30.0 14.0 3.0 15.0 6.0))
           ((facts :Vec<wat::holon::HolonAST>)
            (:trading::vocab::shared::time::encode-time-facts t))
           ((actual :wat::holon::HolonAST)
            (:wat::core::match (:wat::core::get facts 1) -> :wat::holon::HolonAST
              ((Some h) h)
              (:None (:wat::holon::Atom "unreachable"))))
           ((expected :wat::holon::HolonAST)
            (:wat::holon::Bind
              (:wat::holon::Atom "hour")
              (:wat::holon::Circular 14.0 24.0))))
          (:wat::test::assert-eq
            (:wat::holon::coincident? actual expected)
            true))))
    (:wat::core::vec :String)
    (Some "wat")))

;; ─── 4. minute × hour composition shape ───────────────────────────
;;
;; facts[5] = Bind(minute-bind, hour-bind) — the first pairwise
;; composition in time-facts. Hand-build the same shape from fresh
;; atoms and compare.

(:wat::core::define
  (:trading::test::vocab::shared::time::test-minute-x-hour-composition
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-capacity-mode! :error)
      (:wat::config::set-dims! 1024)
      (:wat::core::load! :wat::load::file-path "types/enums.wat")
      (:wat::core::load! :wat::load::file-path "types/newtypes.wat")
      (:wat::core::load! :wat::load::file-path "types/ohlcv.wat")
      (:wat::core::load! :wat::load::file-path "types/distances.wat")
      (:wat::core::load! :wat::load::file-path "types/pivot.wat")
      (:wat::core::load! :wat::load::file-path "types/candle.wat")
      (:wat::core::load! :wat::load::file-path "vocab/shared/time.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((t :trading::types::Candle::Time)
            (:trading::types::Candle::Time/new 30.0 14.0 3.0 15.0 6.0))
           ((facts :Vec<wat::holon::HolonAST>)
            (:trading::vocab::shared::time::time-facts t))
           ((actual :wat::holon::HolonAST)
            (:wat::core::match (:wat::core::get facts 5) -> :wat::holon::HolonAST
              ((Some h) h)
              (:None (:wat::holon::Atom "unreachable"))))
           ;; Hand-build: Bind(Bind(Atom(minute), Circular(30, 60)),
           ;;                  Bind(Atom(hour),   Circular(14, 24)))
           ((minute-bind :wat::holon::HolonAST)
            (:wat::holon::Bind
              (:wat::holon::Atom "minute")
              (:wat::holon::Circular 30.0 60.0)))
           ((hour-bind :wat::holon::HolonAST)
            (:wat::holon::Bind
              (:wat::holon::Atom "hour")
              (:wat::holon::Circular 14.0 24.0)))
           ((expected :wat::holon::HolonAST)
            (:wat::holon::Bind minute-bind hour-bind)))
          (:wat::test::assert-eq
            (:wat::holon::coincident? actual expected)
            true))))
    (:wat::core::vec :String)
    (Some "wat")))

;; ─── 5. rounding quantizes cache keys ─────────────────────────────
;;
;; Candle times with hour = 14.7 and hour = 15.1 both round to 15.0
;; at digits = 0 (half-away-from-zero). Both produce identical hour
;; facts. The per-site round_to IS cache-key quantization (per
;; proposal 057 + 033); this test proves the quantization is live
;; at the vocab layer.

(:wat::core::define
  (:trading::test::vocab::shared::time::test-close-hours-share-cache-key
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-capacity-mode! :error)
      (:wat::config::set-dims! 1024)
      (:wat::core::load! :wat::load::file-path "types/enums.wat")
      (:wat::core::load! :wat::load::file-path "types/newtypes.wat")
      (:wat::core::load! :wat::load::file-path "types/ohlcv.wat")
      (:wat::core::load! :wat::load::file-path "types/distances.wat")
      (:wat::core::load! :wat::load::file-path "types/pivot.wat")
      (:wat::core::load! :wat::load::file-path "types/candle.wat")
      (:wat::core::load! :wat::load::file-path "vocab/shared/time.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((t-a :trading::types::Candle::Time)
            (:trading::types::Candle::Time/new 30.0 14.7 3.0 15.0 6.0))
           ((t-b :trading::types::Candle::Time)
            (:trading::types::Candle::Time/new 30.0 15.1 3.0 15.0 6.0))
           ((facts-a :Vec<wat::holon::HolonAST>)
            (:trading::vocab::shared::time::encode-time-facts t-a))
           ((facts-b :Vec<wat::holon::HolonAST>)
            (:trading::vocab::shared::time::encode-time-facts t-b))
           ((hour-a :wat::holon::HolonAST)
            (:wat::core::match (:wat::core::get facts-a 1) -> :wat::holon::HolonAST
              ((Some h) h)
              (:None (:wat::holon::Atom "unreachable"))))
           ((hour-b :wat::holon::HolonAST)
            (:wat::core::match (:wat::core::get facts-b 1) -> :wat::holon::HolonAST
              ((Some h) h)
              (:None (:wat::holon::Atom "unreachable")))))
          (:wat::test::assert-eq
            (:wat::holon::coincident? hour-a hour-b)
            true))))
    (:wat::core::vec :String)
    (Some "wat")))

;; ─── 6. opposite clock points differ ──────────────────────────────
;;
;; Candle times with hour = 6.0 and hour = 18.0 sit at opposite
;; points on the 24-period circle. Their Circular encodings are
;; anti-parallel; the hour-fact Binds should NOT coincide. Proves
;; the angular encoding from :wat::holon::Circular is live at this
;; vocab layer.
;;
;; Comparing facts[1] (not the full fact vec) so that identical
;; minute/dow/dom/month components don't dilute the distinction.

(:wat::core::define
  (:trading::test::vocab::shared::time::test-opposite-hours-differ
    -> :wat::kernel::RunResult)
  (:wat::kernel::run-sandboxed-ast
    (:wat::test::program
      (:wat::config::set-capacity-mode! :error)
      (:wat::config::set-dims! 1024)
      (:wat::core::load! :wat::load::file-path "types/enums.wat")
      (:wat::core::load! :wat::load::file-path "types/newtypes.wat")
      (:wat::core::load! :wat::load::file-path "types/ohlcv.wat")
      (:wat::core::load! :wat::load::file-path "types/distances.wat")
      (:wat::core::load! :wat::load::file-path "types/pivot.wat")
      (:wat::core::load! :wat::load::file-path "types/candle.wat")
      (:wat::core::load! :wat::load::file-path "vocab/shared/time.wat")
      (:wat::core::define
        (:user::main
          (stdin  :wat::io::IOReader)
          (stdout :wat::io::IOWriter)
          (stderr :wat::io::IOWriter)
          -> :())
        (:wat::core::let*
          (((t-morning :trading::types::Candle::Time)
            (:trading::types::Candle::Time/new 30.0 6.0 3.0 15.0 6.0))
           ((t-evening :trading::types::Candle::Time)
            (:trading::types::Candle::Time/new 30.0 18.0 3.0 15.0 6.0))
           ((facts-morning :Vec<wat::holon::HolonAST>)
            (:trading::vocab::shared::time::encode-time-facts t-morning))
           ((facts-evening :Vec<wat::holon::HolonAST>)
            (:trading::vocab::shared::time::encode-time-facts t-evening))
           ((hour-morning :wat::holon::HolonAST)
            (:wat::core::match (:wat::core::get facts-morning 1) -> :wat::holon::HolonAST
              ((Some h) h)
              (:None (:wat::holon::Atom "unreachable"))))
           ((hour-evening :wat::holon::HolonAST)
            (:wat::core::match (:wat::core::get facts-evening 1) -> :wat::holon::HolonAST
              ((Some h) h)
              (:None (:wat::holon::Atom "unreachable")))))
          (:wat::test::assert-eq
            (:wat::holon::coincident? hour-morning hour-evening)
            false))))
    (:wat::core::vec :String)
    (Some "wat")))
