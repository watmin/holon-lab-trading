;; wat/main.wat — holon-lab-trading's entry file.
;;
;; Phase 0 scaffold (2026-04-22). Commits startup config + defines
;; `:user::main` with a hello-world body to prove the wiring end-to-end
;; (the two Rust files + Cargo + wat-rs all compose cleanly). Later
;; phases add `(:wat::core::load-file!)` calls for the lab's tree under
;; `:trading::*` — types, vocab, encoding, learning, domain,
;; orchestration.
;;
;; See `docs/rewrite-backlog.md` for the leaves-to-root build order.

(:wat::config::set-dims! 10000)
(:wat::config::set-capacity-mode! :error)

;; Phase 1 — types
(:wat::core::load-file! "types/enums.wat")
(:wat::core::load-file! "types/newtypes.wat")
(:wat::core::load-file! "types/ohlcv.wat")
(:wat::core::load-file! "types/distances.wat")
(:wat::core::load-file! "types/pivot.wat")
(:wat::core::load-file! "types/candle.wat")

;; Phase 3 — encoding helpers
(:wat::core::load-file! "encoding/round.wat")
(:wat::core::load-file! "encoding/scale_tracker.wat")
(:wat::core::load-file! "encoding/scaled_linear.wat")
(:wat::core::load-file! "encoding/rhythm.wat")

;; Phase 2 — vocab (lab arc 001 opens: shared/time)
(:wat::core::load-file! "vocab/shared/time.wat")

(:wat::core::define (:user::main
                     (stdin  :wat::io::IOReader)
                     (stdout :wat::io::IOWriter)
                     (stderr :wat::io::IOWriter)
                     -> :())
  (:wat::io::IOWriter/println stdout "holon-lab-trading scaffold is alive"))
