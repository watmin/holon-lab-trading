;; ── lib.wat — module structure declaration ───────────────────────
;;
;; What modules exist and how they compose.
;; The enterprise is a tree. This declares the branches.

; rune:gaze(phantom) — module is not in the wat language
; rune:gaze(phantom) — binary is not in the wat language

;; ── Leaf modules (no children) ─────────────────────────────────

(module candle)              ; Candle struct + SQLite loader
(module event)               ; Event/EnrichedEvent, stream constructors
(module journal)             ; holon::Journal bridge, Direction, label registration
(module portfolio)           ; Portfolio struct (equity, phase, risk branches)
(module position)            ; Pending, ExitObservation, ManagedPosition
(module ledger)              ; run DB schema (the ledger that counts)
(module sizing)              ; Kelly criterion, signal weight
(module state)               ; CandleContext, TradePnl, ExitAtoms
(module treasury)            ; asset map (claim/release/swap)
(module window-sampler)      ; deterministic log-uniform window sampling

;; ── Branch modules (contain children) ──────────────────────────

(module thought              ; Layer 0: candle -> thoughts
  (module pelt))             ;   PELT changepoint detection

(module market               ; Market domain
  (module desk)              ;   trading pair's expert panel
  (module manager)           ;   manager encoding
  (module observer))         ;   Observer struct

(module risk                 ; Risk branches
  (module mod))              ;   RiskBranch struct

(module vocab                ; Thought vocabulary
  (module oscillators)       ;   Williams %R, StochRSI, UltOsc, multi-ROC
  (module flow)              ;   OBV, VWAP, MFI, buying/selling pressure
  (module persistence)       ;   Hurst, autocorrelation, ADX zones
  (module regime)            ;   KAMA ER, chop, DFA, DeMark, Aroon, fractal, entropy, GR
  (module stochastic)        ;   Stochastic %K/%D, crossovers
  (module momentum)          ;   CCI zones
  (module fibonacci)         ;   Fibonacci retracement proximity
  (module ichimoku)          ;   Ichimoku Cloud system
  (module keltner)           ;   Keltner Channels, BB position, squeeze
  (module price-action)      ;   Inside/outside bars, gaps, consecutive
  (module divergence)        ;   RSI divergence via PELT peaks/troughs
  (module timeframe))        ;   Inter-timeframe structure and narrative

;; ── Binaries ───────────────────────────────────────────────────

(binary enterprise)          ; the heartbeat — orchestrates, doesn't define
(binary build-candles)       ; raw OHLCV -> computed candles -> SQLite

;; ── Dependency graph ───────────────────────────────────────────
;;
;; The enterprise crate depends on holon-rs (local, features = ["simd"]).
;; Within the crate, the dependency flows downward:
;;
;;   enterprise.rs (binary)
;;     ├── state      → candle, journal, market, risk, vocab, thought
;;     ├── market     → journal, candle, thought, vocab
;;     ├── thought    → candle, vocab, pelt
;;     ├── vocab      → candle (only)
;;     ├── risk       → (holon primitives only)
;;     ├── portfolio  → journal
;;     ├── position   → journal, candle
;;     ├── treasury   → (standalone)
;;     ├── ledger     → (rusqlite only)
;;     ├── sizing     → (pure arithmetic)
;;     └── window-sampler → (pure arithmetic)
;;
;; vocab modules NEVER import holon. They return Fact data.
;; The encoder in thought/mod.rs is the only bridge from facts to vectors.

;; ── What lib.wat does NOT do ───────────────────────────────────
;; - Does NOT declare types (each module owns its types)
;; - Does NOT declare functions (each module owns its interface)
;; - Does NOT specify behavior (that's the individual wat files)
;; - Structure only. The map, not the territory.
