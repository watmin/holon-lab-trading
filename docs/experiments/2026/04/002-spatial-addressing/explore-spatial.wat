;; docs/experiments/2026/04/002-spatial-addressing/explore-spatial.wat
;;
;; Proof program for BOOK Chapter 51 — The Spatial Database.
;;
;; The wat substrate as a multi-dimensional content-addressed memory.
;; Two basis atoms (u-x, u-y) define a 2D coordinate system. ASTs at
;; coordinate (x, y) are bundled bindings of the basis atoms with
;; Thermometer-encoded values. The Thermometer trick — "anything on
;; the left side IS the thing" — applied to BOTH axes gives us
;; native 2D geometry: cosine reflects 2D distance.
;;
;;   Table 1: Pairwise cosine — 5 ASTs at known (x,y) positions.
;;            2D distance reflected in cosine. Diagonal corners
;;            have lower cosine than adjacent corners.
;;   Table 2: Half-space query — "northern half (y ≈ 0.5),
;;            x unspecified." Single-axis filtering: northern ASTs
;;            match regardless of x; southern don't.
;;   Table 3: Coordinate extraction — given an arbitrary AST, recover
;;            its (x, y) via unbinding + cleanup against probes.
;;            Implementation of `hash-ast-to-coords` from the chapter.
;;
;; Run: wat docs/experiments/2026/04/002-spatial-addressing/explore-spatial.wat
;; All operations at d=256 (default tier 0). Bipolar substrate.
;; Capacity-mode :error is the substrate default.

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

;; Construct an AST at 2D coordinate (x, y) on the (u-x, u-y) basis.
;; AST = Bundle(Bind(u-x, Therm(x)), Bind(u-y, Therm(y)))
(:wat::core::define
  (:explore::point-at
    (u-x :wat::holon::HolonAST)
    (u-y :wat::holon::HolonAST)
    (x :f64) (y :f64)
    -> :wat::holon::HolonAST)
  (:explore::force (:wat::holon::Bundle
    (:wat::core::vec :wat::holon::HolonAST
      (:wat::holon::Bind u-x (:wat::holon::Thermometer x -1.0 1.0))
      (:wat::holon::Bind u-y (:wat::holon::Thermometer y -1.0 1.0))))))

;; ─── main ──────────────────────────────────────────────────────────

(:wat::core::define (:user::main
                     (stdin  :wat::io::IOReader)
                     (stdout :wat::io::IOWriter)
                     (stderr :wat::io::IOWriter)
                     -> :())
  (:wat::core::let*
    (
     ;; ── BASIS ATOMS — the two coordinate axes ─────────────────
     ((u-x :wat::holon::HolonAST) (:wat::holon::Atom "axis-x"))
     ((u-y :wat::holon::HolonAST) (:wat::holon::Atom "axis-y"))

     ;; ── 5 ASTs at known 2D positions ──────────────────────────
     ;; NW (-0.7, +0.7), NE (+0.7, +0.7),
     ;; SW (-0.7, -0.7), SE (+0.7, -0.7),
     ;; C  ( 0.0,  0.0)
     ((nw :wat::holon::HolonAST) (:explore::point-at u-x u-y -0.7  0.7))
     ((ne :wat::holon::HolonAST) (:explore::point-at u-x u-y  0.7  0.7))
     ((sw :wat::holon::HolonAST) (:explore::point-at u-x u-y -0.7 -0.7))
     ((se :wat::holon::HolonAST) (:explore::point-at u-x u-y  0.7 -0.7))
     ((c  :wat::holon::HolonAST) (:explore::point-at u-x u-y  0.0  0.0))

     ;; ── TABLE 1: Pairwise cosine matrix ───────────────────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 1: Pairwise cosine — 5 ASTs at known 2D positions ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "         NW(-0.7,+0.7)        NE(+0.7,+0.7)        SW(-0.7,-0.7)        SE(+0.7,-0.7)        C(0,0)"))
     ((_ :()) (:explore::print-row5 stdout "NW   "
                (:wat::holon::cosine nw nw)
                (:wat::holon::cosine nw ne)
                (:wat::holon::cosine nw sw)
                (:wat::holon::cosine nw se)
                (:wat::holon::cosine nw c)))
     ((_ :()) (:explore::print-row5 stdout "NE   "
                (:wat::holon::cosine ne nw)
                (:wat::holon::cosine ne ne)
                (:wat::holon::cosine ne sw)
                (:wat::holon::cosine ne se)
                (:wat::holon::cosine ne c)))
     ((_ :()) (:explore::print-row5 stdout "SW   "
                (:wat::holon::cosine sw nw)
                (:wat::holon::cosine sw ne)
                (:wat::holon::cosine sw sw)
                (:wat::holon::cosine sw se)
                (:wat::holon::cosine sw c)))
     ((_ :()) (:explore::print-row5 stdout "SE   "
                (:wat::holon::cosine se nw)
                (:wat::holon::cosine se ne)
                (:wat::holon::cosine se sw)
                (:wat::holon::cosine se se)
                (:wat::holon::cosine se c)))
     ((_ :()) (:explore::print-row5 stdout "C    "
                (:wat::holon::cosine c nw)
                (:wat::holon::cosine c ne)
                (:wat::holon::cosine c sw)
                (:wat::holon::cosine c se)
                (:wat::holon::cosine c c)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Adjacent corners (1 axis differs): NW-NE, NW-SW, NE-SE, SW-SE."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Diagonal corners (both axes differ): NW-SE, NE-SW."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Adjacent should have higher cosine than diagonal."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Center vs corners: equidistant — roughly equal cosines."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── TABLE 2: Half-space query ─────────────────────────────
     ;; Query encodes "northern (y ≈ 0.5), x unspecified."
     ;; Bind to u-y only — the x axis is left unconstrained.
     ((q-north :wat::holon::HolonAST)
      (:wat::holon::Bind u-y (:wat::holon::Thermometer 0.5 -1.0 1.0)))

     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 2: Half-space query — \"north (y ≈ 0.5), x unspecified\" ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "          NW (north)     NE (north)     SW (south)     SE (south)     C (mid)"))
     ((_ :()) (:explore::print-row5 stdout "cosine"
                (:wat::holon::cosine q-north nw)
                (:wat::holon::cosine q-north ne)
                (:wat::holon::cosine q-north sw)
                (:wat::holon::cosine q-north se)
                (:wat::holon::cosine q-north c)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Query is bound to u-y only — x dimension unspecified."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  NW and NE (northern, regardless of x): high cosine."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  SW and SE (southern): low or negative cosine."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  C (mid-y): in between."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Single-axis filtering as a substrate-native operation."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── TABLE 3: Coordinate extraction ────────────────────────
     ;; (hash-ast-to-coords ast) -> (x, y) implemented via:
     ;;   1. Unbind axis: Bind(u-x, ast) ≈ Therm(x_val) + noise
     ;;   2. Cleanup against probe Therm values to recover x_val.
     ;; Same procedure for y.
     ;;
     ;; Use AST = NE (true coords (0.7, 0.7)). Probe x and y at
     ;; five candidate Thermometer positions: {-0.7, -0.3, 0, 0.3, 0.7}.

     ;; Unbind NE on each axis.
     ((unbind-x :wat::holon::HolonAST) (:wat::holon::Bind u-x ne))
     ((unbind-y :wat::holon::HolonAST) (:wat::holon::Bind u-y ne))

     ;; Probe Thermometer values along each axis.
     ((probe-n07 :wat::holon::HolonAST) (:wat::holon::Thermometer -0.7 -1.0 1.0))
     ((probe-n03 :wat::holon::HolonAST) (:wat::holon::Thermometer -0.3 -1.0 1.0))
     ((probe-00  :wat::holon::HolonAST) (:wat::holon::Thermometer  0.0 -1.0 1.0))
     ((probe-p03 :wat::holon::HolonAST) (:wat::holon::Thermometer  0.3 -1.0 1.0))
     ((probe-p07 :wat::holon::HolonAST) (:wat::holon::Thermometer  0.7 -1.0 1.0))

     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 3: Coordinate extraction — (hash-ast-to-coords ast) ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Source AST: NE at true coordinates (0.7, 0.7)."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Probe: cosine(unbind-axis(ast), Therm(probe_val))."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Argmax probe = recovered coordinate on that axis."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "       probe=-0.7  probe=-0.3  probe=0.0   probe=0.3   probe=0.7"))
     ((_ :()) (:explore::print-row5 stdout "x-axis"
                (:wat::holon::cosine unbind-x probe-n07)
                (:wat::holon::cosine unbind-x probe-n03)
                (:wat::holon::cosine unbind-x probe-00)
                (:wat::holon::cosine unbind-x probe-p03)
                (:wat::holon::cosine unbind-x probe-p07)))
     ((_ :()) (:explore::print-row5 stdout "y-axis"
                (:wat::holon::cosine unbind-y probe-n07)
                (:wat::holon::cosine unbind-y probe-n03)
                (:wat::holon::cosine unbind-y probe-00)
                (:wat::holon::cosine unbind-y probe-p03)
                (:wat::holon::cosine unbind-y probe-p07)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Both rows should peak at probe=0.7 (the AST's true (x, y))."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Cosine should DECREASE smoothly as probe moves away from 0.7."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  This is `hash-ast-to-coords` operationalized.")))

    (:wat::io::IOWriter/println stdout
      "  The substrate is a spatial database. Coordinates are queryable.")))
