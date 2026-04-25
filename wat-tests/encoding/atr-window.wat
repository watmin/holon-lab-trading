;; wat-tests/encoding/atr-window.wat — Lab arc 025 slice 1 tests.
;;
;; Tests :trading::encoding::AtrWindow (::fresh, ::push, ::median,
;; ::full?) against its source at wat/encoding/atr-window.wat.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/atr-window.wat")))

;; ─── ::median — empty buffer is :None ──────────────────────────────

(:deftest :trading::test::encoding::atr-window::test-median-empty-is-none
  (:wat::core::let*
    (((w :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::fresh 4))
     ((m :Option<f64>)
      (:trading::encoding::AtrWindow::median w))
     ((sentinel :f64)
      (:wat::core::match m -> :f64
        ((Some _) -1.0)
        (:None 999.0))))
    (:wat::test::assert-eq sentinel 999.0)))

;; ─── ::median — odd length ─────────────────────────────────────────

;; Push 1.0, 3.0, 2.0 → sorted [1.0, 2.0, 3.0] → median 2.0.
(:deftest :trading::test::encoding::atr-window::test-median-odd-length
  (:wat::core::let*
    (((w0 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::fresh 8))
     ((w1 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::push w0 1.0))
     ((w2 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::push w1 3.0))
     ((w3 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::push w2 2.0))
     ((m :Option<f64>)
      (:trading::encoding::AtrWindow::median w3))
     ((mv :f64)
      (:wat::core::match m -> :f64
        ((Some v) v)
        (:None -1.0))))
    (:wat::test::assert-eq mv 2.0)))

;; ─── ::median — even length ────────────────────────────────────────

;; Push 1.0, 4.0, 2.0, 3.0 → sorted [1, 2, 3, 4] → median (2+3)/2 = 2.5.
(:deftest :trading::test::encoding::atr-window::test-median-even-length
  (:wat::core::let*
    (((w0 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::fresh 8))
     ((w1 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::push w0 1.0))
     ((w2 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::push w1 4.0))
     ((w3 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::push w2 2.0))
     ((w4 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::push w3 3.0))
     ((m :Option<f64>)
      (:trading::encoding::AtrWindow::median w4))
     ((mv :f64)
      (:wat::core::match m -> :f64
        ((Some v) v)
        (:None -1.0))))
    (:wat::test::assert-eq mv 2.5)))

;; ─── ::push — capacity-bounded eviction ────────────────────────────

;; Capacity 3. Push 1, 2, 3, 4 → values should be [2, 3, 4]; median 3.
(:deftest :trading::test::encoding::atr-window::test-push-evicts-oldest-at-capacity
  (:wat::core::let*
    (((w0 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::fresh 3))
     ((w1 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::push w0 1.0))
     ((w2 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::push w1 2.0))
     ((w3 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::push w2 3.0))
     ((w4 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::push w3 4.0))
     ((len :i64)
      (:wat::core::length (:trading::encoding::AtrWindow/values w4)))
     ((m :Option<f64>)
      (:trading::encoding::AtrWindow::median w4))
     ((mv :f64)
      (:wat::core::match m -> :f64
        ((Some v) v)
        (:None -1.0))))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq len 3)))
      (:wat::test::assert-eq mv 3.0))))

;; ─── ::full? — false until at capacity ────────────────────────────

(:deftest :trading::test::encoding::atr-window::test-full-gate
  (:wat::core::let*
    (((w0 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::fresh 3))
     ((empty? :bool)
      (:trading::encoding::AtrWindow::full? w0))
     ((w1 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::push w0 1.0))
     ((w2 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::push w1 2.0))
     ((not-yet? :bool)
      (:trading::encoding::AtrWindow::full? w2))
     ((w3 :trading::encoding::AtrWindow)
      (:trading::encoding::AtrWindow::push w2 3.0))
     ((full? :bool)
      (:trading::encoding::AtrWindow::full? w3)))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq empty? false))
       ((u2 :()) (:wat::test::assert-eq not-yet? false)))
      (:wat::test::assert-eq full? true))))

;; ─── WEEK constant ─────────────────────────────────────────────────

(:deftest :trading::test::encoding::atr-window::test-week-is-2016
  (:wat::test::assert-eq
    (:trading::encoding::AtrWindow::WEEK)
    2016))
