;; wat-tests/test-scaffold.wat — Phase 0 placeholder.
;;
;; Proves the `wat::test! {}` minimal form wires end-to-end + that
;; a `:trading::*`-namespaced `test-*` define registers cleanly
;; (first real use of the app-owned top-level root documented in
;; wat-rs/docs/CONVENTIONS.md's "App-owned top-level roots"
;; subsection, arc 018 follow-up).
;;
;; Replaced in Phase 9 with the real integration-test ports from
;; `archived/pre-wat-native/tests/`.

(:wat::config::set-dims! 1024)
(:wat::config::set-capacity-mode! :error)

(:wat::test::deftest :trading::test::test-scaffold-is-alive
  ()
  (:wat::test::assert-eq (:wat::core::i64::+ 1 1) 2))
