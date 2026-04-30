;; wat-tests-integ/experiment/014-time-witness/explore-time-witness.wat
;;
;; External time-witness verification — proof 009.
;;
;; Builder framing (2026-04-26):
;;
;;   "the whole point of wat — is to stop lies in statements"
;;
;; A time-witness is a statement of the form *"this Receipt was issued
;; at round R of beacon B, where B published witness value v_R at
;; that round."* The substrate's job is not to BE the time authority;
;; it's to MEASURE WHETHER THE STATEMENT IS SOUND.
;;
;; Sound = receipt's claimed (round, witness) pair coincides with
;; the beacon's published value for that round.
;; Unsound = the claim disagrees with the beacon's published reality.
;;
;; The beacon (DRAND, NIST randomness beacon, Bitcoin block hashes,
;; whatever) provides public time-attested values. The substrate
;; consumes those values as an axiom set. A receipt's time-claim is
;; just another statement to soundness-gate against the axioms.
;;
;; ─── What this proof demonstrates ─────────────────────────────
;;
;; T1  Honest path — receipt's witness matches beacon's published
;;     round value; binding sound + time sound = approve.
;; T2  Witness lie — issuer fabricates a witness value; binding
;;     stays sound (V binds to whatever F says, even a lie); time
;;     verification catches the lie against the beacon's axiom.
;; T3  Future round — issuer claims round N+100 not yet published;
;;     beacon lookup returns :None; time claim cannot be verified.
;; T4  Binding tamper — third party modifies the receipt's form
;;     post-issue; binding fails before time check even runs.
;; T5  Multi-beacon triangulation — receipt includes witnesses from
;;     two independent beacons; both must verify; one lie is enough
;;     to reject. Higher confidence at cost of one extra atom.
;; T6  No time claim — receipt has no witnesses; binding verifies
;;     but time is unattested → review band (the substrate doesn't
;;     fabricate time it wasn't given).
;;
;; ─── What this proof does NOT demonstrate ─────────────────────
;;
;; - Anti-backdating without external observers. A receipt with a
;;   correct round-3 witness is structurally indistinguishable from
;;   one issued at round 3, even if it was actually fabricated at
;;   round 100. To detect that, you need an external observer who
;;   saw the receipt before round 100 (transparency log, peer
;;   network, blockchain anchor). The substrate provides
;;   verifiability of consistency; not absolute time-ordering.
;; - Beacon trust. We don't authenticate the beacon's signature
;;   here. Real deployment composes with the beacon's own signing
;;   protocol (DRAND is verifiable; NIST signs; Bitcoin's chain
;;   self-attests). Out of scope for the substrate primitive.
;; - Revocation. If a beacon's witness for round R is later
;;   discovered to be compromised, this proof has no mechanism to
;;   invalidate prior receipts that used it. That's a beacon-layer
;;   concern.

(:wat::test::make-deftest :deftest
  (;; ─── Receipt + binding (from proof 005) ──────────────────
   (:wat::core::struct :exp::Receipt
     (bytes :wat::core::Bytes)
     (form :wat::holon::HolonAST))

   (:wat::core::define
     (:exp::issue (form :wat::holon::HolonAST) -> :exp::Receipt)
     (:wat::core::let*
       (((v :wat::holon::Vector) (:wat::holon::encode form))
        ((bytes :wat::core::Bytes) (:wat::holon::vector-bytes v)))
       (:exp::Receipt/new bytes form)))

   (:wat::core::define
     (:exp::verify-binding (r :exp::Receipt)
                           (candidate :wat::holon::HolonAST)
                           -> :wat::core::bool)
     (:wat::core::match
       (:wat::holon::bytes-vector (:exp::Receipt/bytes r))
       -> :wat::core::bool
       ((Some v) (:wat::holon::coincident? candidate v))
       (:None false)))


   ;; ─── Beacon — the time-witness axiom set ──────────────────
   ;;
   ;; A Beacon publishes (round → witness) entries. In real
   ;; deployment: DRAND publishes every 30s, NIST every 60s,
   ;; Bitcoin every ~10min, etc. For demo we precompute synthetic
   ;; rounds; the verification mechanism is unchanged.
   (:wat::core::struct :exp::Beacon
     (name :wat::core::String)
     (rounds :HashMap<i64,String>))


   ;; ─── TimeWitness — one beacon's claim about one round ────
   ;;
   ;; A receipt may carry multiple of these (one per beacon used
   ;; for triangulation). Each must verify independently against
   ;; its named beacon.
   (:wat::core::struct :exp::TimeWitness
     (beacon :wat::core::String)     ;; must match :exp::Beacon::name
     (round :wat::core::i64)
     (witness :wat::core::String))


   ;; ─── TimedReceipt — Receipt + time claims ─────────────────
   (:wat::core::struct :exp::TimedReceipt
     (bytes :wat::core::Bytes)
     (form :wat::holon::HolonAST)
     (witnesses :Vec<exp::TimeWitness>))


   ;; ─── Verdict — the soundness gate's output ───────────────
   (:wat::core::struct :exp::TimeVerdict
     (binding-sound :wat::core::bool)
     (time-sound :wat::core::bool)
     (decision :wat::core::String))   ;; "approve" | "reject-binding" | "reject-time" | "no-claim"


   ;; ─── Verify a single time witness against a beacon list ──
   ;;
   ;; Given a TimeWitness and the verifier's known beacons, find
   ;; the matching beacon by name and check the witness against
   ;; the beacon's published round. Returns false on any failure
   ;; (unknown beacon, unpublished round, witness mismatch).
   (:wat::core::define
     (:exp::verify-witness
       (w :exp::TimeWitness)
       (beacons :Vec<exp::Beacon>)
       -> :wat::core::bool)
     (:wat::core::foldl beacons false
       (:wat::core::lambda ((acc :wat::core::bool) (b :exp::Beacon) -> :wat::core::bool)
         (:wat::core::if
           (:wat::core::= (:exp::Beacon/name b) (:exp::TimeWitness/beacon w))
           -> :wat::core::bool
           ;; Beacon name matched — look up the round.
           (:wat::core::match
             (:wat::core::get (:exp::Beacon/rounds b) (:exp::TimeWitness/round w))
             -> :wat::core::bool
             ((Some published) (:wat::core::= published (:exp::TimeWitness/witness w)))
             (:None false))
           ;; Different beacon; carry the accumulator forward.
           acc))))


   ;; ─── Verify all witnesses on a TimedReceipt ──────────────
   ;;
   ;; Triangulation rule: ALL witnesses must verify (logical AND).
   ;; A single lie is enough to reject. Empty witness list returns
   ;; false → "no-claim" branch in the verdict.
   (:wat::core::define
     (:exp::verify-all-witnesses
       (witnesses :Vec<exp::TimeWitness>)
       (beacons :Vec<exp::Beacon>)
       -> :wat::core::bool)
     (:wat::core::if (:wat::core::= (:wat::core::length witnesses) 0)
       -> :wat::core::bool
       false   ;; no witnesses to verify → time-sound false (handled in verdict)
       (:wat::core::foldl witnesses true
         (:wat::core::lambda ((acc :wat::core::bool) (w :exp::TimeWitness) -> :wat::core::bool)
           (:wat::core::and acc (:exp::verify-witness w beacons))))))


   ;; ─── Combined gate — binding + time ──────────────────────
   ;;
   ;;   binding sound  + time sound        → approve
   ;;   binding sound  + no witnesses      → no-claim (review)
   ;;   binding sound  + witnesses fail    → reject-time
   ;;   binding fails (any reason)         → reject-binding
   (:wat::core::define
     (:exp::evaluate
       (tr :exp::TimedReceipt)
       (expected-form :wat::holon::HolonAST)
       (beacons :Vec<exp::Beacon>)
       -> :exp::TimeVerdict)
     (:wat::core::let*
       (((r :exp::Receipt)
         (:exp::Receipt/new (:exp::TimedReceipt/bytes tr)
                            (:exp::TimedReceipt/form tr)))
        ((binding-ok :wat::core::bool) (:exp::verify-binding r expected-form))
        ((witnesses :Vec<exp::TimeWitness>) (:exp::TimedReceipt/witnesses tr))
        ((empty :wat::core::bool) (:wat::core::= (:wat::core::length witnesses) 0))
        ((time-ok :wat::core::bool) (:exp::verify-all-witnesses witnesses beacons))

        ((decision :wat::core::String)
          (:wat::core::cond -> :wat::core::String
            ((:wat::core::not binding-ok) "reject-binding")
            (empty "no-claim")
            ((:wat::core::not time-ok) "reject-time")
            (:else "approve"))))
       (:exp::TimeVerdict/new binding-ok time-ok decision)))


   ;; ─── Test fixtures: the beacons we use across tests ──────
   ;;
   ;; Synthetic DRAND-style and NIST-style values. Real-world
   ;; deployment fetches these from each beacon's published API.
   (:wat::core::define
     (:exp::beacon-drand -> :exp::Beacon)
     (:exp::Beacon/new "drand"
       (:wat::core::HashMap :(i64,String)
         1 "drand-r1-aabbccdd"
         2 "drand-r2-eeff0011"
         3 "drand-r3-22334455"
         4 "drand-r4-66778899"
         5 "drand-r5-aabbccdd"
         6 "drand-r6-deadbeef"
         7 "drand-r7-feedface"
         8 "drand-r8-cafebabe"
         9 "drand-r9-decafbad"
         10 "drand-r10-baadf00d")))

   (:wat::core::define
     (:exp::beacon-nist -> :exp::Beacon)
     (:exp::Beacon/new "nist"
       (:wat::core::HashMap :(i64,String)
         1714329600 "nist-e1714329600-1234"
         1714329660 "nist-e1714329660-5678"
         1714329720 "nist-e1714329720-9abc")))


   ;; ─── Helpers for assembling the binding form ─────────────
   ;;
   ;; Each test builds its own quoted form so the time-witness
   ;; sub-form is part of F (and thus part of V_bytes via encode).
   ;; The witnesses Vec on the struct echoes those values for
   ;; verifier convenience.
))


;; ════════════════════════════════════════════════════════════════
;;  T1 — Honest path: single-beacon witness verifies
;; ════════════════════════════════════════════════════════════════
;;
;; Issuer queries DRAND, sees round 5 with value
;; "drand-r5-aabbccdd". Builds F including the witness atom; issues
;; TimedReceipt. Verifier holds the beacon snapshot; both binding
;; and time pass; verdict approves.

(:deftest :exp::t1-honest-single-beacon
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:audit/inference
          (model "claude-opus-4-7")
          (prompt "What is 2+2?")
          (output "2+2 equals 4.")
          (time-witness (beacon "drand") (round 5) (value "drand-r5-aabbccdd"))))))

     ((receipt :exp::Receipt) (:exp::issue form))
     ((witnesses :Vec<exp::TimeWitness>)
      (:wat::core::vec :exp::TimeWitness
        (:exp::TimeWitness/new "drand" 5 "drand-r5-aabbccdd")))

     ((tr :exp::TimedReceipt)
      (:exp::TimedReceipt/new (:exp::Receipt/bytes receipt)
                              (:exp::Receipt/form receipt)
                              witnesses))

     ((beacons :Vec<exp::Beacon>) (:wat::core::vec :exp::Beacon (:exp::beacon-drand)))
     ((verdict :exp::TimeVerdict) (:exp::evaluate tr form beacons))

     ((_b :()) (:wat::test::assert-eq (:exp::TimeVerdict/binding-sound verdict) true))
     ((_t :()) (:wat::test::assert-eq (:exp::TimeVerdict/time-sound verdict) true)))
    (:wat::test::assert-eq (:exp::TimeVerdict/decision verdict) "approve")))


;; ════════════════════════════════════════════════════════════════
;;  T2 — Witness lie: fabricated witness value caught at time check
;; ════════════════════════════════════════════════════════════════
;;
;; Issuer claims round 5 but invents witness value "FAKE-VALUE-NOT-FROM-BEACON".
;; The form binds to the lie (V_bytes commits to whatever F says, including
;; the lie). Binding check passes — F encodes to the same V it was issued
;; against. Time check looks up round 5 in the beacon, gets
;; "drand-r5-aabbccdd", compares to the receipt's claimed witness
;; "FAKE-VALUE-NOT-FROM-BEACON" — mismatch. Time-sound = false.
;;
;; This is the canonical lie-detection demonstration. The substrate
;; binds the issuer to whatever they say. The beacon's axiom set
;; says what's true. The two diverge, and the substrate flags it.

(:deftest :exp::t2-witness-lie
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:audit/inference
          (model "claude-opus-4-7")
          (prompt "Was the trade approved?")
          (output "Yes.")
          (time-witness (beacon "drand") (round 5) (value "FAKE-VALUE-NOT-FROM-BEACON"))))))

     ((receipt :exp::Receipt) (:exp::issue form))
     ((witnesses :Vec<exp::TimeWitness>)
      (:wat::core::vec :exp::TimeWitness
        (:exp::TimeWitness/new "drand" 5 "FAKE-VALUE-NOT-FROM-BEACON")))

     ((tr :exp::TimedReceipt)
      (:exp::TimedReceipt/new (:exp::Receipt/bytes receipt)
                              (:exp::Receipt/form receipt)
                              witnesses))

     ((beacons :Vec<exp::Beacon>) (:wat::core::vec :exp::Beacon (:exp::beacon-drand)))
     ((verdict :exp::TimeVerdict) (:exp::evaluate tr form beacons))

     ;; Binding still sound — F was honestly committed-to, even though
     ;; what it says is a lie. The lie is INSIDE F.
     ((_b :()) (:wat::test::assert-eq (:exp::TimeVerdict/binding-sound verdict) true))
     ;; Time UNSOUND — the claimed witness diverges from the beacon's axiom.
     ((_t :()) (:wat::test::assert-eq (:exp::TimeVerdict/time-sound verdict) false)))
    (:wat::test::assert-eq (:exp::TimeVerdict/decision verdict) "reject-time")))


;; ════════════════════════════════════════════════════════════════
;;  T3 — Future round: claiming a round the beacon hasn't published
;; ════════════════════════════════════════════════════════════════
;;
;; Beacon has rounds 1..10 published. Issuer claims round 999 with
;; some witness value. The beacon's round → witness map has no
;; entry for 999; lookup returns :None; verify-witness returns
;; false. Decision: reject-time.
;;
;; This is impossible to fabricate without the beacon's
;; cooperation. Round 999's value depends on rounds 1..998's
;; publication chain (in DRAND/Bitcoin/etc). You can't precompute
;; it; you can't claim it.

(:deftest :exp::t3-future-round
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:audit/inference
          (model "claude-opus-4-7")
          (prompt "Predict the future")
          (output "Definitely!")
          (time-witness (beacon "drand") (round 999) (value "drand-r999-fabricated"))))))

     ((receipt :exp::Receipt) (:exp::issue form))
     ((witnesses :Vec<exp::TimeWitness>)
      (:wat::core::vec :exp::TimeWitness
        (:exp::TimeWitness/new "drand" 999 "drand-r999-fabricated")))

     ((tr :exp::TimedReceipt)
      (:exp::TimedReceipt/new (:exp::Receipt/bytes receipt)
                              (:exp::Receipt/form receipt)
                              witnesses))

     ((beacons :Vec<exp::Beacon>) (:wat::core::vec :exp::Beacon (:exp::beacon-drand)))
     ((verdict :exp::TimeVerdict) (:exp::evaluate tr form beacons))

     ((_b :()) (:wat::test::assert-eq (:exp::TimeVerdict/binding-sound verdict) true)))
    (:wat::test::assert-eq (:exp::TimeVerdict/time-sound verdict) false)))


;; ════════════════════════════════════════════════════════════════
;;  T4 — Binding tamper: form modified post-issue, time never checks
;; ════════════════════════════════════════════════════════════════
;;
;; Issuer signs F with honest witness. An adversary intercepts and
;; substitutes a different form (different prompt, different output,
;; or different witness — anything). The receipt's bytes still
;; commit to the ORIGINAL F. The verifier's expected-form is the
;; tampered version. Re-encoding the tampered form produces a
;; different V; coincident? against the original bytes returns
;; false. Binding fails. Decision: reject-binding (without ever
;; reaching the time check).
;;
;; Same mechanism as proof 006 T2 (registry tampering). Belongs in
;; this proof too because it shows the binding layer is the FIRST
;; gate — before time-witness even matters, the substrate confirms
;; the form being verified is the form that was signed.

(:deftest :exp::t4-binding-tamper
  (:wat::core::let*
    (((original-form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:audit/inference
          (model "claude-opus-4-7")
          (prompt "Should I sell BTC?")
          (output "I cannot give specific investment advice.")
          (time-witness (beacon "drand") (round 5) (value "drand-r5-aabbccdd"))))))

     ((receipt :exp::Receipt) (:exp::issue original-form))
     ((witnesses :Vec<exp::TimeWitness>)
      (:wat::core::vec :exp::TimeWitness
        (:exp::TimeWitness/new "drand" 5 "drand-r5-aabbccdd")))

     ;; Adversary's tampered form — flips the AI's refusal into approval.
     ((tampered-form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:audit/inference
          (model "claude-opus-4-7")
          (prompt "Should I sell BTC?")
          (output "Yes, sell immediately.")
          (time-witness (beacon "drand") (round 5) (value "drand-r5-aabbccdd"))))))

     ;; The TimedReceipt the adversary publishes still has the original
     ;; receipt's bytes (V binds to the original) — but the verifier's
     ;; expected-form is the tampered version.
     ((tr :exp::TimedReceipt)
      (:exp::TimedReceipt/new (:exp::Receipt/bytes receipt)
                              (:exp::Receipt/form receipt)
                              witnesses))

     ((beacons :Vec<exp::Beacon>) (:wat::core::vec :exp::Beacon (:exp::beacon-drand)))
     ;; Verifier evaluates against the TAMPERED form they were shown.
     ((verdict :exp::TimeVerdict) (:exp::evaluate tr tampered-form beacons))

     ((_b :()) (:wat::test::assert-eq (:exp::TimeVerdict/binding-sound verdict) false)))
    (:wat::test::assert-eq (:exp::TimeVerdict/decision verdict) "reject-binding")))


;; ════════════════════════════════════════════════════════════════
;;  T5 — Multi-beacon triangulation: BOTH beacons must verify
;; ════════════════════════════════════════════════════════════════
;;
;; Issuer attests at TWO independent beacons (DRAND round 5 +
;; NIST epoch 1714329600). The receipt carries both witnesses.
;; Verifier checks both; both match; approve.
;;
;; If either beacon's witness were forged, the AND in
;; verify-all-witnesses returns false. One lie is enough.
;; Triangulation gives higher confidence than single-beacon at
;; the cost of one extra atom. Receipts using N beacons are
;; N-of-N forgery-resistant.

(:deftest :exp::t5-multi-beacon-triangulation
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:audit/inference
          (model "claude-opus-4-7")
          (prompt "Confirm this trade")
          (output "Trade confirmed.")
          (time-witness-drand (beacon "drand") (round 5) (value "drand-r5-aabbccdd"))
          (time-witness-nist  (beacon "nist") (epoch 1714329600) (value "nist-e1714329600-1234"))))))

     ((receipt :exp::Receipt) (:exp::issue form))

     ;; Both witnesses, both correct.
     ((witnesses :Vec<exp::TimeWitness>)
      (:wat::core::vec :exp::TimeWitness
        (:exp::TimeWitness/new "drand" 5 "drand-r5-aabbccdd")
        (:exp::TimeWitness/new "nist" 1714329600 "nist-e1714329600-1234")))

     ((tr :exp::TimedReceipt)
      (:exp::TimedReceipt/new (:exp::Receipt/bytes receipt)
                              (:exp::Receipt/form receipt)
                              witnesses))

     ((beacons :Vec<exp::Beacon>)
      (:wat::core::vec :exp::Beacon (:exp::beacon-drand) (:exp::beacon-nist)))

     ((verdict :exp::TimeVerdict) (:exp::evaluate tr form beacons))

     ((_b :()) (:wat::test::assert-eq (:exp::TimeVerdict/binding-sound verdict) true))
     ((_t :()) (:wat::test::assert-eq (:exp::TimeVerdict/time-sound verdict) true)))
    (:wat::test::assert-eq (:exp::TimeVerdict/decision verdict) "approve")))


;; ════════════════════════════════════════════════════════════════
;;  T6 — No time claim: receipt is binding-sound but time-unattested
;; ════════════════════════════════════════════════════════════════
;;
;; A receipt with no time-witness sub-form. The substrate doesn't
;; manufacture time it wasn't given; it routes to "no-claim" — the
;; review band. Honest about its scope: "I confirm this form binds
;; to its bytes; I have no evidence about WHEN."
;;
;; This is the failure mode that proves the substrate doesn't lie
;; in the OTHER direction either. It won't claim time-soundness
;; in the absence of a witness. Silent on what it doesn't know.

(:deftest :exp::t6-no-time-claim
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:audit/inference
          (model "claude-opus-4-7")
          (prompt "What is 2+2?")
          (output "4.")))))

     ((receipt :exp::Receipt) (:exp::issue form))
     ((empty-witnesses :Vec<exp::TimeWitness>) (:wat::core::vec :exp::TimeWitness))

     ((tr :exp::TimedReceipt)
      (:exp::TimedReceipt/new (:exp::Receipt/bytes receipt)
                              (:exp::Receipt/form receipt)
                              empty-witnesses))

     ((beacons :Vec<exp::Beacon>) (:wat::core::vec :exp::Beacon (:exp::beacon-drand)))
     ((verdict :exp::TimeVerdict) (:exp::evaluate tr form beacons))

     ;; Binding sound (form encodes correctly).
     ((_b :()) (:wat::test::assert-eq (:exp::TimeVerdict/binding-sound verdict) true))
     ;; Time NOT sound — there's no claim to assert. The substrate
     ;; doesn't fabricate evidence.
     ((_t :()) (:wat::test::assert-eq (:exp::TimeVerdict/time-sound verdict) false)))
    ;; Decision is "no-claim" — distinguished from "reject-time" so
    ;; the consumer knows whether to raise an alarm or just ask
    ;; the issuer to provide a witness.
    (:wat::test::assert-eq (:exp::TimeVerdict/decision verdict) "no-claim")))
