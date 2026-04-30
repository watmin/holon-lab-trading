;; Investigation probes — narrow down where the type variable
;; resolution breaks in the lab harness post-arc-071.
;; All bodies end in assert-eq → :() to keep test-body type honest.

(:wat::test::make-deftest :deftest
  ((:wat::core::define
     (:my::test::count-visit
       (acc :wat::core::i64)
       (form :wat::WatAST)
       (step :wat::eval::StepResult)
       -> :wat::eval::WalkStep<i64>)
     (:wat::eval::WalkStep::Continue (:wat::core::i64::+ acc 1)))))


;; Probe A — bare tuple destructure with explicit type. Sanity.
(:deftest :probe::a-tuple-destructure-baseline
  (:wat::core::let*
    (((pair :(i64,i64)) (:wat::core::tuple 7 11))
     ((y :wat::core::i64) (:wat::core::second pair)))
    (:wat::test::assert-eq y 11)))


;; Probe B — Result destructure with explicit type. Does match
;; propagate the Ok-payload type from the let*-bound annotation
;; into the (Ok pair) pattern's binding?
(:deftest :probe::b-result-with-tuple-payload
  (:wat::core::let*
    (((wrapped :Result<(i64,i64),i64>)
      (Ok (:wat::core::tuple 7 11)))
     ((extracted :wat::core::i64)
      (:wat::core::match wrapped -> :wat::core::i64
        ((Ok pair) (:wat::core::second pair))
        ((Err _) -1))))
    (:wat::test::assert-eq extracted 11)))


;; Probe B' — Workaround attempt 1: annotate the pattern variable
;; directly inside the Ok constructor.
(:deftest :probe::b1-pattern-annotated
  (:wat::core::let*
    (((wrapped :Result<(i64,i64),i64>)
      (Ok (:wat::core::tuple 7 11)))
     ((extracted :wat::core::i64)
      (:wat::core::match wrapped -> :wat::core::i64
        ((Ok (pair :(i64,i64))) (:wat::core::second pair))
        ((Err _) -1))))
    (:wat::test::assert-eq extracted 11)))


;; Probe B'' — Workaround attempt 2: pattern-destructure inline
;; (no named binding for the tuple, just the elements).
(:deftest :probe::b2-pattern-destructure-inline
  (:wat::core::let*
    (((wrapped :Result<(i64,i64),i64>)
      (Ok (:wat::core::tuple 7 11)))
     ((extracted :wat::core::i64)
      (:wat::core::match wrapped -> :wat::core::i64
        ((Ok (a b)) b)
        ((Err _) -1))))
    (:wat::test::assert-eq extracted 11)))


;; Probe C — walk's actual return type, no destructure;
;; just check the match against Ok/Err works at all.
(:deftest :probe::c-walk-returns-ok-or-err
  (:wat::core::let*
    (((form :wat::WatAST)
      (:wat::core::quote
        (:wat::holon::Bind
          (:wat::holon::Atom "k")
          (:wat::holon::Atom "v"))))
     ((tag :wat::core::i64)
      (:wat::core::match
        (:wat::eval::walk form 0 :my::test::count-visit)
        -> :wat::core::i64
        ((Ok _) 1)
        ((Err _) -1))))
    (:wat::test::assert-eq tag 1)))


;; Probe D — walk + destructure. Mirrors USER-GUIDE shape.
(:deftest :probe::d-walk-destructure-inline
  (:wat::core::let*
    (((form :wat::WatAST)
      (:wat::core::quote
        (:wat::holon::Bind
          (:wat::holon::Atom "k")
          (:wat::holon::Atom "v"))))
     ((count :wat::core::i64)
      (:wat::core::match
        (:wat::eval::walk form 0 :my::test::count-visit)
        -> :wat::core::i64
        ((Ok pair) (:wat::core::second pair))
        ((Err _e) -1))))
    (:wat::test::assert-eq count 1)))
