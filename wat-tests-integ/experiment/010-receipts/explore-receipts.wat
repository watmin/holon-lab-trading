;; wat-tests-integ/experiment/010-receipts/explore-receipts.wat
;;
;; Generic utility on top of proof 004's proof-of-computation primitive.
;; Three views of one underlying object — the Receipt:
;;
;;   Receipt   the unit (issue + verify)
;;   Journal   ordered append-only collection (append + verify-at)
;;   Registry  content-addressed lookup        (register + lookup)
;;
;; Each view answers a different question; the underlying record is
;; the same shape. T1-T5 prove the unit. T6-T9 prove the Journal.
;; T10-T13 prove the Registry. T14-T16 prove the cross-cutting
;; applications (build cache, decision journal, dual-stored receipt).
;;
;; Naming verdict (gaze ward, 2026-04-26):
;;   - `Receipt` over Commitment/Witness/Proof — the literature
;;     reserves Commitment for hide-then-reveal; Witness is the ZK
;;     secret. We don't hide F. We ship F.
;;   - `Journal` over Ledger (Level 1 lie: implies double-entry),
;;     over Chain (Level 1 lie: implies hash-linked entries).
;;   - `Registry` over Vault (implies secrecy) / Repository / Catalog.
;;   - `issue` / `verify` for the unit; `append` / `verify-at` for
;;     the Journal; `register` / `lookup` for the Registry. Each
;;     verb-pair distinct so the namespaces don't collide.
;;   - Fields: `bytes` (the encoded artifact), `form` (the HolonAST
;;     that was encoded), `seed-hint` (which universe; metadata
;;     only — seeds shouldn't travel with receipts).
;;
;; ── Form-size budget ──────────────────────────────────────────
;; Same posture as experiment 009: each form ≤100 statements per
;; Kanerva capacity. The forms here are deliberately small —
;; arithmetic primitives — so the encoding's structural fingerprint
;; isn't the load-bearing claim. Proof 004 already established
;; encoding fidelity at form scale. Proof 005 demonstrates utility.

(:wat::test::make-deftest :deftest
  (;; ─── The unit type ───────────────────────────────────────
   ;;
   ;; A Receipt is a portable record asserting "I encoded this form
   ;; under this seed and got these bytes." The seed-hint rides as
   ;; metadata only — the receipt does NOT carry the actual seed;
   ;; universe-binding stays geometric (per proof 004 T8).
   (:wat::core::struct :exp::Receipt
     (bytes :wat::core::Bytes)
     (form :wat::holon::HolonAST)
     (seed-hint :wat::core::i64))

   ;; Issue — encode `form` under the ambient universe; capture
   ;; (bytes, form, seed-hint) as a portable Receipt.
   (:wat::core::define
     (:exp::issue (form :wat::holon::HolonAST)
                  (seed-hint :wat::core::i64)
                  -> :exp::Receipt)
     (:wat::core::let*
       (((v :wat::holon::Vector) (:wat::holon::encode form))
        ((bytes :wat::core::Bytes) (:wat::holon::vector-bytes v)))
       (:exp::Receipt/new bytes form seed-hint)))

   ;; Verify — given a Receipt and a candidate form, re-decode the
   ;; receipt's bytes to a Vector and check coincident? against the
   ;; candidate. False on every failure mode: wrong form, corrupted
   ;; bytes, cross-universe mismatch.
   (:wat::core::define
     (:exp::verify (r :exp::Receipt)
                   (candidate :wat::holon::HolonAST)
                   -> :wat::core::bool)
     (:wat::core::match
       (:wat::holon::bytes-vector (:exp::Receipt/bytes r))
       -> :wat::core::bool
       ((Some v) (:wat::holon::coincident? candidate v))
       (:None false)))


   ;; ─── Journal — ordered append-only collection ─────────────
   ;;
   ;; A Vec<Receipt> wrapped in a struct so the type reads at call
   ;; sites — `:exp::Journal` carries semantic weight that bare
   ;; `:Vec<exp::Receipt>` doesn't.
   (:wat::core::struct :exp::Journal
     (entries :Vec<exp::Receipt>))

   (:wat::core::define
     (:exp::journal-empty -> :exp::Journal)
     (:exp::Journal/new (:wat::core::vec :exp::Receipt)))

   ;; append — return a NEW Journal with the receipt at the tail.
   ;; Pure functional; callers thread journals through let*
   ;; bindings as they accumulate.
   (:wat::core::define
     (:exp::append (j :exp::Journal) (r :exp::Receipt) -> :exp::Journal)
     (:exp::Journal/new
       (:wat::core::conj (:exp::Journal/entries j) r)))

   ;; verify-at — fetch entry at index, verify against a candidate
   ;; form. Returns false on out-of-range (matches the Receipt's
   ;; "false on every failure mode" convention).
   (:wat::core::define
     (:exp::verify-at (j :exp::Journal)
                      (idx :wat::core::i64)
                      (candidate :wat::holon::HolonAST)
                      -> :wat::core::bool)
     (:wat::core::match
       (:wat::core::get (:exp::Journal/entries j) idx)
       -> :wat::core::bool
       ((Some r) (:exp::verify r candidate))
       (:None false)))

   (:wat::core::define
     (:exp::journal-len (j :exp::Journal) -> :wat::core::i64)
     (:wat::core::length (:exp::Journal/entries j)))


   ;; ─── Registry — content-addressed lookup ──────────────────
   ;;
   ;; A HashMap<String, Receipt> keyed by hex-encoded bytes. Hex
   ;; is the canonical text bridge for byte payloads (arc 063);
   ;; `:wat::core::HashMap` requires its key type to be Hash + Eq,
   ;; which Vec<u8> isn't natively, but String is. The hex form is
   ;; lossless and stable — same V → same hex → same key.
   (:wat::core::struct :exp::Registry
     (entries :HashMap<String,exp::Receipt>))

   (:wat::core::define
     (:exp::registry-empty -> :exp::Registry)
     (:exp::Registry/new (:wat::core::HashMap :(String,exp::Receipt))))

   ;; register — insert a Receipt keyed by hex(bytes). If the same
   ;; bytes were registered before, the new entry replaces the old
   ;; (HashMap assoc semantics). Same V → same key → idempotent.
   (:wat::core::define
     (:exp::register (reg :exp::Registry) (r :exp::Receipt) -> :exp::Registry)
     (:exp::Registry/new
       (:wat::core::assoc (:exp::Registry/entries reg)
                          (:wat::core::Bytes::to-hex (:exp::Receipt/bytes r))
                          r)))

   ;; lookup — find a Receipt by its bytes. Returns Option;
   ;; None when the key isn't present.
   (:wat::core::define
     (:exp::lookup (reg :exp::Registry) (bytes :wat::core::Bytes)
                   -> :Option<exp::Receipt>)
     (:wat::core::get (:exp::Registry/entries reg)
                      (:wat::core::Bytes::to-hex bytes)))))


;; ════════════════════════════════════════════════════════════════
;;  PART A — The Receipt unit primitive (T1-T5)
;; ════════════════════════════════════════════════════════════════


;; ─── T1 — issue then verify the matching form ────────────────

(:deftest :exp::t1-issue-and-verify
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((r :exp::Receipt) (:exp::issue form 42))
     ((ok :wat::core::bool) (:exp::verify r form)))
    (:wat::test::assert-eq ok true)))


;; ─── T2 — rejects a wrong candidate form ─────────────────────

(:deftest :exp::t2-rejects-wrong-form
  (:wat::core::let*
    (((form-a :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((form-b :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::* 7 11))))
     ((r :exp::Receipt) (:exp::issue form-a 42))
     ((wrong :wat::core::bool) (:exp::verify r form-b)))
    (:wat::test::assert-eq wrong false)))


;; ─── T3 — tamper-detect via empty bytes ──────────────────────

(:deftest :exp::t3-tamper-detect
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((empty-bytes :wat::core::Bytes) (:wat::core::vec :wat::core::u8))
     ((tampered :exp::Receipt) (:exp::Receipt/new empty-bytes form 42))
     ((rejected :wat::core::bool) (:exp::verify tampered form)))
    (:wat::test::assert-eq rejected false)))


;; ─── T4 — accessors round-trip ───────────────────────────────

(:deftest :exp::t4-accessors
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((r :exp::Receipt) (:exp::issue form 42))

     ((stored-form :wat::holon::HolonAST) (:exp::Receipt/form r))
     ((stored-seed :wat::core::i64) (:exp::Receipt/seed-hint r))

     ((form-preserved :wat::core::bool) (:wat::holon::coincident? stored-form form))
     ((_f :()) (:wat::test::assert-eq form-preserved true)))
    (:wat::test::assert-eq stored-seed 42)))


;; ─── T5 — receipts compose (deterministic encoding) ──────────

(:deftest :exp::t5-receipts-compose
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 1 (:wat::core::* 2 3)))))
     ((r :exp::Receipt) (:exp::issue form 42))
     ((r2 :exp::Receipt) (:exp::issue form 42))
     ((ok1 :wat::core::bool) (:exp::verify r form))
     ((ok2 :wat::core::bool) (:exp::verify r2 form))
     ((cross :wat::core::bool) (:exp::verify r2 (:exp::Receipt/form r)))
     ((_o1 :()) (:wat::test::assert-eq ok1 true))
     ((_o2 :()) (:wat::test::assert-eq ok2 true)))
    (:wat::test::assert-eq cross true)))


;; ════════════════════════════════════════════════════════════════
;;  PART B — Journal (ordered append-only) (T6-T9)
;; ════════════════════════════════════════════════════════════════


;; ─── T6 — append then verify-at returns true ─────────────────

(:deftest :exp::t6-journal-append-and-verify
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((r :exp::Receipt) (:exp::issue form 42))

     ((j0 :exp::Journal) (:exp::journal-empty))
     ((j1 :exp::Journal) (:exp::append j0 r))

     ((ok :wat::core::bool) (:exp::verify-at j1 0 form))
     ((_l :()) (:wat::test::assert-eq (:exp::journal-len j1) 1)))
    (:wat::test::assert-eq ok true)))


;; ─── T7 — append three; each verifies at its own index ───────

(:deftest :exp::t7-journal-multi-entry-order
  (:wat::core::let*
    (((form-a :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 1 1))))
     ((form-b :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::* 3 5))))
     ((form-c :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::- 100 1))))

     ((j :exp::Journal)
      (:exp::append (:exp::append (:exp::append (:exp::journal-empty)
                                                (:exp::issue form-a 42))
                                  (:exp::issue form-b 42))
                    (:exp::issue form-c 42)))

     ((ok-a :wat::core::bool) (:exp::verify-at j 0 form-a))
     ((ok-b :wat::core::bool) (:exp::verify-at j 1 form-b))
     ((ok-c :wat::core::bool) (:exp::verify-at j 2 form-c))
     ((_a :()) (:wat::test::assert-eq ok-a true))
     ((_b :()) (:wat::test::assert-eq ok-b true))
     ((_l :()) (:wat::test::assert-eq (:exp::journal-len j) 3)))
    (:wat::test::assert-eq ok-c true)))


;; ─── T8 — cross-entry mismatch rejects ───────────────────────

(:deftest :exp::t8-journal-cross-mismatch
  (:wat::core::let*
    (((form-a :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 1 1))))
     ((form-b :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::* 3 5))))
     ((form-c :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::- 100 1))))

     ((j :exp::Journal)
      (:exp::append
        (:exp::append (:exp::append (:exp::journal-empty)
                                    (:exp::issue form-a 42))
                      (:exp::issue form-b 42))
        (:exp::issue form-c 42)))

     ((swap-01 :wat::core::bool) (:exp::verify-at j 0 form-b))
     ((swap-20 :wat::core::bool) (:exp::verify-at j 2 form-a))
     ((_01 :()) (:wat::test::assert-eq swap-01 false)))
    (:wat::test::assert-eq swap-20 false)))


;; ─── T9 — out-of-range index rejects ─────────────────────────

(:deftest :exp::t9-journal-out-of-range
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((j :exp::Journal)
      (:exp::append (:exp::journal-empty) (:exp::issue form 42)))

     ((past-tail :wat::core::bool) (:exp::verify-at j 5 form))
     ((empty-q :wat::core::bool) (:exp::verify-at (:exp::journal-empty) 0 form))
     ((_p :()) (:wat::test::assert-eq past-tail false)))
    (:wat::test::assert-eq empty-q false)))


;; ════════════════════════════════════════════════════════════════
;;  PART C — Registry (content-addressed lookup) (T10-T13)
;; ════════════════════════════════════════════════════════════════


;; ─── T10 — register then lookup-by-bytes returns the receipt ─

(:deftest :exp::t10-registry-register-and-lookup
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((r :exp::Receipt) (:exp::issue form 42))

     ((reg0 :exp::Registry) (:exp::registry-empty))
     ((reg1 :exp::Registry) (:exp::register reg0 r))

     ((found :Option<exp::Receipt>) (:exp::lookup reg1 (:exp::Receipt/bytes r))))
    (:wat::core::match found -> :()
      ((Some r-found) (:wat::test::assert-eq (:exp::verify r-found form) true))
      (:None (:wat::test::assert-eq "lookup returned :None for known bytes" "ok")))))


;; ─── T11 — unknown bytes return :None ────────────────────────

(:deftest :exp::t11-registry-unknown-key
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((other-form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::* 7 11))))

     ((r :exp::Receipt) (:exp::issue form 42))
     ((other-bytes :wat::core::Bytes)
      (:wat::holon::vector-bytes (:wat::holon::encode other-form)))

     ((reg :exp::Registry) (:exp::register (:exp::registry-empty) r))
     ((found :Option<exp::Receipt>) (:exp::lookup reg other-bytes))
     ((is-none :wat::core::bool)
       (:wat::core::match found -> :wat::core::bool
         ((Some _) false)
         (:None true))))
    (:wat::test::assert-eq is-none true)))


;; ─── T12 — multi-entry registry — lookup each ────────────────

(:deftest :exp::t12-registry-multi-entry
  (:wat::core::let*
    (((form-a :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 1 1))))
     ((form-b :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::* 3 5))))
     ((form-c :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::- 100 1))))

     ((r-a :exp::Receipt) (:exp::issue form-a 42))
     ((r-b :exp::Receipt) (:exp::issue form-b 42))
     ((r-c :exp::Receipt) (:exp::issue form-c 42))

     ((reg :exp::Registry)
      (:exp::register
        (:exp::register (:exp::register (:exp::registry-empty) r-a) r-b)
        r-c))

     ((found-a :Option<exp::Receipt>) (:exp::lookup reg (:exp::Receipt/bytes r-a)))
     ((found-c :Option<exp::Receipt>) (:exp::lookup reg (:exp::Receipt/bytes r-c)))

     ((ok-a :wat::core::bool)
       (:wat::core::match found-a -> :wat::core::bool
         ((Some r) (:exp::verify r form-a))
         (:None false)))
     ((ok-c :wat::core::bool)
       (:wat::core::match found-c -> :wat::core::bool
         ((Some r) (:exp::verify r form-c))
         (:None false)))
     ((_a :()) (:wat::test::assert-eq ok-a true)))
    (:wat::test::assert-eq ok-c true)))


;; ─── T13 — registered receipt verifies after lookup ──────────
;;
;; The full registry round trip: register → lookup → verify. The
;; receipt extracted by lookup must verify identically to the one
;; that was registered. This proves the registry is *content-
;; addressable* — given the bytes (the public V), you recover the
;; full receipt and can verify it.

(:deftest :exp::t13-registry-lookup-then-verify
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ (:wat::core::* 7 13) (:wat::core::* 11 17)))))
     ((r-original :exp::Receipt) (:exp::issue form 42))
     ((reg :exp::Registry) (:exp::register (:exp::registry-empty) r-original))

     ;; The verifier holds only V (the bytes) and F (the form).
     ;; They use V to look up the registered receipt; then use F
     ;; to verify it.
     ((looked-up :Option<exp::Receipt>) (:exp::lookup reg (:exp::Receipt/bytes r-original)))
     ((verified :wat::core::bool)
       (:wat::core::match looked-up -> :wat::core::bool
         ((Some r) (:exp::verify r form))
         (:None false))))
    (:wat::test::assert-eq verified true)))


;; ════════════════════════════════════════════════════════════════
;;  PART D — Applications (cross-cutting utility) (T14-T16)
;; ════════════════════════════════════════════════════════════════


;; ─── T14 — build-cache shape ─────────────────────────────────
;;
;; A build cache asks: "have I built F before? if so, what was the
;; output?" The Registry IS this. Index by the form's V_bytes; the
;; "output" payload is the Receipt itself (which carries form for
;; verification + bytes as the output identifier). A cache miss
;; would compute the form fresh and register the result.
;;
;; In a real build system, the receipt would carry a payload
;; instead of just self-attestation, but the SHAPE is here: V is
;; the cache key, lookup-or-compute is the access pattern, and
;; every hit is verifiable (no cache-poisoning).

(:deftest :exp::t14-build-cache
  (:wat::core::let*
    (;; "Build" — a form whose V we treat as the build's identity.
     ((build-form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((build-bytes :wat::core::Bytes)
      (:wat::holon::vector-bytes (:wat::holon::encode build-form)))

     ;; First request: cache miss → compute → register.
     ((cache-empty :exp::Registry) (:exp::registry-empty))
     ((miss :Option<exp::Receipt>) (:exp::lookup cache-empty build-bytes))
     ((is-miss :wat::core::bool)
       (:wat::core::match miss -> :wat::core::bool ((Some _) false) (:None true)))
     ((_miss :()) (:wat::test::assert-eq is-miss true))

     ;; Compute and register.
     ((built :exp::Receipt) (:exp::issue build-form 42))
     ((cache :exp::Registry) (:exp::register cache-empty built))

     ;; Second request for the SAME build → cache hit; verifiable.
     ((hit :Option<exp::Receipt>) (:exp::lookup cache build-bytes))
     ((cache-hit-verifies :wat::core::bool)
       (:wat::core::match hit -> :wat::core::bool
         ((Some r) (:exp::verify r build-form))
         (:None false))))
    (:wat::test::assert-eq cache-hit-verifies true)))


;; ─── T15 — decision-journal shape ────────────────────────────
;;
;; A decision journal asks: "what was decided, in what order?" The
;; Journal IS this. Each decision is encoded as a form, issued as
;; a receipt, and appended at its time of decision. Auditors later
;; replay the journal to verify the decisions match the forms they
;; claim. Position is part of the audit — decision-3-was-after-
;; decision-2 is a structural property of the journal, not metadata.

(:deftest :exp::t15-decision-journal
  (:wat::core::let*
    (;; Three decisions, in order. Forms encode the decision shape.
     ((d1 :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 1 0))))
     ((d2 :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::* 2 3))))
     ((d3 :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::- 10 1))))

     ((log :exp::Journal)
      (:exp::append
        (:exp::append (:exp::append (:exp::journal-empty)
                                    (:exp::issue d1 42))
                      (:exp::issue d2 42))
        (:exp::issue d3 42)))

     ;; Audit: each decision verifies at its position; out-of-order
     ;; verification rejects (proves order is part of the record).
     ((audit-1 :wat::core::bool) (:exp::verify-at log 0 d1))
     ((audit-2 :wat::core::bool) (:exp::verify-at log 1 d2))
     ((audit-3 :wat::core::bool) (:exp::verify-at log 2 d3))
     ((wrong-order :wat::core::bool) (:exp::verify-at log 0 d3))

     ((_a1 :()) (:wat::test::assert-eq audit-1 true))
     ((_a2 :()) (:wat::test::assert-eq audit-2 true))
     ((_a3 :()) (:wat::test::assert-eq audit-3 true)))
    (:wat::test::assert-eq wrong-order false)))


;; ─── T16 — same Receipt in Journal AND Registry ──────────────
;;
;; The unifying claim: one Receipt, two views. A receipt issued
;; once can be appended to a Journal (for ordered audit) AND
;; registered in a Registry (for content-addressed lookup) — both
;; verifications succeed against the same Receipt instance.
;;
;; This proves the Receipt is genuinely the underlying primitive;
;; Journal and Registry are *views*, not separate types. Cheap to
;; build, cheap to query, no duplication of the cryptographic
;; assertion.

(:deftest :exp::t16-dual-stored-receipt
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote (:wat::core::+ 2 2))))
     ((r :exp::Receipt) (:exp::issue form 42))

     ;; Same receipt — appended to a Journal and registered in a Registry.
     ((j :exp::Journal) (:exp::append (:exp::journal-empty) r))
     ((reg :exp::Registry) (:exp::register (:exp::registry-empty) r))

     ;; Audit via journal (by position).
     ((via-journal :wat::core::bool) (:exp::verify-at j 0 form))

     ;; Audit via registry (by content key).
     ((via-registry :wat::core::bool)
       (:wat::core::match (:exp::lookup reg (:exp::Receipt/bytes r)) -> :wat::core::bool
         ((Some r-found) (:exp::verify r-found form))
         (:None false)))

     ((_j :()) (:wat::test::assert-eq via-journal true)))
    (:wat::test::assert-eq via-registry true)))
