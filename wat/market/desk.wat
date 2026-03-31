;; -- market/desk.wat -- a trading pair's expert panel ------------------------
;;
;; A desk trades one pair (asset_a / asset_b). It consumes two candle
;; streams and produces recommendations for the treasury.
;;
;; Two phases per tick:
;;   observe -- always. Journals learn from partial data.
;;   act     -- only when both sides are fresh.
;;
;; The desk is a value. It has a tick method. The caller decides when
;; to call it. The desk doesn't know about the fold or the stream.

(require core/structural)
(require candle)

;; -- Configuration ----------------------------------------------------------

(struct desk-config
  name                   ; string -- "btc-usdc", "btc-sol"
  asset-a                ; string -- first asset in the pair
  asset-b                ; string -- second asset in the pair
  staleness-a            ; usize -- max candle age before stale (MAX = never stale)
  staleness-b)           ; usize

;; -- Side state -------------------------------------------------------------

;; The freshness state of one side of the pair.
(struct side-state
  latest                 ; (option Candle) -- most recent candle
  age                    ; usize -- candles since last update (0 = just updated)
  staleness-limit)       ; usize -- MAX means always fresh (stablecoin)

(define (side-fresh? side)
  "Is this side fresh enough to act on?"
  (or (= (:staleness-limit side) MAX)    ; stablecoin: always fresh
      (and (some? (:latest side))
           (<= (:age side) (:staleness-limit side)))))

(define (side-update side candle)
  (update side :latest (some candle) :age 0))

(define (side-tick-age side)
  (update side :age (+ (:age side) 1)))

;; -- Recommendation --------------------------------------------------------

(struct recommendation
  desk-name
  asset-a asset-b
  conviction             ; f64 -- positive = long asset_a, negative = short
  raw-cos                ; f64 -- the manager's raw cosine
  proven)                ; bool -- has the desk's manager proven its edge?

;; -- Desk -------------------------------------------------------------------

(struct desk
  name
  asset-a asset-b
  side-a                 ; SideState
  side-b)                ; SideState
  ;; TODO: observers, generalist, manager, risk will move here
  ;; from enterprise.rs as the streaming refactor progresses.
  ;; For now, the desk tracks freshness only.

(define (new-desk config)
  (desk :name (:name config)
        :asset-a (:asset-a config) :asset-b (:asset-b config)
        :side-a (side-state :latest nothing :age 0 :staleness-limit (:staleness-a config))
        :side-b (side-state :latest nothing :age 0 :staleness-limit (:staleness-b config))))

;; -- Observe ----------------------------------------------------------------

(define (observe-candle desk asset candle)
  "Feed a candle to the appropriate side. Returns true if desk cares about this asset."
  (cond
    ((= asset (:asset-a desk))
     (set! (:side-a desk) (side-update (:side-a desk) candle))
     (set! (:side-b desk) (side-tick-age (:side-b desk)))
     true)
    ((= asset (:asset-b desk))
     (set! (:side-b desk) (side-update (:side-b desk) candle))
     (set! (:side-a desk) (side-tick-age (:side-a desk)))
     true)
    (else false)))

;; -- Act gate ---------------------------------------------------------------

(define (can-act? desk)
  "Both sides must have fresh data."
  (and (side-fresh? (:side-a desk))
       (side-fresh? (:side-b desk))))

;; -- Cross rate -------------------------------------------------------------

(define (cross-rate desk)
  "Price of asset_a in terms of asset_b."
  (match ((:latest (:side-a desk)) (:latest (:side-b desk)))
    ((some a) (some b)) (if (> (:close b) 1e-10) (/ (:close a) (:close b)) nothing)
    ((some a) nothing)  (:close a)  ; base-pair: asset_b = base (price 1.0)
    _                   nothing))

;; -- What desks do NOT do ---------------------------------------------------
;; - Do NOT encode candle data (that's ThoughtEncoder)
;; - Do NOT learn patterns (that's the observers inside the desk)
;; - Do NOT manage positions (that's the treasury + position lifecycle)
;; - Do NOT decide sizing (that's the portfolio + kelly)
;; - The desk recommends. The treasury decides.
