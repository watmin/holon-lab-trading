;; wat-tests-integ/experiment/009-cryptographic-substrate/explore-directed.wat
;;
;; The directed-evaluation arc as runnable proofs. The forms-to-values
;; relation is a directed graph; values don't determine forms. The
;; substrate's directionality enables both symmetric (seed-as-key,
;; AES-shaped) and asymmetric (form-as-preimage-knowledge,
;; signature-shaped) cryptographic constructions. This file walks the
;; demonstration step by step.
;;
;; T1 — many-forms-one-value (smallest demonstration)
;; T2 — three+ forms producing the same value, pairwise distinct
;; T3 — universe isolation: same form, different seeds, different values
;; T4 — two-factor verification: only (seed_K, form_F) recovers V
;;
;; ── Form-size budget ───────────────────────────────────────────
;; Forms in this experiment are budgeted at ≤100 statements each per
;; Kanerva capacity (Ch 28's slack lemma + Ch 61's adjacent
;; infinities). Beyond ~100 reliable items per 10k-D vector under the
;; cosine threshold, encoding interference would corrupt the
;; cryptographic claims. Each individual form below is well under
;; that ceiling.

(:wat::test::make-deftest :deftest
  (;; Round-trip helper: take an atom-wrapped form, unwrap one layer
   ;; (atom-value → inner HolonAST), lift to WatAST (to-watast),
   ;; evaluate (eval-ast! → Result<HolonAST, EvalError>), and on
   ;; success extract the inner i64 leaf via atom-value.
   ;;
   ;; This is the unquote-and-eval chain made into one helper so the
   ;; deftests below can read cleanly. -1 sentinel on Err — tests
   ;; expect Ok for their forms.
   ;; T10's three-factor verify primitive — given V's bytes and a
   ;; candidate form, returns true iff the form encoded under the
   ;; current universe (K is config-time) coincides with the bytes-
   ;; reconstructed Vector. False on any mismatch (form, V, bytes).
   ;; This IS the cryptographic verification API in one function.
   (:wat::core::define
     (:exp::verify
       (v-bytes :wat::core::Bytes)
       (form :wat::holon::HolonAST)
       -> :bool)
     (:wat::core::match (:wat::holon::bytes-vector v-bytes) -> :bool
       ((Some v) (:wat::holon::coincident? form v))
       (:None false)))

   ;; Round-trip an atom-stored form back to its evaluated i64 value.
   ;;
   ;; SUBSTRATE NOTE — corrected 2026-04-29 via arc 102:
   ;;
   ;;   - arc 065 split polymorphic Atom into honest constructors.
   ;;     Forms (quoted lists) use `:wat::holon::from-watast`, making
   ;;     the structural-lowering move explicit at the call site.
   ;;   - arc 102 made eval-ast! polymorphic in its return scheme:
   ;;     `:wat::WatAST -> :Result<:T, :wat::core::EvalError>`. For a
   ;;     form whose terminal value is i64, the Ok arm binds the bare
   ;;     i64 directly — no atom-value extraction needed.
   ;;
   ;; The chain: HolonAST → to-watast → eval-ast! → Ok(i64) → i64.
   ;; Each step honest about its inputs and outputs.
   (:wat::core::define
     (:exp::form->i64 (form :wat::holon::HolonAST) -> :i64)
     (:wat::core::match
       (:wat::eval-ast! (:wat::holon::to-watast form))
       -> :i64
       ((Ok v) v)
       ((Err _) -1)))))


;; ─── T1 — many-forms-one-value ───────────────────────────────
;;
;; Two distinct expressions, (+ 2 2) and (* 1 4), encode as
;; structurally distinct HolonAST atoms (NOT coincident in the
;; algebra grid) but evaluate to the same i64 value (4). The
;; directed-graph property in its smallest demonstration: forms
;; differ, terminals coincide.

(:deftest :exp::t1-many-forms-one-value
  (:wat::core::let*
    (;; Forms-as-atoms — captured via Atom + quote so the form's
     ;; structural identity becomes a lattice coordinate (per Ch 54).
     ;; Each form is defined ONCE here; values come from running
     ;; the unquote-and-eval round trip on these same atoms.
     ((form-a :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((form-b :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::* 1 4))))

     ;; Sanity: each form is coincident with itself.
     ((_self-a :()) (:wat::test::assert-coincident form-a form-a))
     ((_self-b :()) (:wat::test::assert-coincident form-b form-b))

     ;; The directed-graph claim, structural side: forms differ.
     ;; coincident? wraps the slack-lemma floor predicate (Ch 23, Ch 28).
     ((cross :bool) (:wat::holon::coincident? form-a form-b))
     ((_diff :()) (:wat::test::assert-eq cross false))

     ;; The directed-graph claim, terminal side: round-trip each
     ;; atom-stored form through unquote-and-eval. Same forms,
     ;; defined once above; values come from running them.
     ((value-a :i64) (:exp::form->i64 form-a))
     ((value-b :i64) (:exp::form->i64 form-b)))
    (:wat::test::assert-eq value-a value-b)))


;; ─── T2 — three forms, one value, pairwise distinct ──────────
;;
;; Generalize T1: three structurally-distinct forms, all evaluating
;; to the same i64 value (4). Pairwise coincident? checks confirm
;; each pair is geometrically distinct. The lattice has at LEAST
;; three nodes pointing at the value 4; in principle, unbounded
;; many. The directed-graph claim from beat 1 made concrete.
;;
;; Also includes a STRUCTURAL EQUALITY positive control: two atoms
;; built from the same quoted form coincide, even though they were
;; constructed by separate Atom calls. This is arc 057's structural
;; Hash + Eq — the substrate hashes canonical bytes deterministically.

(:deftest :exp::t2-three-forms-one-value
  (:wat::core::let*
    (((form-a :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((form-b :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::* 1 4))))
     ((form-c :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::- 5 1))))

     ;; Structural equality control — same quoted form, same atom.
     ((form-a-again :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((_struct :()) (:wat::test::assert-coincident form-a form-a-again))

     ;; Pairwise distinctness — three pairs, all expected to differ.
     ((ab :bool) (:wat::holon::coincident? form-a form-b))
     ((bc :bool) (:wat::holon::coincident? form-b form-c))
     ((ac :bool) (:wat::holon::coincident? form-a form-c))
     ((_d-ab :()) (:wat::test::assert-eq ab false))
     ((_d-bc :()) (:wat::test::assert-eq bc false))
     ((_d-ac :()) (:wat::test::assert-eq ac false))

     ;; Terminal coincidence — all three forms unquote-and-eval
     ;; to the same value 4. Same atoms defined above; no parallel
     ;; re-write of the source forms.
     ((value-a :i64) (:exp::form->i64 form-a))
     ((value-b :i64) (:exp::form->i64 form-b))
     ((value-c :i64) (:exp::form->i64 form-c))
     ((_eq-ab :()) (:wat::test::assert-eq value-a value-b))
     ((_eq-bc :()) (:wat::test::assert-eq value-b value-c)))
    (:wat::test::assert-eq value-a value-c)))


;; ─── T3 — universe isolation via seed swap (hermetic) ────────
;;
;; Same form encoded under different global seeds produces
;; coordinate-different vectors. Child 1 runs the inner program
;; under seed 42; child 2 under seed 99. Each encodes the SAME
;; pair of forms (form-a sharing structure with form-b), computes
;; cosine, prints it. The printed cosines should DIFFER — same
;; structural relation, different basis, different cosine value.
;;
;; Hermetic forks isolate each universe: each child has its own
;; config, its own VectorManager, its own basis. Per Ch 61, "Seed
;; 42 is one universe; seed 43 is another." We are running both
;; universes side by side and showing they agree on STRUCTURE
;; while disagreeing on COORDINATES.

(:deftest :exp::t3-universe-isolation
  (:wat::core::let*
    (;; Child running under seed 42 — encodes (+ 2 2) and (+ 3 3),
     ;; prints cosine to stdout.
     ((r-42 :wat::kernel::RunResult)
      (:wat::test::run-hermetic-ast
        (:wat::test::program
          (:wat::config::set-global-seed! 42)
          (:wat::core::define
            (:user::main (stdin  :wat::io::IOReader)
                         (stdout :wat::io::IOWriter)
                         (stderr :wat::io::IOWriter)
                         -> :())
            (:wat::core::let*
              (((form-a :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
               ((form-b :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 3 3))))
               ((cos-ab :f64) (:wat::holon::cosine form-a form-b)))
              (:wat::io::IOWriter/print stdout
                (:wat::core::f64::to-string cos-ab)))))
        (:wat::core::vec :String)))

     ;; Child running under seed 99 — same forms, different universe.
     ((r-99 :wat::kernel::RunResult)
      (:wat::test::run-hermetic-ast
        (:wat::test::program
          (:wat::config::set-global-seed! 99)
          (:wat::core::define
            (:user::main (stdin  :wat::io::IOReader)
                         (stdout :wat::io::IOWriter)
                         (stderr :wat::io::IOWriter)
                         -> :())
            (:wat::core::let*
              (((form-a :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
               ((form-b :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 3 3))))
               ((cos-ab :f64) (:wat::holon::cosine form-a form-b)))
              (:wat::io::IOWriter/print stdout
                (:wat::core::f64::to-string cos-ab)))))
        (:wat::core::vec :String)))

     ;; Extract first printed line from each child.
     ((cos-42 :String)
      (:wat::core::match (:wat::core::first (:wat::kernel::RunResult/stdout r-42)) -> :String
        ((Some s) s)
        (:None "<missing-42>")))
     ((cos-99 :String)
      (:wat::core::match (:wat::core::first (:wat::kernel::RunResult/stdout r-99)) -> :String
        ((Some s) s)
        (:None "<missing-99>")))

     ;; Universe isolation claim: the cosines printed under different
     ;; seeds are not the same value. (If they were, the two universes
     ;; would happen to agree on this specific encoding — astronomically
     ;; unlikely at d=10000.)
     ((differ :bool) (:wat::core::not= cos-42 cos-99)))
    (:wat::test::assert-eq differ true)))


;; ─── T4 — replay determinism (same seed → same output) ───────
;;
;; The symmetric foundation of T3. T3 asserted that different seeds
;; produce different cosines (universe isolation, the negative
;; claim). T4 asserts the positive: same seed + same form produces
;; the SAME cosine, every time, across processes.
;;
;; Without replay determinism, T3's inequality would be meaningless —
;; outputs would just be random noise. Determinism is what makes
;; verification possible: the recipient with (seed_K, form_F) can
;; compute the SAME cosine the originator computed, and check it
;; against a published commitment.
;;
;; Two hermetic children, both with seed 42, both encoding the same
;; pair of forms. Their printed cosines must match exactly.

(:deftest :exp::t4-replay-determinism
  (:wat::core::let*
    (;; Child A — seed 42, encode (+ 2 2) and (+ 3 3), print cosine.
     ((r-a :wat::kernel::RunResult)
      (:wat::test::run-hermetic-ast
        (:wat::test::program
          (:wat::config::set-global-seed! 42)
          (:wat::core::define
            (:user::main (stdin  :wat::io::IOReader)
                         (stdout :wat::io::IOWriter)
                         (stderr :wat::io::IOWriter)
                         -> :())
            (:wat::core::let*
              (((form-a :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
               ((form-b :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 3 3))))
               ((cos-ab :f64) (:wat::holon::cosine form-a form-b)))
              (:wat::io::IOWriter/print stdout
                (:wat::core::f64::to-string cos-ab)))))
        (:wat::core::vec :String)))

     ;; Child B — same seed, same forms, separate process.
     ((r-b :wat::kernel::RunResult)
      (:wat::test::run-hermetic-ast
        (:wat::test::program
          (:wat::config::set-global-seed! 42)
          (:wat::core::define
            (:user::main (stdin  :wat::io::IOReader)
                         (stdout :wat::io::IOWriter)
                         (stderr :wat::io::IOWriter)
                         -> :())
            (:wat::core::let*
              (((form-a :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
               ((form-b :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 3 3))))
               ((cos-ab :f64) (:wat::holon::cosine form-a form-b)))
              (:wat::io::IOWriter/print stdout
                (:wat::core::f64::to-string cos-ab)))))
        (:wat::core::vec :String)))

     ((cos-a :String)
      (:wat::core::match (:wat::core::first (:wat::kernel::RunResult/stdout r-a)) -> :String
        ((Some s) s)
        (:None "<missing-a>")))
     ((cos-b :String)
      (:wat::core::match (:wat::core::first (:wat::kernel::RunResult/stdout r-b)) -> :String
        ((Some s) s)
        (:None "<missing-b>")))

     ;; Replay determinism claim: same seed + same form across two
     ;; processes produces the SAME cosine value, character-for-character.
     ((same :bool) (:wat::core::= cos-a cos-b)))
    (:wat::test::assert-eq same true)))


;; ─── T5 — two-factor verification (the synthesis) ────────────
;;
;; The cryptographic synthesis. T3 proved different seeds → different
;; outputs. T4 proved same seed → same output. T1/T2 proved different
;; forms → different atoms. T5 combines them: only the matching
;; (seed, form) pair recovers the reference cosine. Either factor
;; wrong is enough to break the verification.
;;
;; Three hermetic children:
;;   1. (seed 42, form-correct, anchor) — the reference
;;   2. (seed 99, form-correct, anchor) — wrong seed (right form)
;;   3. (seed 42, form-wrong,   anchor) — wrong form (right seed)
;;
;; Assert reference differs from BOTH the wrong-seed and wrong-form
;; runs. The cryptographic claim: an attacker who has only one factor
;; cannot reproduce the reference. Both must be right; either alone
;; is operationally insufficient.

(:deftest :exp::t5-two-factor-verification
  (:wat::core::let*
    (;; Child 1 — reference: seed 42, correct form (+ 2 2) vs anchor (+ 3 3).
     ((r-ref :wat::kernel::RunResult)
      (:wat::test::run-hermetic-ast
        (:wat::test::program
          (:wat::config::set-global-seed! 42)
          (:wat::core::define
            (:user::main (stdin  :wat::io::IOReader)
                         (stdout :wat::io::IOWriter)
                         (stderr :wat::io::IOWriter)
                         -> :())
            (:wat::core::let*
              (((form-correct :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
               ((anchor :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 3 3))))
               ((cos :f64) (:wat::holon::cosine form-correct anchor)))
              (:wat::io::IOWriter/print stdout
                (:wat::core::f64::to-string cos)))))
        (:wat::core::vec :String)))

     ;; Child 2 — wrong seed: seed 99, correct form, same anchor.
     ((r-wrong-seed :wat::kernel::RunResult)
      (:wat::test::run-hermetic-ast
        (:wat::test::program
          (:wat::config::set-global-seed! 99)
          (:wat::core::define
            (:user::main (stdin  :wat::io::IOReader)
                         (stdout :wat::io::IOWriter)
                         (stderr :wat::io::IOWriter)
                         -> :())
            (:wat::core::let*
              (((form-correct :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
               ((anchor :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 3 3))))
               ((cos :f64) (:wat::holon::cosine form-correct anchor)))
              (:wat::io::IOWriter/print stdout
                (:wat::core::f64::to-string cos)))))
        (:wat::core::vec :String)))

     ;; Child 3 — wrong form: seed 42, but a structurally different form.
     ((r-wrong-form :wat::kernel::RunResult)
      (:wat::test::run-hermetic-ast
        (:wat::test::program
          (:wat::config::set-global-seed! 42)
          (:wat::core::define
            (:user::main (stdin  :wat::io::IOReader)
                         (stdout :wat::io::IOWriter)
                         (stderr :wat::io::IOWriter)
                         -> :())
            (:wat::core::let*
              (;; Different operator + different operands — clearly distinct
               ;; from form-correct's structural shape.
               ((form-wrong :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::- 100 1))))
               ((anchor :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 3 3))))
               ((cos :f64) (:wat::holon::cosine form-wrong anchor)))
              (:wat::io::IOWriter/print stdout
                (:wat::core::f64::to-string cos)))))
        (:wat::core::vec :String)))

     ((cos-ref :String)
      (:wat::core::match (:wat::core::first (:wat::kernel::RunResult/stdout r-ref)) -> :String
        ((Some s) s)
        (:None "<missing-ref>")))
     ((cos-wrong-seed :String)
      (:wat::core::match (:wat::core::first (:wat::kernel::RunResult/stdout r-wrong-seed)) -> :String
        ((Some s) s)
        (:None "<missing-wrong-seed>")))
     ((cos-wrong-form :String)
      (:wat::core::match (:wat::core::first (:wat::kernel::RunResult/stdout r-wrong-form)) -> :String
        ((Some s) s)
        (:None "<missing-wrong-form>")))

     ;; Two-factor claim: reference does NOT match either failure mode.
     ((seed-attack-fails :bool) (:wat::core::not= cos-ref cos-wrong-seed))
     ((form-attack-fails :bool) (:wat::core::not= cos-ref cos-wrong-form))
     ((_seed-check :()) (:wat::test::assert-eq seed-attack-fails true)))
    (:wat::test::assert-eq form-attack-fails true)))


;; ─── T6 — full verification protocol (match + fail) ──────────
;;
;; The complete protocol picture. T5 asserted FAILURE modes (wrong
;; seed differs, wrong form differs) but didn't explicitly assert
;; that the CORRECT credentials match the reference. T6 lifts the
;; verification into a four-child protocol with all three claims:
;;
;;   1. reference     — Alice publishes V (the commitment)
;;   2. right creds   — Bob with (seed_42, form-correct) → MUST MATCH V
;;   3. wrong seed    — attacker with (seed_99, form-correct) → must NOT match
;;   4. wrong form    — attacker with (seed_42, form-wrong) → must NOT match
;;
;; The protocol now reads as a real cryptographic primitive:
;;   - Commitment + correct credentials → verified
;;   - Commitment + wrong credentials   → rejected
;;   - Either factor wrong → rejected
;;
;; This is the foundation for any system that wants to prove
;; "I know the form that produces V" without revealing F directly
;; until verification time.

(:deftest :exp::t6-full-protocol
  (:wat::core::let*
    (;; Child 1 — Alice's commitment under (seed 42, form-correct).
     ((r-ref :wat::kernel::RunResult)
      (:wat::test::run-hermetic-ast
        (:wat::test::program
          (:wat::config::set-global-seed! 42)
          (:wat::core::define
            (:user::main (stdin  :wat::io::IOReader)
                         (stdout :wat::io::IOWriter)
                         (stderr :wat::io::IOWriter)
                         -> :())
            (:wat::core::let*
              (((form-correct :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
               ((anchor :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 3 3))))
               ((cos :f64) (:wat::holon::cosine form-correct anchor)))
              (:wat::io::IOWriter/print stdout
                (:wat::core::f64::to-string cos)))))
        (:wat::core::vec :String)))

     ;; Child 2 — verifier with CORRECT credentials. Must match.
     ((r-correct :wat::kernel::RunResult)
      (:wat::test::run-hermetic-ast
        (:wat::test::program
          (:wat::config::set-global-seed! 42)
          (:wat::core::define
            (:user::main (stdin  :wat::io::IOReader)
                         (stdout :wat::io::IOWriter)
                         (stderr :wat::io::IOWriter)
                         -> :())
            (:wat::core::let*
              (((form-correct :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
               ((anchor :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 3 3))))
               ((cos :f64) (:wat::holon::cosine form-correct anchor)))
              (:wat::io::IOWriter/print stdout
                (:wat::core::f64::to-string cos)))))
        (:wat::core::vec :String)))

     ;; Child 3 — attacker with WRONG SEED. Must not match.
     ((r-wrong-seed :wat::kernel::RunResult)
      (:wat::test::run-hermetic-ast
        (:wat::test::program
          (:wat::config::set-global-seed! 99)
          (:wat::core::define
            (:user::main (stdin  :wat::io::IOReader)
                         (stdout :wat::io::IOWriter)
                         (stderr :wat::io::IOWriter)
                         -> :())
            (:wat::core::let*
              (((form-correct :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
               ((anchor :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 3 3))))
               ((cos :f64) (:wat::holon::cosine form-correct anchor)))
              (:wat::io::IOWriter/print stdout
                (:wat::core::f64::to-string cos)))))
        (:wat::core::vec :String)))

     ;; Child 4 — attacker with WRONG FORM. Must not match.
     ((r-wrong-form :wat::kernel::RunResult)
      (:wat::test::run-hermetic-ast
        (:wat::test::program
          (:wat::config::set-global-seed! 42)
          (:wat::core::define
            (:user::main (stdin  :wat::io::IOReader)
                         (stdout :wat::io::IOWriter)
                         (stderr :wat::io::IOWriter)
                         -> :())
            (:wat::core::let*
              (((form-wrong :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::- 100 1))))
               ((anchor :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 3 3))))
               ((cos :f64) (:wat::holon::cosine form-wrong anchor)))
              (:wat::io::IOWriter/print stdout
                (:wat::core::f64::to-string cos)))))
        (:wat::core::vec :String)))

     ;; Extract the four printed cosines.
     ((v-ref :String)
      (:wat::core::match (:wat::core::first (:wat::kernel::RunResult/stdout r-ref)) -> :String
        ((Some s) s)
        (:None "<missing-ref>")))
     ((v-correct :String)
      (:wat::core::match (:wat::core::first (:wat::kernel::RunResult/stdout r-correct)) -> :String
        ((Some s) s)
        (:None "<missing-correct>")))
     ((v-wrong-seed :String)
      (:wat::core::match (:wat::core::first (:wat::kernel::RunResult/stdout r-wrong-seed)) -> :String
        ((Some s) s)
        (:None "<missing-wrong-seed>")))
     ((v-wrong-form :String)
      (:wat::core::match (:wat::core::first (:wat::kernel::RunResult/stdout r-wrong-form)) -> :String
        ((Some s) s)
        (:None "<missing-wrong-form>")))

     ;; The three protocol claims:
     ;;   correct credentials VERIFY
     ((verified :bool) (:wat::core::= v-ref v-correct))
     ;;   wrong seed REJECTED
     ((seed-rejected :bool) (:wat::core::not= v-ref v-wrong-seed))
     ;;   wrong form REJECTED
     ((form-rejected :bool) (:wat::core::not= v-ref v-wrong-form))

     ((_v :()) (:wat::test::assert-eq verified true))
     ((_s :()) (:wat::test::assert-eq seed-rejected true)))
    (:wat::test::assert-eq form-rejected true)))


;; ─── T7 — vector serialization + mixed-cosine verification ────
;;
;; Arc 061 shipped the substrate primitives that lift vectors into
;; first-class portable artifacts:
;;   - :wat::holon::vector-bytes (Vector → :Vec<u8>)
;;   - :wat::holon::bytes-vector (:Vec<u8> → :Option<Vector>)
;;   - :wat::holon::coincident? polymorphic (HolonAST | Vector)
;;
;; T7 demonstrates the verification protocol end-to-end using these
;; primitives, in-process. Alice encodes form-correct → V → bytes;
;; "Bob" deserializes the bytes → V_imported; verifies via mixed
;; coincident?(form-correct, V_imported). Same universe (current),
;; round-trip preserves the vector, mixed-cosine API is the minimal
;; verification call.

(:deftest :exp::t7-vector-round-trip-verify
  (:wat::core::let*
    (((form-correct :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((v-alice :wat::holon::Vector) (:wat::holon::encode form-correct))

     ;; Serialize — Alice publishes V as bytes.
     ((bytes :Vec<u8>) (:wat::holon::vector-bytes v-alice))

     ;; Deserialize — Bob imports the bytes back to a Vector.
     ((v-imported-opt :Option<wat::holon::Vector>)
      (:wat::holon::bytes-vector bytes)))
    (:wat::core::match v-imported-opt -> :()
      ((Some v-imported)
        (:wat::core::let*
          (;; Round-trip: imported V coincides with original V.
           ((round-trip :bool) (:wat::holon::coincident? v-alice v-imported))
           ((_rt :()) (:wat::test::assert-eq round-trip true))
           ;; Mixed-cosine verification: HolonAST × Vector polymorphism.
           ;; This IS the verification primitive — one coincident?
           ;; call confirms F → V_imported under the current universe.
           ((verified :bool) (:wat::holon::coincident? form-correct v-imported)))
          (:wat::test::assert-eq verified true)))
      (:None (:wat::test::assert-eq "bytes-vector returned :None — round-trip broken" "ok")))))


;; ─── T8 — universe-binding via cross-process hex transmission ─
;;
;; Beat 4 made empirical. A vector encoded in one universe is
;; OPERATIONALLY INERT in another — even if the bytes survive
;; transmission. Two hermetic children encode the SAME form under
;; DIFFERENT seeds; each writes its vector as hex to stdout. Parent
;; reads both, decodes hex → bytes → Vector, then encodes the same
;; form locally (in the parent's seed-42 universe) and tests:
;;
;;   coincident?(V_a_imported, V_local) → TRUE   (same universe)
;;   coincident?(V_b_imported, V_local) → FALSE  (different universe)
;;
;; The bytes survived hex transmission cleanly. The vectors
;; reconstructed identically. But the universe-binding makes them
;; geometrically incompatible — V_b's bits are seed_99's encoding
;; of the form, which doesn't match seed_42's encoding of the same
;; form, even when the structural form is identical.
;;
;; The chain: encode → vector-bytes → to-hex → transmit →
;;             from-hex → bytes-vector → coincident?

(:deftest :exp::t8-universe-binding-via-bytes
  (:wat::core::let*
    (;; Child A — seed 42, encode form, write hex to stdout.
     ((r-a :wat::kernel::RunResult)
      (:wat::test::run-hermetic-ast
        (:wat::test::program
          (:wat::config::set-global-seed! 42)
          (:wat::core::define
            (:user::main (stdin  :wat::io::IOReader)
                         (stdout :wat::io::IOWriter)
                         (stderr :wat::io::IOWriter)
                         -> :())
            (:wat::core::let*
              (((form :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
               ((v :wat::holon::Vector) (:wat::holon::encode form))
               ((bytes :wat::core::Bytes) (:wat::holon::vector-bytes v))
               ((hex :String) (:wat::core::Bytes::to-hex bytes)))
              (:wat::io::IOWriter/print stdout hex))))
        (:wat::core::vec :String)))

     ;; Child B — seed 99, same form, hex to stdout.
     ((r-b :wat::kernel::RunResult)
      (:wat::test::run-hermetic-ast
        (:wat::test::program
          (:wat::config::set-global-seed! 99)
          (:wat::core::define
            (:user::main (stdin  :wat::io::IOReader)
                         (stdout :wat::io::IOWriter)
                         (stderr :wat::io::IOWriter)
                         -> :())
            (:wat::core::let*
              (((form :wat::holon::HolonAST)
                (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
               ((v :wat::holon::Vector) (:wat::holon::encode form))
               ((bytes :wat::core::Bytes) (:wat::holon::vector-bytes v))
               ((hex :String) (:wat::core::Bytes::to-hex bytes)))
              (:wat::io::IOWriter/print stdout hex))))
        (:wat::core::vec :String)))

     ;; Extract hex strings from each child's first stdout line.
     ((hex-a :String)
      (:wat::core::match (:wat::core::first (:wat::kernel::RunResult/stdout r-a)) -> :String
        ((Some s) s)
        (:None "<missing-a>")))
     ((hex-b :String)
      (:wat::core::match (:wat::core::first (:wat::kernel::RunResult/stdout r-b)) -> :String
        ((Some s) s)
        (:None "<missing-b>"))))
    ;; Decode hex → bytes → vector. Nested match for the Option chains.
    (:wat::core::match (:wat::core::Bytes::from-hex hex-a) -> :()
      ((Some bytes-a)
        (:wat::core::match (:wat::core::Bytes::from-hex hex-b) -> :()
          ((Some bytes-b)
            (:wat::core::match (:wat::holon::bytes-vector bytes-a) -> :()
              ((Some v-a-imported)
                (:wat::core::match (:wat::holon::bytes-vector bytes-b) -> :()
                  ((Some v-b-imported)
                    (:wat::core::let*
                      (;; Parent (default seed 42) encodes the same form locally.
                       ((form-local :wat::holon::HolonAST)
                        (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
                       ((v-local :wat::holon::Vector) (:wat::holon::encode form-local))
                       ;; Same-universe match — child-A's bytes encode under
                       ;; seed 42; parent's local V also under seed 42; coincide.
                       ((same-uni :bool) (:wat::holon::coincident? v-a-imported v-local))
                       ;; Different-universe — child-B's bytes encode under
                       ;; seed 99; parent's local V under seed 42; do not coincide.
                       ((diff-uni :bool) (:wat::holon::coincident? v-b-imported v-local))
                       ((_su :()) (:wat::test::assert-eq same-uni true)))
                      (:wat::test::assert-eq diff-uni false)))
                  (:None (:wat::test::assert-eq "bytes-vector b → :None" "ok"))))
              (:None (:wat::test::assert-eq "bytes-vector a → :None" "ok"))))
          (:None (:wat::test::assert-eq "from-hex b → :None" "ok"))))
      (:None (:wat::test::assert-eq "from-hex a → :None" "ok")))))


;; ─── T9 — mixed cosine as the verification primitive ─────────
;;
;; The minimal verification API: ONE coincident? call confirms or
;; rejects (HolonAST × Vector). Three failure modes side by side:
;;
;;   coincident?(form-correct, V_correct) → TRUE
;;   coincident?(form-wrong,   V_correct) → FALSE  (wrong form)
;;   coincident?(form-correct, V_wrong)   → FALSE  (tampered/swapped V)
;;
;; The third case is "tampered V" in cryptographic terms — Bob
;; receives a V that doesn't actually correspond to form-correct.
;; This could be malicious substitution OR a transmission error
;; OR Alice committing the wrong thing. The verifier rejects on the
;; same primitive — coincident? is the unified verification API.

(:deftest :exp::t9-mixed-cosine-verification
  (:wat::core::let*
    (((form-correct :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((form-wrong :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::* 7 11))))

     ((v-correct :wat::holon::Vector) (:wat::holon::encode form-correct))
     ((v-wrong   :wat::holon::Vector) (:wat::holon::encode form-wrong))

     ;; Right form against right V → verified.
     ((right-right :bool) (:wat::holon::coincident? form-correct v-correct))
     ;; Wrong form against right V → rejected.
     ((wrong-right :bool) (:wat::holon::coincident? form-wrong v-correct))
     ;; Right form against wrong V (tampered/swapped) → rejected.
     ((right-wrong :bool) (:wat::holon::coincident? form-correct v-wrong))

     ((_rr :()) (:wat::test::assert-eq right-right true))
     ((_wr :()) (:wat::test::assert-eq wrong-right false)))
    (:wat::test::assert-eq right-wrong false)))


;; ─── T10 — explicit three-factor verification function ───────
;;
;; The verification protocol lifted into a callable predicate:
;;
;;   exp::verify (v-bytes :Bytes) (form :HolonAST) → :bool
;;
;; Given V's bytes (transmittable artifact) and a candidate form
;; (under the caller's current universe — K is config-time), returns
;; true iff the form encoded under K coincides with the bytes-
;; reconstructed Vector. False on EVERY failure mode:
;;   - wrong form
;;   - tampered/swapped V (different form's bytes)
;;   - corrupted bytes (bytes-vector → :None)
;;
;; Four test cases exercise each branch.

(:deftest :exp::t10-verify-three-factor
  (:wat::core::let*
    (((form-correct :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((form-wrong :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::* 7 11))))

     ((v-correct :wat::holon::Vector) (:wat::holon::encode form-correct))
     ((v-wrong   :wat::holon::Vector) (:wat::holon::encode form-wrong))

     ((bytes-correct :wat::core::Bytes) (:wat::holon::vector-bytes v-correct))
     ((bytes-wrong   :wat::core::Bytes) (:wat::holon::vector-bytes v-wrong))

     ;; Empty bytes — no dim header, bytes-vector → :None, verify → false.
     ;; A "tampered to nothing" scenario.
     ((bytes-empty :wat::core::Bytes) (:wat::core::vec :u8))

     ;; Right form + right V → verified.
     ((right :bool) (:exp::verify bytes-correct form-correct))
     ;; Wrong form + right V → rejected (form mismatch).
     ((wrong-form :bool) (:exp::verify bytes-correct form-wrong))
     ;; Right form + swapped V (different form's bytes) → rejected.
     ((wrong-v :bool) (:exp::verify bytes-wrong form-correct))
     ;; Right form + corrupted V (empty bytes) → rejected (decode fails).
     ((corrupted :bool) (:exp::verify bytes-empty form-correct))

     ((_r :()) (:wat::test::assert-eq right true))
     ((_wf :()) (:wat::test::assert-eq wrong-form false))
     ((_wv :()) (:wat::test::assert-eq wrong-v false)))
    (:wat::test::assert-eq corrupted false)))


;; ─── T11 — proof-of-computation ⊃ proof-of-work (the closer) ─
;;
;; Beat 7's kinship made concrete. Any deterministic computation
;; produces a verifiable proof artifact via the substrate. Bitcoin's
;; proof-of-work is one specific instantiation of this property.
;;
;; The shape:
;;   F = a non-trivial form (the "work")
;;   V = encode(F) — the proof artifact (cheap to produce, given F)
;;   T = eval(F) — the computational result (separate from V)
;;
;; Verification by anyone who has F:
;;   - Re-encode F → V'; check coincident?(V, V'). One operation.
;; Forgery attempt by anyone with a near-miss F':
;;   - encode(F') → V''; coincident?(V, V'') → FALSE.
;;
;; The asymmetry: cheap forward (encode F → V), expensive reverse
;; (search for F given V — the directed-graph property from beat 1).
;; This IS the cryptographic property Bitcoin's PoW depends on,
;; generalized: V can be ANY terminal of any deterministic
;; computation, not just hash output meeting a target.

(:deftest :exp::t11-proof-of-computation-pow-kinship
  (:wat::core::let*
    (;; The "work": a non-trivial form. The miner computes this
     ;; and publishes V as proof of having done the work.
     ;; Using `from-watast` (arc 065) — the honest constructor that
     ;; says "lower this quoted form structurally into a HolonAST."
     ((work-form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:wat::core::+ (:wat::core::* 7 13) (:wat::core::* 11 17)))))
     ((v-worker :wat::holon::Vector) (:wat::holon::encode work-form))

     ;; Verifier with the SAME form: cheap re-encode, cheap compare.
     ((v-verifier :wat::holon::Vector) (:wat::holon::encode work-form))
     ((verified :bool) (:wat::holon::coincident? v-worker v-verifier))

     ;; Forgery attempt: a near-miss form (same structural shape,
     ;; one operand changed: 17 → 19). Without the original work-form,
     ;; an attacker would need to enumerate candidates against V_worker
     ;; (the directed-graph property — unbounded reverse search).
     ((forgery-form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:wat::core::+ (:wat::core::* 7 13) (:wat::core::* 11 19)))))
     ((v-forgery :wat::holon::Vector) (:wat::holon::encode forgery-form))
     ((forgery-rejected :bool)
      (:wat::core::not (:wat::holon::coincident? v-worker v-forgery)))

     ;; The form's TERMINAL VALUE is also computable — separately
     ;; from V. (+ (* 7 13) (* 11 17)) = 91 + 187 = 278. Anyone with
     ;; the form can derive both V (cryptographic proof) and 278
     ;; (the computational result). They are two distinct artifacts
     ;; from the same form. Round-trip via to-watast → eval-ast! → atom-value
     ;; works honestly post-arcs-065/066.
     ((work-result :i64) (:exp::form->i64 work-form))

     ((_v :()) (:wat::test::assert-eq verified true))
     ((_f :()) (:wat::test::assert-eq forgery-rejected true)))
    (:wat::test::assert-eq work-result 278)))
