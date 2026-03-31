;; ── lib.wat — module structure declaration ───────────────────────
;;
;; What modules exist and how they compose.
;; The enterprise is a tree. This declares the branches.

;; declare-module: declares a compilation unit (a Rust `pub mod`).
;; declare-binary: declares an executable entry point (a Rust `[[bin]]`).
;; These are crate-structure declarations, not runtime constructs.

;; ── Leaf modules (no children) ─────────────────────────────────

; rune:gaze(phantom) — declare-module is not in the wat language
(declare-module candle)              ; Candle struct + SQLite loader
(declare-module event)               ; Event/EnrichedEvent, stream constructors
(declare-module journal)             ; holon::Journal bridge, Direction, label registration
(declare-module portfolio)           ; Portfolio struct (equity, phase, risk branches)
(declare-module position)            ; Pending, ExitObservation, ManagedPosition
(declare-module ledger)              ; run DB schema (the ledger that counts)
(declare-module sizing)              ; Kelly criterion, signal weight
(declare-module state)               ; CandleContext, TradePnl, ExitAtoms
(declare-module treasury)            ; asset map (claim/release/swap)
(declare-module window-sampler)      ; deterministic log-uniform window sampling

;; ── Branch modules (contain children) ──────────────────────────

(declare-module thought              ; Layer 0: candle -> thoughts
  (declare-module pelt))             ;   PELT changepoint detection

(declare-module market               ; Market domain
  (declare-module desk)              ;   trading pair's expert panel
  (declare-module manager)           ;   manager encoding
  (declare-module observer))         ;   Observer struct

(declare-module risk                 ; Risk branches
  (declare-module mod))              ;   RiskBranch struct

(declare-module vocab                ; Thought vocabulary
  (declare-module oscillators)       ;   Williams %R, StochRSI, UltOsc, multi-ROC
  (declare-module flow)              ;   OBV, VWAP, MFI, buying/selling pressure
  (declare-module persistence)       ;   Hurst, autocorrelation, ADX zones
  (declare-module regime)            ;   KAMA ER, chop, DFA, DeMark, Aroon, fractal, entropy, GR
  (declare-module stochastic)        ;   Stochastic %K/%D, crossovers
  (declare-module momentum)          ;   CCI zones
  (declare-module fibonacci)         ;   Fibonacci retracement proximity
  (declare-module ichimoku)          ;   Ichimoku Cloud system
  (declare-module keltner)           ;   Keltner Channels, BB position, squeeze
  (declare-module price-action)      ;   Inside/outside bars, gaps, consecutive
  (declare-module divergence)        ;   RSI divergence via PELT peaks/troughs
  (declare-module timeframe))        ;   Inter-timeframe structure and narrative

;; ── Binaries ───────────────────────────────────────────────────

; rune:gaze(phantom) — declare-binary is not in the wat language
(declare-binary enterprise)          ; the heartbeat — orchestrates, doesn't define
(declare-binary build-candles)       ; raw OHLCV -> computed candles -> SQLite

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
