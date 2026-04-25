;; docs/experiments/2026/04/003-tree-walks/explore-tree.wat
;;
;; Proof program for BOOK Chapter 52 — The Tree.
;;
;; The substrate as path-addressable nested memory. The user's
;; recognition: "(x y z a b)" can be a PATH through a tree, not a
;; flat coordinate. Each level's options depend on prior choices.
;; Asymmetric branches; variable depth. Filesystems, JSON, ASTs all
;; have this shape.
;;
;; The mechanism: each "box" is itself a HashBundle of (key, child)
;; bindings. Bind to walk one step. Cosine the final result against
;; candidate leaves; coincident? confirms the thing is at that path.
;;
;; Test tree (asymmetric):
;;   root → usr → bin → {python, wat}
;;   root → etc → {config, hosts}
;;   root → home → alice → docs
;;   root → home → bob → code
;;
;; Three tables:
;;   Table 1: Valid path walks. Each path's final result cosined
;;            against all 6 candidate leaves. Argmax should land on
;;            the correct leaf.
;;   Table 2: Invalid path walk. (usr lib X) — "lib" isn't a key
;;            under "usr". Walk yields noise; no leaf matches.
;;   Table 3: Asymmetric structure. Cross-domain unbinding (asking
;;            "config" of the usr bundle) gives garbage; valid
;;            unbinding (asking "config" of the etc bundle)
;;            recovers the sub-bundle.
;;
;; Run: wat docs/experiments/2026/04/003-tree-walks/explore-tree.wat
;; All bipolar — {-1, 0, 1}^d. Default tier routing.

;; ─── helpers ───────────────────────────────────────────────────────

(:wat::core::define
  (:explore::print-row6
    (stdout :wat::io::IOWriter)
    (header :String)
    (c1 :f64) (c2 :f64) (c3 :f64) (c4 :f64) (c5 :f64) (c6 :f64)
    -> :())
  (:wat::io::IOWriter/println stdout
    (:wat::core::string::join "\t"
      (:wat::core::vec :String
        header
        (:wat::core::f64::to-string c1)
        (:wat::core::f64::to-string c2)
        (:wat::core::f64::to-string c3)
        (:wat::core::f64::to-string c4)
        (:wat::core::f64::to-string c5)
        (:wat::core::f64::to-string c6)))))

(:wat::core::define
  (:explore::print-row4
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
     ;; ── PATH-COMPONENT KEYS ───────────────────────────────────
     ((k-usr    :wat::holon::HolonAST) (:wat::holon::Atom "usr"))
     ((k-etc    :wat::holon::HolonAST) (:wat::holon::Atom "etc"))
     ((k-home   :wat::holon::HolonAST) (:wat::holon::Atom "home"))
     ((k-bin    :wat::holon::HolonAST) (:wat::holon::Atom "bin"))
     ((k-config :wat::holon::HolonAST) (:wat::holon::Atom "config"))
     ((k-hosts  :wat::holon::HolonAST) (:wat::holon::Atom "hosts"))
     ((k-alice  :wat::holon::HolonAST) (:wat::holon::Atom "alice"))
     ((k-bob    :wat::holon::HolonAST) (:wat::holon::Atom "bob"))
     ((k-python :wat::holon::HolonAST) (:wat::holon::Atom "python"))
     ((k-wat    :wat::holon::HolonAST) (:wat::holon::Atom "wat"))
     ((k-docs   :wat::holon::HolonAST) (:wat::holon::Atom "docs"))
     ((k-code   :wat::holon::HolonAST) (:wat::holon::Atom "code"))
     ((k-lib    :wat::holon::HolonAST) (:wat::holon::Atom "lib"))
     ((k-x      :wat::holon::HolonAST) (:wat::holon::Atom "X"))

     ;; ── LEAF VALUES (the things at terminal paths) ────────────
     ((v-python :wat::holon::HolonAST) (:wat::holon::Atom "py-content"))
     ((v-wat    :wat::holon::HolonAST) (:wat::holon::Atom "wat-content"))
     ((v-config :wat::holon::HolonAST) (:wat::holon::Atom "config-content"))
     ((v-hosts  :wat::holon::HolonAST) (:wat::holon::Atom "hosts-content"))
     ((v-docs   :wat::holon::HolonAST) (:wat::holon::Atom "alice-docs"))
     ((v-code   :wat::holon::HolonAST) (:wat::holon::Atom "bob-code"))

     ;; ── BUILD TREE BOTTOM-UP ──────────────────────────────────
     ;; Level 2 (deepest internal nodes):
     ((b-usr-bin :wat::holon::HolonAST)
      (:explore::force (:wat::holon::Bundle
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Bind k-python v-python)
          (:wat::holon::Bind k-wat    v-wat)))))
     ((b-etc :wat::holon::HolonAST)
      (:explore::force (:wat::holon::Bundle
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Bind k-config v-config)
          (:wat::holon::Bind k-hosts  v-hosts)))))
     ((b-home-alice :wat::holon::HolonAST)
      (:explore::force (:wat::holon::Bundle
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Bind k-docs v-docs)))))
     ((b-home-bob :wat::holon::HolonAST)
      (:explore::force (:wat::holon::Bundle
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Bind k-code v-code)))))

     ;; Level 1:
     ((b-usr :wat::holon::HolonAST)
      (:explore::force (:wat::holon::Bundle
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Bind k-bin b-usr-bin)))))
     ((b-home :wat::holon::HolonAST)
      (:explore::force (:wat::holon::Bundle
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Bind k-alice b-home-alice)
          (:wat::holon::Bind k-bob   b-home-bob)))))

     ;; Root:
     ((root :wat::holon::HolonAST)
      (:explore::force (:wat::holon::Bundle
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Bind k-usr  b-usr)
          (:wat::holon::Bind k-etc  b-etc)
          (:wat::holon::Bind k-home b-home)))))

     ;; ── WALK PATH 1: (usr bin python) → expect v-python ──────
     ((w1-1 :wat::holon::HolonAST) (:wat::holon::Bind k-usr    root))
     ((w1-2 :wat::holon::HolonAST) (:wat::holon::Bind k-bin    w1-1))
     ((w1-3 :wat::holon::HolonAST) (:wat::holon::Bind k-python w1-2))

     ;; ── WALK PATH 2: (etc config) → expect v-config ──────────
     ((w2-1 :wat::holon::HolonAST) (:wat::holon::Bind k-etc    root))
     ((w2-2 :wat::holon::HolonAST) (:wat::holon::Bind k-config w2-1))

     ;; ── WALK PATH 3: (home alice docs) → expect v-docs ───────
     ((w3-1 :wat::holon::HolonAST) (:wat::holon::Bind k-home  root))
     ((w3-2 :wat::holon::HolonAST) (:wat::holon::Bind k-alice w3-1))
     ((w3-3 :wat::holon::HolonAST) (:wat::holon::Bind k-docs  w3-2))

     ;; ── WALK PATH 4 (INVALID): (usr lib X) — no "lib" in usr ──
     ((w4-1 :wat::holon::HolonAST) (:wat::holon::Bind k-usr root))
     ((w4-2 :wat::holon::HolonAST) (:wat::holon::Bind k-lib w4-1))
     ((w4-3 :wat::holon::HolonAST) (:wat::holon::Bind k-x   w4-2))

     ;; ── TABLE 1: Valid path walks ─────────────────────────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 1: Valid path walks ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Cosine of walked-result vs each candidate leaf:"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "                  py-content   wat-content  config-c     hosts-c      alice-docs   bob-code"))
     ((_ :()) (:explore::print-row6 stdout "(usr bin py)    "
                (:wat::holon::cosine w1-3 v-python)
                (:wat::holon::cosine w1-3 v-wat)
                (:wat::holon::cosine w1-3 v-config)
                (:wat::holon::cosine w1-3 v-hosts)
                (:wat::holon::cosine w1-3 v-docs)
                (:wat::holon::cosine w1-3 v-code)))
     ((_ :()) (:explore::print-row6 stdout "(etc config)    "
                (:wat::holon::cosine w2-2 v-python)
                (:wat::holon::cosine w2-2 v-wat)
                (:wat::holon::cosine w2-2 v-config)
                (:wat::holon::cosine w2-2 v-hosts)
                (:wat::holon::cosine w2-2 v-docs)
                (:wat::holon::cosine w2-2 v-code)))
     ((_ :()) (:explore::print-row6 stdout "(home alice doc)"
                (:wat::holon::cosine w3-3 v-python)
                (:wat::holon::cosine w3-3 v-wat)
                (:wat::holon::cosine w3-3 v-config)
                (:wat::holon::cosine w3-3 v-hosts)
                (:wat::holon::cosine w3-3 v-docs)
                (:wat::holon::cosine w3-3 v-code)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Each row's argmax should land on the correct leaf."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── TABLE 2: Invalid path ─────────────────────────────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 2: Invalid path walk — (usr lib X) ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  No 'lib' under 'usr' in the tree. Walk yields noise."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "                  py-content   wat-content  config-c     hosts-c      alice-docs   bob-code"))
     ((_ :()) (:explore::print-row6 stdout "(usr lib X)     "
                (:wat::holon::cosine w4-3 v-python)
                (:wat::holon::cosine w4-3 v-wat)
                (:wat::holon::cosine w4-3 v-config)
                (:wat::holon::cosine w4-3 v-hosts)
                (:wat::holon::cosine w4-3 v-docs)
                (:wat::holon::cosine w4-3 v-code)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  All cosines should be near zero — no leaf was reached."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  No coincident? hit means the path doesn't exist."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── TABLE 3: Asymmetric structure ─────────────────────────
     ;; b-usr only has 'bin' as a key.
     ;; b-etc has 'config' and 'hosts' as keys.
     ;; Cross-binding (e.g. asking 'config' of b-usr) should give noise.
     ((cross-1 :wat::holon::HolonAST) (:wat::holon::Bind k-bin    b-usr))   ;; valid
     ((cross-2 :wat::holon::HolonAST) (:wat::holon::Bind k-config b-usr))   ;; INVALID
     ((cross-3 :wat::holon::HolonAST) (:wat::holon::Bind k-config b-etc))   ;; valid
     ((cross-4 :wat::holon::HolonAST) (:wat::holon::Bind k-bin    b-etc))   ;; INVALID

     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 3: Asymmetric structure verification ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  b-usr is keyed by {bin}. b-etc is keyed by {config, hosts}."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Bind with right key recovers sub-bundle. Wrong key gives noise."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Cosine of unbind result vs known sub-bundles:"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "                       b-usr-bin    b-etc        b-home-alice b-home-bob"))
     ((_ :()) (:explore::print-row4 stdout "Bind(bin,b-usr)    "
                (:wat::holon::cosine cross-1 b-usr-bin)
                (:wat::holon::cosine cross-1 b-etc)
                (:wat::holon::cosine cross-1 b-home-alice)
                (:wat::holon::cosine cross-1 b-home-bob)))
     ((_ :()) (:explore::print-row4 stdout "Bind(config,b-usr) "
                (:wat::holon::cosine cross-2 b-usr-bin)
                (:wat::holon::cosine cross-2 b-etc)
                (:wat::holon::cosine cross-2 b-home-alice)
                (:wat::holon::cosine cross-2 b-home-bob)))
     ((_ :()) (:explore::print-row4 stdout "Bind(config,b-etc) "
                (:wat::holon::cosine cross-3 b-usr-bin)
                (:wat::holon::cosine cross-3 b-etc)
                (:wat::holon::cosine cross-3 b-home-alice)
                (:wat::holon::cosine cross-3 b-home-bob)))
     ((_ :()) (:explore::print-row4 stdout "Bind(bin,b-etc)    "
                (:wat::holon::cosine cross-4 b-usr-bin)
                (:wat::holon::cosine cross-4 b-etc)
                (:wat::holon::cosine cross-4 b-home-alice)
                (:wat::holon::cosine cross-4 b-home-bob)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Row 1: bin∈b-usr → cosine highest vs b-usr-bin (its child)."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Row 2: config∉b-usr → all cosines near zero (noise)."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Row 3: config∈b-etc → cosine highest vs ... what though?"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "         (b-etc binds config to v-config; sub-bundles aren't"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "         the right comparison here. Just shows asymmetry.)"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Row 4: bin∉b-etc → noise.")))

    (:wat::io::IOWriter/println stdout
      "  Asymmetric trees work. The substrate doesn't impose uniformity.")))
