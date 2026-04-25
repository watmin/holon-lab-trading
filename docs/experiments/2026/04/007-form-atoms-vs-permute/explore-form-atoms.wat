;; docs/experiments/2026/04/007-form-atoms-vs-permute/explore-form-atoms.wat
;;
;; The verdict program. Permute-vs-form-atoms head-to-head.
;;
;; Experiment 006 surfaced what Proposal 056's RESOLUTION had already
;; admitted in passing:
;;
;;     "Raw rhythm cosine between uptrend and downtrend: 0.72-0.96.
;;      After subspace strips the background: -0.09 to -0.10."
;;
;; — meaning the rhythm encoding does NOT distinguish uptrend from
;; downtrend by raw cosine; the project routed around it via noise
;; subspace residuals. The Permute primitive shipped (Proposal 044,
;; 058-009, 058-013) on category-theory grounds (Beckman: ordered
;; lists are a different functor) and production-mirror logic
;; (rhythm.rs already used bind-chain trigrams). Hickey objected on
;; queryability; was overruled. Permute's empirical scrambling power
;; on structured Thermometer inputs was never measured.
;;
;; Now we have a lisp. We can measure.
;;
;; This program encodes the SAME 8-value series three ways:
;;
;;   A. Trigram of raw Thermometers
;;      Bind(Atom "rsi", Trigram([Therm v_0, ..., Therm v_7]))
;;      = the stdlib path (058-013) over plain values.
;;
;;   B. Trigram of atom-bound Thermometers (archived rhythm.rs shape,
;;      WITHOUT delta facts so we isolate Permute's contribution)
;;      Bind(Atom "rsi", Trigram([Bind(Atom "rsi", Therm v_i), ...]))
;;
;;   C. Bundle of form-atom positional facts
;;      Bundle([Bind(Atom (quote (pos i)), Therm v_i), ...])
;;      = position is a quoted form. The form IS the address.
;;
;; Per 058-001 (parametric Atom<T>), every Atom hashes
;; (type-tag, canonical-EDN) → deterministic seeded vector. Per
;; arc 051 (SimHash), Atom(i64)..Atom(63) are reserved as the LSH
;; projection basis — position markers and LSH anchors are the
;; SAME resource (BOOK Chapter 36's lattice). Form-atoms naturally
;; double as both.
;;
;; Same input data. Three encodings. One verdict.
;;
;; Run: wat docs/experiments/2026/04/007-form-atoms-vs-permute/explore-form-atoms.wat

;; ─── Force d=10k for everything ────────────────────────────────────
(:wat::config::set-dim-router!
  (:wat::core::lambda
    ((ast :wat::holon::HolonAST) -> :Option<i64>)
    (Some 10000)))

;; ─── helpers ───────────────────────────────────────────────────────

(:wat::core::define
  (:explore::force
    (r :wat::holon::BundleResult)
    -> :wat::holon::HolonAST)
  (:wat::core::match r -> :wat::holon::HolonAST
    ((Ok h) h)
    ((Err _) (:wat::holon::Atom "_BUNDLE_ERROR_"))))

(:wat::core::define
  (:explore::print-row
    (stdout :wat::io::IOWriter)
    (label :String) (a :f64) (b :f64) (c :f64)
    -> :())
  (:wat::io::IOWriter/println stdout
    (:wat::core::string::join "\t"
      (:wat::core::vec :String label
        (:wat::core::f64::to-string a)
        (:wat::core::f64::to-string b)
        (:wat::core::f64::to-string c)))))

;; ─── Encoding A: Trigram of raw Thermometers ───────────────────────
(:wat::core::define
  (:explore::rhythm-A
    (v0 :f64) (v1 :f64) (v2 :f64) (v3 :f64)
    (v4 :f64) (v5 :f64) (v6 :f64) (v7 :f64)
    -> :wat::holon::HolonAST)
  (:wat::holon::Bind
    (:wat::holon::Atom "rsi")
    (:explore::force
      (:wat::holon::Trigram
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Thermometer v0 0.0 1.0)
          (:wat::holon::Thermometer v1 0.0 1.0)
          (:wat::holon::Thermometer v2 0.0 1.0)
          (:wat::holon::Thermometer v3 0.0 1.0)
          (:wat::holon::Thermometer v4 0.0 1.0)
          (:wat::holon::Thermometer v5 0.0 1.0)
          (:wat::holon::Thermometer v6 0.0 1.0)
          (:wat::holon::Thermometer v7 0.0 1.0))))))

;; ─── Encoding B: Trigram of atom-bound Thermometers ────────────────
(:wat::core::define
  (:explore::rhythm-B
    (v0 :f64) (v1 :f64) (v2 :f64) (v3 :f64)
    (v4 :f64) (v5 :f64) (v6 :f64) (v7 :f64)
    -> :wat::holon::HolonAST)
  (:wat::holon::Bind
    (:wat::holon::Atom "rsi")
    (:explore::force
      (:wat::holon::Trigram
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Bind (:wat::holon::Atom "rsi") (:wat::holon::Thermometer v0 0.0 1.0))
          (:wat::holon::Bind (:wat::holon::Atom "rsi") (:wat::holon::Thermometer v1 0.0 1.0))
          (:wat::holon::Bind (:wat::holon::Atom "rsi") (:wat::holon::Thermometer v2 0.0 1.0))
          (:wat::holon::Bind (:wat::holon::Atom "rsi") (:wat::holon::Thermometer v3 0.0 1.0))
          (:wat::holon::Bind (:wat::holon::Atom "rsi") (:wat::holon::Thermometer v4 0.0 1.0))
          (:wat::holon::Bind (:wat::holon::Atom "rsi") (:wat::holon::Thermometer v5 0.0 1.0))
          (:wat::holon::Bind (:wat::holon::Atom "rsi") (:wat::holon::Thermometer v6 0.0 1.0))
          (:wat::holon::Bind (:wat::holon::Atom "rsi") (:wat::holon::Thermometer v7 0.0 1.0)))))))

;; ─── Encoding C: Bundle of form-atom positional facts ──────────────
;; Each position is a quoted form. (Atom (quote (rsi pos 0))) is its
;; own canonical-EDN-hashed vector. Per 058-001, the form IS the atom.
(:wat::core::define
  (:explore::rhythm-C
    (v0 :f64) (v1 :f64) (v2 :f64) (v3 :f64)
    (v4 :f64) (v5 :f64) (v6 :f64) (v7 :f64)
    -> :wat::holon::HolonAST)
  (:explore::force
    (:wat::holon::Bundle
      (:wat::core::vec :wat::holon::HolonAST
        (:wat::holon::Bind (:wat::holon::Atom (:wat::core::quote (rsi pos 0))) (:wat::holon::Thermometer v0 0.0 1.0))
        (:wat::holon::Bind (:wat::holon::Atom (:wat::core::quote (rsi pos 1))) (:wat::holon::Thermometer v1 0.0 1.0))
        (:wat::holon::Bind (:wat::holon::Atom (:wat::core::quote (rsi pos 2))) (:wat::holon::Thermometer v2 0.0 1.0))
        (:wat::holon::Bind (:wat::holon::Atom (:wat::core::quote (rsi pos 3))) (:wat::holon::Thermometer v3 0.0 1.0))
        (:wat::holon::Bind (:wat::holon::Atom (:wat::core::quote (rsi pos 4))) (:wat::holon::Thermometer v4 0.0 1.0))
        (:wat::holon::Bind (:wat::holon::Atom (:wat::core::quote (rsi pos 5))) (:wat::holon::Thermometer v5 0.0 1.0))
        (:wat::holon::Bind (:wat::holon::Atom (:wat::core::quote (rsi pos 6))) (:wat::holon::Thermometer v6 0.0 1.0))
        (:wat::holon::Bind (:wat::holon::Atom (:wat::core::quote (rsi pos 7))) (:wat::holon::Thermometer v7 0.0 1.0))))))

;; ─── main ──────────────────────────────────────────────────────────

(:wat::core::define (:user::main
                     (stdin  :wat::io::IOReader)
                     (stdout :wat::io::IOWriter)
                     (stderr :wat::io::IOWriter)
                     -> :())
  (:wat::core::let*
    (
     ;; ── Same 8-value series encoded three ways ────────────────
     ;; uptrend
     ((up-A   :wat::holon::HolonAST) (:explore::rhythm-A 0.30 0.36 0.42 0.48 0.54 0.60 0.66 0.72))
     ((up-B   :wat::holon::HolonAST) (:explore::rhythm-B 0.30 0.36 0.42 0.48 0.54 0.60 0.66 0.72))
     ((up-C   :wat::holon::HolonAST) (:explore::rhythm-C 0.30 0.36 0.42 0.48 0.54 0.60 0.66 0.72))
     ;; downtrend
     ((dn-A   :wat::holon::HolonAST) (:explore::rhythm-A 0.72 0.66 0.60 0.54 0.48 0.42 0.36 0.30))
     ((dn-B   :wat::holon::HolonAST) (:explore::rhythm-B 0.72 0.66 0.60 0.54 0.48 0.42 0.36 0.30))
     ((dn-C   :wat::holon::HolonAST) (:explore::rhythm-C 0.72 0.66 0.60 0.54 0.48 0.42 0.36 0.30))
     ;; mean-reverting
     ((mn-A   :wat::holon::HolonAST) (:explore::rhythm-A 0.50 0.62 0.50 0.38 0.50 0.62 0.50 0.38))
     ((mn-B   :wat::holon::HolonAST) (:explore::rhythm-B 0.50 0.62 0.50 0.38 0.50 0.62 0.50 0.38))
     ((mn-C   :wat::holon::HolonAST) (:explore::rhythm-C 0.50 0.62 0.50 0.38 0.50 0.62 0.50 0.38))

     ;; Candidates
     ;; q-exact: replay of uptrend
     ((qE-A   :wat::holon::HolonAST) (:explore::rhythm-A 0.30 0.36 0.42 0.48 0.54 0.60 0.66 0.72))
     ((qE-B   :wat::holon::HolonAST) (:explore::rhythm-B 0.30 0.36 0.42 0.48 0.54 0.60 0.66 0.72))
     ((qE-C   :wat::holon::HolonAST) (:explore::rhythm-C 0.30 0.36 0.42 0.48 0.54 0.60 0.66 0.72))
     ;; q-noisy: small perturbations from uptrend
     ((qN-A   :wat::holon::HolonAST) (:explore::rhythm-A 0.31 0.35 0.43 0.47 0.55 0.59 0.67 0.71))
     ((qN-B   :wat::holon::HolonAST) (:explore::rhythm-B 0.31 0.35 0.43 0.47 0.55 0.59 0.67 0.71))
     ((qN-C   :wat::holon::HolonAST) (:explore::rhythm-C 0.31 0.35 0.43 0.47 0.55 0.59 0.67 0.71))
     ;; q-shifted: same shape, value offset +0.10
     ((qS-A   :wat::holon::HolonAST) (:explore::rhythm-A 0.40 0.46 0.52 0.58 0.64 0.70 0.76 0.82))
     ((qS-B   :wat::holon::HolonAST) (:explore::rhythm-B 0.40 0.46 0.52 0.58 0.64 0.70 0.76 0.82))
     ((qS-C   :wat::holon::HolonAST) (:explore::rhythm-C 0.40 0.46 0.52 0.58 0.64 0.70 0.76 0.82))
     ;; q-random: no clear trend
     ((qR-A   :wat::holon::HolonAST) (:explore::rhythm-A 0.50 0.30 0.70 0.40 0.60 0.45 0.55 0.50))
     ((qR-B   :wat::holon::HolonAST) (:explore::rhythm-B 0.50 0.30 0.70 0.40 0.60 0.45 0.55 0.50))
     ((qR-C   :wat::holon::HolonAST) (:explore::rhythm-C 0.50 0.30 0.70 0.40 0.60 0.45 0.55 0.50))

     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Experiment 007: Permute (Trigram) vs form-atoms — verdict ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Same 8-value series encoded three ways at d=10k:"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  A: Trigram(raw Thermometers)"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  B: Trigram(atom-bound Thermometers)  [archived rhythm.rs shape, no deltas]"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  C: Bundle(form-atom positional)      [(Atom (quote (rsi pos i)))]"))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── METRIC 1: Direction discrimination ────────────────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "─── Direction discrimination — cos(uptrend, downtrend) ───"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Lower is better. The encoding's job is to separate opposing shapes."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "                          A           B           C"))
     ((_ :()) (:explore::print-row stdout "cos(up, dn)         "
                (:wat::holon::cosine up-A dn-A)
                (:wat::holon::cosine up-B dn-B)
                (:wat::holon::cosine up-C dn-C)))
     ((_ :()) (:explore::print-row stdout "cos(up, mean-revert)"
                (:wat::holon::cosine up-A mn-A)
                (:wat::holon::cosine up-B mn-B)
                (:wat::holon::cosine up-C mn-C)))
     ((_ :()) (:explore::print-row stdout "cos(dn, mean-revert)"
                (:wat::holon::cosine dn-A mn-A)
                (:wat::holon::cosine dn-B mn-B)
                (:wat::holon::cosine dn-C mn-C)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── METRIC 2: Self-identity ───────────────────────────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "─── Self-identity — cos(uptrend, uptrend) ──────────"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "All encodings should be deterministic: 1.0."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "                          A           B           C"))
     ((_ :()) (:explore::print-row stdout "cos(up, up)         "
                (:wat::holon::cosine up-A up-A)
                (:wat::holon::cosine up-B up-B)
                (:wat::holon::cosine up-C up-C)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── METRIC 3: Candidate × archive cosine ──────────────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "─── Candidate × uptrend archive ─────────────────────"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Higher = candidate looks more like archived uptrend."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "                          A           B           C"))
     ((_ :()) (:explore::print-row stdout "cos(exact, up)      "
                (:wat::holon::cosine qE-A up-A)
                (:wat::holon::cosine qE-B up-B)
                (:wat::holon::cosine qE-C up-C)))
     ((_ :()) (:explore::print-row stdout "cos(noisy, up)      "
                (:wat::holon::cosine qN-A up-A)
                (:wat::holon::cosine qN-B up-B)
                (:wat::holon::cosine qN-C up-C)))
     ((_ :()) (:explore::print-row stdout "cos(shifted, up)    "
                (:wat::holon::cosine qS-A up-A)
                (:wat::holon::cosine qS-B up-B)
                (:wat::holon::cosine qS-C up-C)))
     ((_ :()) (:explore::print-row stdout "cos(random, up)     "
                (:wat::holon::cosine qR-A up-A)
                (:wat::holon::cosine qR-B up-B)
                (:wat::holon::cosine qR-C up-C)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── METRIC 4: Candidate × downtrend archive ───────────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "─── Candidate × downtrend archive ───────────────────"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "An uptrend candidate should NOT look like archived downtrend."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "                          A           B           C"))
     ((_ :()) (:explore::print-row stdout "cos(exact, dn)      "
                (:wat::holon::cosine qE-A dn-A)
                (:wat::holon::cosine qE-B dn-B)
                (:wat::holon::cosine qE-C dn-C)))
     ((_ :()) (:explore::print-row stdout "cos(noisy, dn)      "
                (:wat::holon::cosine qN-A dn-A)
                (:wat::holon::cosine qN-B dn-B)
                (:wat::holon::cosine qN-C dn-C)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── METRIC 5: SimHash bucket coherence ───────────────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "─── SimHash bucket coherence — exact replay hits archive bucket? ───"))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "                          A           B           C"))
     ((_ :()) (:wat::io::IOWriter/println stdout
       (:wat::core::string::join "\t"
         (:wat::core::vec :String
           "simhash uptrend     "
           (:wat::core::i64::to-string (:wat::holon::simhash up-A))
           (:wat::core::i64::to-string (:wat::holon::simhash up-B))
           (:wat::core::i64::to-string (:wat::holon::simhash up-C))))))
     ((_ :()) (:wat::io::IOWriter/println stdout
       (:wat::core::string::join "\t"
         (:wat::core::vec :String
           "simhash downtrend   "
           (:wat::core::i64::to-string (:wat::holon::simhash dn-A))
           (:wat::core::i64::to-string (:wat::holon::simhash dn-B))
           (:wat::core::i64::to-string (:wat::holon::simhash dn-C))))))
     ((_ :()) (:wat::io::IOWriter/println stdout
       (:wat::core::string::join "\t"
         (:wat::core::vec :String
           "simhash q-exact     "
           (:wat::core::i64::to-string (:wat::holon::simhash qE-A))
           (:wat::core::i64::to-string (:wat::holon::simhash qE-B))
           (:wat::core::i64::to-string (:wat::holon::simhash qE-C))))))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Per row: A's archive simhash should == A's exact simhash, etc."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Cross-check: are uptrend and downtrend in DIFFERENT buckets?"))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── Verdict ───────────────────────────────────────────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "─── Reading the table ────────────────────────────────"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Direction discrimination — cos(up, dn):"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "    A near 1.0:  Permute(Trigram) does not scramble structured Therms."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "    B near 1.0:  shared-atom Bind does not help — atom factor cancels."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "    C below 1.0: form-atoms randomize position-by-position."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  This is what 056 RESOLUTION acknowledged as 0.72-0.96 raw cosine."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Their fix: noise subspace residuals."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Form-atoms fix it at the encoding step. No subspace required.")))

    (:wat::io::IOWriter/println stdout
      "  The form is the address. The address randomizes the value.")))
