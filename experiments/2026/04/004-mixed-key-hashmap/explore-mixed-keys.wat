;; experiments/2026/04/004-mixed-key-hashmap/explore-mixed-keys.wat
;;
;; Proof program for BOOK Chapter 53 — The Generalization.
;;
;; The user's recognition: integer indexes are a SPECIAL CASE of the
;; general key→hash→Bind pattern. The substrate's "slot" is whatever
;; vector you Bind with — derived from an integer, a string, a
;; compound (Bind of atoms), a Bundle of atoms, or any HolonAST.
;; All key types work identically through the SAME Bind operation.
;;
;; Force d=10k for everything via router override — cleaner cosines
;; than the default tier 0 (d=256) used by experiments 001-003.
;;
;; Three tables:
;;   Table 1: Pairwise cosines among 5 mixed-type keys — verify
;;            quasi-orthogonality at d=10k.
;;   Table 2: Forward lookups (key → value). Each key Bind'd against
;;            the HashMap, cosined vs all 5 values. Argmax wins.
;;   Table 3: Reverse lookups (value → key) via commutativity.
;;            Same HashMap, opposite query direction.
;;
;; Run: wat experiments/2026/04/004-mixed-key-hashmap/explore-mixed-keys.wat
;; All bipolar — {-1, 0, 1}^d. d forced to 10k via router.

;; ─── Force d=10k for everything ────────────────────────────────────
;; Default router picks tier by AST size. Override with a "dumb 10k"
;; lambda — every AST gets d=10k regardless of size. Presence-floor
;; at d=10k: sigma_fn(10000)/sqrt(10000) = 49/100 = 0.49.
(:wat::config::set-dim-router!
  (:wat::core::lambda
    ((ast :wat::holon::HolonAST) -> :Option<i64>)
    (Some 10000)))

;; ─── helpers ───────────────────────────────────────────────────────

(:wat::core::define
  (:explore::print-row5
    (stdout :wat::io::IOWriter)
    (header :String)
    (c1 :f64) (c2 :f64) (c3 :f64) (c4 :f64) (c5 :f64)
    -> :())
  (:wat::io::IOWriter/println stdout
    (:wat::core::string::join "\t"
      (:wat::core::vec :String
        header
        (:wat::core::f64::to-string c1)
        (:wat::core::f64::to-string c2)
        (:wat::core::f64::to-string c3)
        (:wat::core::f64::to-string c4)
        (:wat::core::f64::to-string c5)))))

(:wat::core::define
  (:explore::force
    (r :wat::holon::BundleResult)
    -> :wat::holon::HolonAST)
  (:wat::core::match r -> :wat::holon::HolonAST
    ((Ok h) h)
    ((Err _) (:wat::holon::Atom "_BUNDLE_ERROR_"))))

;; ─── main ──────────────────────────────────────────────────────────

(:wat::core::define (:user::main
                     (stdin  :wat::io::IOReader)
                     (stdout :wat::io::IOWriter)
                     (stderr :wat::io::IOWriter)
                     -> :())
  (:wat::core::let*
    (
     ;; ── FIVE KEYS OF DIFFERENT TYPES ──────────────────────────
     ;; All produce HolonAST; substrate treats them uniformly.

     ;; 1. Integer-like key (atom named "k-3")
     ((k-int :wat::holon::HolonAST) (:wat::holon::Atom "k-3"))

     ;; 2. String key
     ((k-str :wat::holon::HolonAST) (:wat::holon::Atom "alice"))

     ;; 3. Negative-integer-like key
     ((k-neg :wat::holon::HolonAST) (:wat::holon::Atom "k-negative-7"))

     ;; 4. Compound key — Bind of two atoms (a "tuple key")
     ((k-tuple :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "user")
        (:wat::holon::Atom "bob")))

     ;; 5. Compound key — Bundle of atoms (a "set key")
     ((k-set :wat::holon::HolonAST)
      (:explore::force (:wat::holon::Bundle
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Atom "session")
          (:wat::holon::Atom "active")))))

     ;; ── FIVE VALUES ───────────────────────────────────────────
     ((v-int   :wat::holon::HolonAST) (:wat::holon::Atom "value-at-3"))
     ((v-str   :wat::holon::HolonAST) (:wat::holon::Atom "alice-data"))
     ((v-neg   :wat::holon::HolonAST) (:wat::holon::Atom "value-at-neg-7"))
     ((v-tuple :wat::holon::HolonAST) (:wat::holon::Atom "user-bob-record"))
     ((v-set   :wat::holon::HolonAST) (:wat::holon::Atom "session-active-state"))

     ;; ── BUILD THE HASHMAP ─────────────────────────────────────
     ;; One bundle of (key ⊙ value) pairs. The substrate doesn't
     ;; care about the heterogeneous key types — they're all
     ;; HolonASTs hashing to vectors at d=10k.
     ((dict :wat::holon::HolonAST)
      (:explore::force (:wat::holon::Bundle
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Bind k-int   v-int)
          (:wat::holon::Bind k-str   v-str)
          (:wat::holon::Bind k-neg   v-neg)
          (:wat::holon::Bind k-tuple v-tuple)
          (:wat::holon::Bind k-set   v-set)))))

     ;; ── TABLE 1: Key orthogonality ────────────────────────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 1: Pairwise cosine — 5 mixed-type keys ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Verifying quasi-orthogonality. At d=10k, 5σ noise floor = 0.49"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Off-diagonal entries should be |c| << 0.49."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "        k-int(\"k-3\")  k-str(\"alice\")  k-neg(\"k-...-7\")  k-tuple        k-set"))
     ((_ :()) (:explore::print-row5 stdout "k-int   "
                (:wat::holon::cosine k-int k-int)
                (:wat::holon::cosine k-int k-str)
                (:wat::holon::cosine k-int k-neg)
                (:wat::holon::cosine k-int k-tuple)
                (:wat::holon::cosine k-int k-set)))
     ((_ :()) (:explore::print-row5 stdout "k-str   "
                (:wat::holon::cosine k-str k-int)
                (:wat::holon::cosine k-str k-str)
                (:wat::holon::cosine k-str k-neg)
                (:wat::holon::cosine k-str k-tuple)
                (:wat::holon::cosine k-str k-set)))
     ((_ :()) (:explore::print-row5 stdout "k-neg   "
                (:wat::holon::cosine k-neg k-int)
                (:wat::holon::cosine k-neg k-str)
                (:wat::holon::cosine k-neg k-neg)
                (:wat::holon::cosine k-neg k-tuple)
                (:wat::holon::cosine k-neg k-set)))
     ((_ :()) (:explore::print-row5 stdout "k-tuple "
                (:wat::holon::cosine k-tuple k-int)
                (:wat::holon::cosine k-tuple k-str)
                (:wat::holon::cosine k-tuple k-neg)
                (:wat::holon::cosine k-tuple k-tuple)
                (:wat::holon::cosine k-tuple k-set)))
     ((_ :()) (:explore::print-row5 stdout "k-set   "
                (:wat::holon::cosine k-set k-int)
                (:wat::holon::cosine k-set k-str)
                (:wat::holon::cosine k-set k-neg)
                (:wat::holon::cosine k-set k-tuple)
                (:wat::holon::cosine k-set k-set)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── TABLE 2: Forward lookups (key → value) ────────────────
     ;; Bind each key against dict; result ≈ value + noise.
     ;; Cosine vs all 5 values — argmax should pick the matching one.
     ((lookup-int   :wat::holon::HolonAST) (:wat::holon::Bind k-int   dict))
     ((lookup-str   :wat::holon::HolonAST) (:wat::holon::Bind k-str   dict))
     ((lookup-neg   :wat::holon::HolonAST) (:wat::holon::Bind k-neg   dict))
     ((lookup-tuple :wat::holon::HolonAST) (:wat::holon::Bind k-tuple dict))
     ((lookup-set   :wat::holon::HolonAST) (:wat::holon::Bind k-set   dict))

     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 2: Forward lookups (key → value) ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Bind each key with dict, cosine vs all 5 values."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Diagonal = correct match should win."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "                v-int          v-str          v-neg          v-tuple        v-set"))
     ((_ :()) (:explore::print-row5 stdout "Bind(k-int)  "
                (:wat::holon::cosine lookup-int v-int)
                (:wat::holon::cosine lookup-int v-str)
                (:wat::holon::cosine lookup-int v-neg)
                (:wat::holon::cosine lookup-int v-tuple)
                (:wat::holon::cosine lookup-int v-set)))
     ((_ :()) (:explore::print-row5 stdout "Bind(k-str)  "
                (:wat::holon::cosine lookup-str v-int)
                (:wat::holon::cosine lookup-str v-str)
                (:wat::holon::cosine lookup-str v-neg)
                (:wat::holon::cosine lookup-str v-tuple)
                (:wat::holon::cosine lookup-str v-set)))
     ((_ :()) (:explore::print-row5 stdout "Bind(k-neg)  "
                (:wat::holon::cosine lookup-neg v-int)
                (:wat::holon::cosine lookup-neg v-str)
                (:wat::holon::cosine lookup-neg v-neg)
                (:wat::holon::cosine lookup-neg v-tuple)
                (:wat::holon::cosine lookup-neg v-set)))
     ((_ :()) (:explore::print-row5 stdout "Bind(k-tuple)"
                (:wat::holon::cosine lookup-tuple v-int)
                (:wat::holon::cosine lookup-tuple v-str)
                (:wat::holon::cosine lookup-tuple v-neg)
                (:wat::holon::cosine lookup-tuple v-tuple)
                (:wat::holon::cosine lookup-tuple v-set)))
     ((_ :()) (:explore::print-row5 stdout "Bind(k-set)  "
                (:wat::holon::cosine lookup-set v-int)
                (:wat::holon::cosine lookup-set v-str)
                (:wat::holon::cosine lookup-set v-neg)
                (:wat::holon::cosine lookup-set v-tuple)
                (:wat::holon::cosine lookup-set v-set)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Each row's argmax should land on the matching value."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Same Bind operation; key types mixed; lookups all work."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── TABLE 3: Reverse lookups (value → key) ────────────────
     ;; Same dict, opposite direction. Bind's commutativity.
     ((reverse-int   :wat::holon::HolonAST) (:wat::holon::Bind v-int   dict))
     ((reverse-str   :wat::holon::HolonAST) (:wat::holon::Bind v-str   dict))
     ((reverse-tuple :wat::holon::HolonAST) (:wat::holon::Bind v-tuple dict))

     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 3: Reverse lookups (value → key) ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Bind each VALUE with dict, cosine vs all 5 keys."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Same bundle, opposite query direction (Chapter 38's commutativity)."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "                k-int          k-str          k-neg          k-tuple        k-set"))
     ((_ :()) (:explore::print-row5 stdout "Bind(v-int)  "
                (:wat::holon::cosine reverse-int k-int)
                (:wat::holon::cosine reverse-int k-str)
                (:wat::holon::cosine reverse-int k-neg)
                (:wat::holon::cosine reverse-int k-tuple)
                (:wat::holon::cosine reverse-int k-set)))
     ((_ :()) (:explore::print-row5 stdout "Bind(v-str)  "
                (:wat::holon::cosine reverse-str k-int)
                (:wat::holon::cosine reverse-str k-str)
                (:wat::holon::cosine reverse-str k-neg)
                (:wat::holon::cosine reverse-str k-tuple)
                (:wat::holon::cosine reverse-str k-set)))
     ((_ :()) (:explore::print-row5 stdout "Bind(v-tuple)"
                (:wat::holon::cosine reverse-tuple k-int)
                (:wat::holon::cosine reverse-tuple k-str)
                (:wat::holon::cosine reverse-tuple k-neg)
                (:wat::holon::cosine reverse-tuple k-tuple)
                (:wat::holon::cosine reverse-tuple k-set)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Forward and reverse via commutativity. ONE bundle. BOTH directions.")))

    (:wat::io::IOWriter/println stdout
      "  Integer indexes were a special case. Keys are general.")))
