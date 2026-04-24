;; docs/arc/2026/04/014-labels-as-holons/explore-labels.wat
;;
;; Proof program for BOOK Chapter 45 — The Label.
;;
;; Under arc 037's multi-d substrate, labels expressed as holons
;; `(Bind (Atom X) (Atom Y))` occupy discrete shells on the
;; hypersphere, and measurement primitives (cosine / presence? /
;; coincident?) classify observations against them. This program
;; prints three tables verifying the three claims from the chapter:
;;
;;   Table 1: labels are distinct (pairwise cosine shows shells
;;            don't overlap — diagonal = 1.0, off-diagonal near 0).
;;   Table 2: a Bundle containing a label's vector matches that
;;            label on cosine argmax above the other three.
;;   Table 3: prototype learning — Bundle N observations per
;;            category into a prototype; held-out observations
;;            match their own prototype highest.
;;
;; Run via:   cargo run --manifest-path ../../../../wat-rs/Cargo.toml --release --bin wat -- explore-labels.wat
;; Or:        wat docs/arc/2026/04/014-labels-as-holons/explore-labels.wat
;;
;; Labels are 2-atom Binds → router picks tier 0 (d=256). Observations
;; are 4-atom Bundles → still tier 0 (sqrt(256)=16 budget, 4 cost).
;; Cross-dim cosine normalizes UP; here everything is at d=256.
;; At d=256 presence-floor is sigma_fn(d)/sqrt(d) = 7/16 ≈ 0.4375
;; (arc 024 default sigma formula: floor(sqrt(256)/2)-1 = 7).

(:wat::config::set-capacity-mode! :error)

;; ─── helpers ─────────────────────────────────────────────────────────

(:wat::core::define
  (:explore::print-row
    (stdout :wat::io::IOWriter)
    (header :String)
    (c1 :f64) (c2 :f64) (c3 :f64) (c4 :f64)
    -> :())
  (:wat::io::IOWriter/println stdout
    (:wat::core::string::join "\t"
      (:wat::core::vec :String
        header
        (:wat::core::f64::to-string c1)
        (:wat::core::f64::to-string c2)
        (:wat::core::f64::to-string c3)
        (:wat::core::f64::to-string c4)))))

;; Bundle capacity never overflows in this program (cost <= 4, budget
;; = 16 at tier 0). Force-unwrap the Result; the Err branch is
;; unreachable.
(:wat::core::define
  (:explore::force
    (r :wat::holon::BundleResult)
    -> :wat::holon::HolonAST)
  (:wat::core::match r -> :wat::holon::HolonAST
    ((Ok h) h)
    ((Err _) (:wat::holon::Atom "_BUNDLE_ERROR_"))))

;; ─── main ────────────────────────────────────────────────────────────

(:wat::core::define (:user::main
                     (stdin  :wat::io::IOReader)
                     (stdout :wat::io::IOWriter)
                     (stderr :wat::io::IOWriter)
                     -> :())
  (:wat::core::let*
    ;; ── FOUR LABELS ───────────────────────────────────────────
    ;; grace/violence × up/down — the trading lab's outcome 2×2.
    (((g-up :wat::holon::HolonAST)
      (:wat::holon::Bind (:wat::holon::Atom "grace")
                         (:wat::holon::Atom "up")))
     ((g-dn :wat::holon::HolonAST)
      (:wat::holon::Bind (:wat::holon::Atom "grace")
                         (:wat::holon::Atom "down")))
     ((v-up :wat::holon::HolonAST)
      (:wat::holon::Bind (:wat::holon::Atom "violence")
                         (:wat::holon::Atom "up")))
     ((v-dn :wat::holon::HolonAST)
      (:wat::holon::Bind (:wat::holon::Atom "violence")
                         (:wat::holon::Atom "down")))

     ;; ── TABLE 1: pairwise cosine between labels ──────────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 1: label shell separation (pairwise cosine) ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "\t\tg-up\t\t\tg-dn\t\t\tv-up\t\t\tv-dn"))
     ((_ :()) (:explore::print-row stdout "g-up"
                (:wat::holon::cosine g-up g-up)
                (:wat::holon::cosine g-up g-dn)
                (:wat::holon::cosine g-up v-up)
                (:wat::holon::cosine g-up v-dn)))
     ((_ :()) (:explore::print-row stdout "g-dn"
                (:wat::holon::cosine g-dn g-up)
                (:wat::holon::cosine g-dn g-dn)
                (:wat::holon::cosine g-dn v-up)
                (:wat::holon::cosine g-dn v-dn)))
     ((_ :()) (:explore::print-row stdout "v-up"
                (:wat::holon::cosine v-up g-up)
                (:wat::holon::cosine v-up g-dn)
                (:wat::holon::cosine v-up v-up)
                (:wat::holon::cosine v-up v-dn)))
     ((_ :()) (:explore::print-row stdout "v-dn"
                (:wat::holon::cosine v-dn g-up)
                (:wat::holon::cosine v-dn g-dn)
                (:wat::holon::cosine v-dn v-up)
                (:wat::holon::cosine v-dn v-dn)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Claim: diagonal = 1.0 (self-cosine), off-diagonal |c| < 0.4375"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  (presence-floor at d=256). Four distinct shells."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── TABLE 2: observation-containing-label recognizes the label ───
     ;; Each observation is a Bundle of 4 items: the label vector +
     ;; 3 noise atoms (moment facts that would accompany a real
     ;; observation). Cosine argmax against the 4 labels must pick
     ;; the label that was bundled in.
     ((obs-carrying-g-up :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            g-up
            (:wat::holon::Atom "morning")
            (:wat::holon::Atom "btc")
            (:wat::holon::Atom "high-volume")))))
     ((obs-carrying-g-dn :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            g-dn
            (:wat::holon::Atom "afternoon")
            (:wat::holon::Atom "eth")
            (:wat::holon::Atom "low-volume")))))
     ((obs-carrying-v-up :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            v-up
            (:wat::holon::Atom "evening")
            (:wat::holon::Atom "sol")
            (:wat::holon::Atom "volatile")))))
     ((obs-carrying-v-dn :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            v-dn
            (:wat::holon::Atom "night")
            (:wat::holon::Atom "avax")
            (:wat::holon::Atom "stable")))))

     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 2: observation → label recognition ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "observation\t\tg-up\t\t\tg-dn\t\t\tv-up\t\t\tv-dn"))
     ((_ :()) (:explore::print-row stdout "obs(g-up)"
                (:wat::holon::cosine obs-carrying-g-up g-up)
                (:wat::holon::cosine obs-carrying-g-up g-dn)
                (:wat::holon::cosine obs-carrying-g-up v-up)
                (:wat::holon::cosine obs-carrying-g-up v-dn)))
     ((_ :()) (:explore::print-row stdout "obs(g-dn)"
                (:wat::holon::cosine obs-carrying-g-dn g-up)
                (:wat::holon::cosine obs-carrying-g-dn g-dn)
                (:wat::holon::cosine obs-carrying-g-dn v-up)
                (:wat::holon::cosine obs-carrying-g-dn v-dn)))
     ((_ :()) (:explore::print-row stdout "obs(v-up)"
                (:wat::holon::cosine obs-carrying-v-up g-up)
                (:wat::holon::cosine obs-carrying-v-up g-dn)
                (:wat::holon::cosine obs-carrying-v-up v-up)
                (:wat::holon::cosine obs-carrying-v-up v-dn)))
     ((_ :()) (:explore::print-row stdout "obs(v-dn)"
                (:wat::holon::cosine obs-carrying-v-dn g-up)
                (:wat::holon::cosine obs-carrying-v-dn g-dn)
                (:wat::holon::cosine obs-carrying-v-dn v-up)
                (:wat::holon::cosine obs-carrying-v-dn v-dn)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Claim: row i's argmax = label i. The label's signal"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  survives being bundled with 3 unrelated atoms."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── TABLE 3: prototype learning ─────────────────────────────────
     ;; Simulate the deferred-learning loop. For each category, we
     ;; have 3 "training observations" — Bundles that share a
     ;; category-characteristic atom (the literal "grace-feature-X"
     ;; or "violence-feature-X"). We bundle the 3 training obs per
     ;; category into a prototype. Then we test a held-out observation
     ;; built from the same category pattern. Expected: held-out
     ;; matches its category's prototype higher than others'.

     ;; Training observations for grace-up — each shares atom
     ;; "cat-grace-up" plus one variable feature.
     ((train-gup-1 :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-grace-up")
            (:wat::holon::Atom "feat-alpha")))))
     ((train-gup-2 :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-grace-up")
            (:wat::holon::Atom "feat-beta")))))
     ((train-gup-3 :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-grace-up")
            (:wat::holon::Atom "feat-gamma")))))
     ((proto-g-up :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            train-gup-1 train-gup-2 train-gup-3))))

     ;; Training observations for grace-down.
     ((train-gdn-1 :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-grace-dn")
            (:wat::holon::Atom "feat-alpha")))))
     ((train-gdn-2 :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-grace-dn")
            (:wat::holon::Atom "feat-beta")))))
     ((train-gdn-3 :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-grace-dn")
            (:wat::holon::Atom "feat-gamma")))))
     ((proto-g-dn :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            train-gdn-1 train-gdn-2 train-gdn-3))))

     ;; Training observations for violence-up.
     ((train-vup-1 :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-violence-up")
            (:wat::holon::Atom "feat-alpha")))))
     ((train-vup-2 :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-violence-up")
            (:wat::holon::Atom "feat-beta")))))
     ((train-vup-3 :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-violence-up")
            (:wat::holon::Atom "feat-gamma")))))
     ((proto-v-up :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            train-vup-1 train-vup-2 train-vup-3))))

     ;; Training observations for violence-down.
     ((train-vdn-1 :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-violence-dn")
            (:wat::holon::Atom "feat-alpha")))))
     ((train-vdn-2 :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-violence-dn")
            (:wat::holon::Atom "feat-beta")))))
     ((train-vdn-3 :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-violence-dn")
            (:wat::holon::Atom "feat-gamma")))))
     ((proto-v-dn :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            train-vdn-1 train-vdn-2 train-vdn-3))))

     ;; HELD-OUT TEST OBSERVATIONS — same pattern as training
     ;; (category atom + a feature) but NEW feature atoms never seen
     ;; during prototype construction. The learned prototype should
     ;; still classify them correctly because the category atom's
     ;; signal dominates after 3-fold bundling.
     ((test-g-up :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-grace-up")
            (:wat::holon::Atom "feat-delta")))))
     ((test-g-dn :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-grace-dn")
            (:wat::holon::Atom "feat-delta")))))
     ((test-v-up :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-violence-up")
            (:wat::holon::Atom "feat-delta")))))
     ((test-v-dn :wat::holon::HolonAST)
      (:explore::force
        (:wat::holon::Bundle
          (:wat::core::vec :wat::holon::HolonAST
            (:wat::holon::Atom "cat-violence-dn")
            (:wat::holon::Atom "feat-delta")))))

     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 3: prototype classification (deferred learning) ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Each prototype = Bundle of 3 training obs sharing a"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  category atom. Test obs has the same category atom"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  plus a held-out feature (feat-delta, unseen during"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  training). Argmax must pick the correct prototype."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "test-obs\t\tproto-g-up\t\tproto-g-dn\t\tproto-v-up\t\tproto-v-dn"))
     ((_ :()) (:explore::print-row stdout "test(g-up)"
                (:wat::holon::cosine test-g-up proto-g-up)
                (:wat::holon::cosine test-g-up proto-g-dn)
                (:wat::holon::cosine test-g-up proto-v-up)
                (:wat::holon::cosine test-g-up proto-v-dn)))
     ((_ :()) (:explore::print-row stdout "test(g-dn)"
                (:wat::holon::cosine test-g-dn proto-g-up)
                (:wat::holon::cosine test-g-dn proto-g-dn)
                (:wat::holon::cosine test-g-dn proto-v-up)
                (:wat::holon::cosine test-g-dn proto-v-dn)))
     ((_ :()) (:explore::print-row stdout "test(v-up)"
                (:wat::holon::cosine test-v-up proto-g-up)
                (:wat::holon::cosine test-v-up proto-g-dn)
                (:wat::holon::cosine test-v-up proto-v-up)
                (:wat::holon::cosine test-v-up proto-v-dn)))
     ((_ :()) (:explore::print-row stdout "test(v-dn)"
                (:wat::holon::cosine test-v-dn proto-g-up)
                (:wat::holon::cosine test-v-dn proto-g-dn)
                (:wat::holon::cosine test-v-dn proto-v-up)
                (:wat::holon::cosine test-v-dn proto-v-dn)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Claim: row i's argmax = proto-i. Prototype learning")))

    (:wat::io::IOWriter/println stdout
      "  via Bundle-as-superposition, classification via cosine.")))
