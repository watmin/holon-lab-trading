;; ── enterprise.wat — the organization ────────────────────────────────
;;
;; The enterprise manages wealth across assets.
;; Each role has one job. Each speaks one language. Each listens to one language.
;; Nobody crosses boundaries except through defined interfaces.
;;
;; The treasury has the action call. Nobody else moves money.

;; ── The Organization ────────────────────────────────────────────────
;;
;;  Treasury (CEO)
;;  │
;;  ├── Risk (CFO)
;;  │   └── Sees: total portfolio state, cross-desk correlation,
;;  │        concentration, overall drawdown/Sharpe.
;;  │        Produces: risk multiplier (0 to 1).
;;  │        Does NOT see candles. Does NOT see indicators.
;;  │
;;  ├── Ledger (Secretary)
;;  │   └── Sees: everything. Decides: nothing. Records: everything.
;;  │
;;  ├── BTC Desk (Department Head)
;;  │   ├── Manager
;;  │   │   └── Reads observer opinions → deploy/withhold + conviction
;;  │   ├── Generalist
;;  │   │   └── All thoughts at this desk's time scale
;;  │   └── Observers
;;  │       ├── Momentum (oscillators, divergence, ROC)
;;  │       ├── Structure (PELT segments, ichimoku, fibonacci, timeframe geometry)
;;  │       ├── Volume (flow, pressure, OBV)
;;  │       ├── Narrative (temporal, calendar, timeframe direction)
;;  │       └── Regime (persistence, entropy, fractal, DFA)
;;  │
;;  ├── ETH Desk
;;  │   └── (same shape as BTC Desk, different candle stream)
;;  │
;;  ├── Gold Desk
;;  │   └── (same shape)
;;  │
;;  └── ... N desks, one per asset the treasury wants exposure to

;; ── Interfaces ──────────────────────────────────────────────────────
;;
;; Each component speaks exactly one output language:
;;
;; Observer  → (direction, conviction)
;; Manager   → (deploy/withhold, conviction)
;; Desk      → (asset, direction, conviction)  ; the manager's output + asset identity
;; Risk      → (risk-multiplier)               ; 0.0 = stop everything, 1.0 = full go
;; Treasury  → (swap asset-a asset-b amount)   ; the action
;; Ledger    → (record)                        ; the trace
;;
;; The treasury's decision:
;;   for each desk:
;;     allocation = desk.conviction × risk.multiplier × kelly(desk.curve)
;;     if allocation > threshold:
;;       (swap base-asset desk-asset amount)

;; ── Risk ────────────────────────────────────────────────────────────
;;
;; Risk is NOT per-desk. Risk is about the TREASURY.
;; "Is the total portfolio healthy?" not "is the BTC desk healthy?"
;;
;; A desk can be losing while the portfolio is fine — another desk
;; is winning. Risk sees the whole picture.
;;
;; Risk inputs:
;;   - Total treasury equity and drawdown (from treasury)
;;   - Per-desk allocation concentration (from treasury)
;;   - Cross-desk correlation (from desk conviction histories)
;;   - Overall Sharpe from the ledger
;;   - Equity curve shape (rising/falling/flat)
;;
;; Risk does NOT see:
;;   - Candle data
;;   - Indicator values
;;   - Observer opinions
;;   - Individual trade details
;;
;; Risk uses Template 2 (REACTION): OnlineSubspace learns healthy
;; portfolio states. Residual measures distance from healthy.
;; The risk multiplier scales with familiarity.

;; ── Desks ───────────────────────────────────────────────────────────
;;
;; Each desk is the enterprise we already built.
;; Same observers. Same manager. Same proof gates.
;; Different candle stream. Different asset.
;;
;; Desks do NOT know about:
;;   - Other desks
;;   - The treasury's total state
;;   - Risk assessment
;;   - How much capital they've been allocated
;;
;; Desks produce:
;;   - Direction (Buy or Sell this asset)
;;   - Conviction (how strongly)
;;   - Proof (is the manager's curve valid?)
;;
;; The desk is an island. It thinks about one market.
;; The treasury decides whether to listen.

;; ── Treasury ────────────────────────────────────────────────────────
;;
;; The treasury is the CEO. It holds the assets. It makes the call.
;;
;; Treasury reads:
;;   - Each desk's (direction, conviction, proof)
;;   - Risk's (multiplier)
;;   - Its own state (balances, utilization, fees paid)
;;
;; Treasury decides:
;;   - Which desks to fund (proof gate: only proven desks)
;;   - How much to allocate per desk (Kelly × risk × concentration cap)
;;   - When to swap (desk says deploy, risk says healthy, treasury executes)
;;
;; Treasury does NOT:
;;   - Think about markets (that's the desks)
;;   - Assess risk (that's the risk team)
;;   - Record history (that's the ledger)
;;   - Predict anything (it executes decisions, it doesn't make predictions)
;;
;; The treasury's one question: "given what my desks recommend and
;; what risk says, how should I allocate capital right now?"

;; ── Alpha ───────────────────────────────────────────────────────────
;;
;; Per-desk alpha: did this desk's actions beat holding the asset?
;; Total alpha: did the enterprise beat holding a diversified basket?
;;
;; The ledger tracks both. The treasury reads both.
;; A desk with negative alpha gets less allocation.
;; A desk with positive alpha gets more.
;; The enterprise self-organizes around what works.

;; ── What the current code has vs what this spec describes ───────────
;;
;; Has:
;;   - One desk (BTC) with 5 observers + generalist + manager
;;   - Treasury with generic asset map
;;   - Risk branches (per-desk, should be per-treasury)
;;   - Ledger recording everything
;;
;; Needs:
;;   - Desk abstraction (parameterized by asset + candle source)
;;   - Risk reads treasury state, not desk state
;;   - Treasury reads desk recommendations and risk assessment
;;   - Multiple desks running concurrently on different candle streams
;;   - Cross-desk correlation in risk assessment
;;   - Per-desk alpha tracking
;;
;; The architecture supports this. The Fact interface is asset-agnostic.
;; The observer struct is asset-agnostic. The manager encoding is
;; asset-agnostic. The treasury is already a HashMap<String, f64>.
;; The heartbeat loop is the only thing that assumes one asset.
