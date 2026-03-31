;; ── lib.wat — module structure ────────────────────────────────────
;;
;; The directory IS the module system. Each .wat file is a module.
;; This file documents the tree and the dependency graph.

;; ── Module tree ──────────────────────────────────────────────────
;;
;; Leaf modules:
;;   candle          — Candle struct + SQLite loader
;;   event           — Event/EnrichedEvent, stream constructors
;;   journal         — holon::Journal bridge, Direction, label registration
;;   portfolio       — Portfolio struct (equity, phase, risk branches)
;;   position        — Pending, ExitObservation, ManagedPosition
;;   ledger          — run DB schema (the ledger that counts)
;;   sizing          — Kelly criterion, signal weight
;;   state           — CandleContext, TradePnl, ExitAtoms
;;   treasury        — asset map (claim/release/swap)
;;   window-sampler  — deterministic log-uniform window sampling
;;
;; Branch modules:
;;   thought/        — Layer 0: candle → thoughts
;;     pelt          — PELT changepoint detection
;;   market/         — Market domain
;;     desk          — trading pair's expert panel
;;     manager       — manager encoding
;;     observer      — Observer struct
;;   risk/           — Risk branches
;;     mod           — RiskBranch struct
;;   vocab/          — Thought vocabulary (12 modules)
;;
;; Binaries:
;;   bin/enterprise      — the heartbeat
;;   bin/build-candles   — raw OHLCV → computed candles → SQLite

;; ── Dependency graph ─────────────────────────────────────────────
;;
;;   enterprise (binary)
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
;; The encoder in thought/mod is the only bridge from facts to vectors.
