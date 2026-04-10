;; ── proposal.wat ────────────────────────────────────────────────────
;;
;; What a post produces, what the treasury evaluates. Assembled by the
;; post during step-compute-dispatch from market observer thoughts,
;; exit observer distances, and broker predictions.
;; Depends on: enums, distances.

(require enums)
(require distances)

;; ── Struct ──────────────────────────────────────────────────────

(struct proposal
  [composed-thought : Vector]  ; market thought + exit facts
  [distances : Distances]      ; from the exit observer
  [edge : f64]                 ; the broker's edge. [0.0, 1.0]. Accuracy from
                               ; the broker's curve at its current conviction.
                               ; 0.0 when unproven. The treasury sorts proposals
                               ; by this value and funds proportionally.
  [side : Side]                ; :buy or :sell — trading action, from the market
                               ; observer's Up/Down prediction. Up → :buy, Down → :sell.
  [source-asset : Asset]       ; what is deployed (e.g. USDC)
  [target-asset : Asset]       ; what is acquired (e.g. WBTC)
  [prediction : Prediction]    ; the broker's Grace/Violence prediction at proposal time.
                               ; Stashed on TradeOrigin at funding for propagation audit.
  [post-idx : usize]           ; which post this came from
  [broker-slot-idx : usize])   ; which broker proposed this
