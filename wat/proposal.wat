;; proposal.wat — what a post produces, what the treasury evaluates
;;
;; Depends on: enums (Prediction, Side), distances (Distances)
;;
;; Assembled by the post during step-compute-dispatch. The post calls:
;;   market observer -> thought vector
;;   exit observer -> evaluate-and-compose -> composed + distances
;;   broker -> propose(composed) -> prediction
;;   post bundles these into a Proposal and submits to treasury.

(require primitives)
(require enums)
(require distances)

(struct proposal
  [composed-thought : Vector]     ; market thought + exit facts
  [prediction : Prediction]       ; :discrete (Grace/Violence) from the broker's reckoner
  [distances : Distances]         ; from the exit observer
  [edge : f64]                    ; the broker's edge. [0.0, 1.0]. Raw accuracy
                                  ; from the broker's curve at its current conviction.
                                  ; The treasury sorts proposals by this value and
                                  ; funds proportionally.
  [side : Side]                   ; :buy or :sell — from market observer's Up/Down prediction
  [post-idx : usize]              ; which post this came from
  [broker-slot-idx : usize])      ; which broker proposed this
