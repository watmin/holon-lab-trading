# 059-002 — Telemetry sweep on the new substrate

**Status:** PROPOSED 2026-04-29. Pre-implementation reasoning artifact. Depends on the substrate arcs 079 + 080 + 081 landing first.

**Umbrella:** [`docs/proposals/2026/04/059-the-trader-on-substrate/`](../).

**Predecessors:**
- 059-001 (L1/L2 caches) — milestone 1 + 2 shipped (cache primitives + substrate uplift). Milestone 3 (thinker integration with reporters) lands in this sub-arc.
- Substrate arc 079 (wat-edn shims).
- Substrate arc 080 (`:wat::std::telemetry::Sqlite<E,G>` — generic Service shell with caller-provided dispatcher + stats-translator).
- Substrate arc 081 (`:wat::std::telemetry::Console<E,G>` — EDN/JSON-per-line dev sink).

**Surfaced by:** Building proof_004 (cache telemetry, T7) revealed that the lab's `:trading::rundb::Service` is a generic Service with a trader-specific entry enum welded in. The user's recognition (2026-04-29):

> "RunDbService - is a bad name... we need something generic"
> "the LogEntry /must/ be user defined - we do not provide anything here"

The substrate arcs above expose the right primitives. This sub-arc is the lab-side sweep that consumes them.

---

## What this sub-arc is, and is not

**Is:**
- A lab-side rename: `:trading::rundb::Service` → `:trading::telemetry::Sqlite` (lab-thin wrapper that picks the substrate Service's dispatcher).
- A lab entry enum: `:trading::telemetry::Entry` — superset of substrate's expectations, including domain-specific `PaperResolved` and any future trader event variants. Substrate doesn't see them; the lab dispatcher does.
- A lab dispatcher: `:trading::telemetry::dispatch (db entry) -> :()` — match-dispatches each entry variant to its sqlite table (`paper_resolutions`, `telemetry`, …).
- A lab stats-translator: `:trading::telemetry::translate-stats (Sqlite::Stats) -> :Vec<Entry>` — encodes the substrate Service's own counters as Entry values.
- A lab entry-maker: `:trading::telemetry::maker/make (now-fn) -> :EntryMaker` — closure over a clock; constructs `Entry` values with timestamps. Used by every Reporter regardless of destination.
- Reporter sweep: cache reporter, treasury reporter, future broker reporter — all use the entry-maker + the substrate Service's batch-log path.
- proof_005 — the originally-requested rundb-self-heartbeat integ. Now realized via the substrate's tick-window fired through the lab's dispatcher.

**Is not:**
- A console-as-default switch. The trader keeps writing to sqlite as the production destination; Console is a dev-time wiring choice (one-line swap in main.wat).
- A change to the lab's RunDb wrapper (`:trading::rundb::RunDb` stays as the wat value passed to dispatchers).
- A removal of the existing `LogEntry::PaperResolved` schema. The schema rides through into `Entry::PaperResolved` with the same column meanings.
- A free-form-text exit. Stderr checkpoints (T1/T2/T3 in proof_002/003) keep using `Console/err`; only structured records go through telemetry::* destinations.

---

## Surface

### Lab entry enum (lab-defined, NOT substrate)

```scheme
(:wat::core::enum :trading::telemetry::Entry
  ;; Substrate's two would-be-shipped variants, defined HERE because
  ;; the substrate ships ZERO variants per arc 080's discipline.
  (Metric
    (namespace :String) (id :String) (dimensions :String)
    (timestamp-ns :i64)
    (metric-name :String) (metric-value :f64) (metric-unit :String))
  ;; Trader-specific structured event.
  (PaperResolved
    (run-name :String) (thinker :String) (predictor :String)
    (paper-id :i64) (direction :String)
    (opened-at :i64) (resolved-at :i64)
    (state :String) (residue :f64) (loss :f64))
  ;; Future variants (broker decisions, observer outcomes, etc.) land
  ;; here as the trader grows.
  )
```

### Lab dispatcher

```scheme
(:wat::core::define
  (:trading::telemetry::dispatch
    (db :trading::rundb::RunDb)
    (entry :trading::telemetry::Entry)
    -> :())
  (:wat::core::match entry -> :()
    ((:Entry::Metric ns id dim ts name value unit)
      (:trading::rundb::log-telemetry db ns id dim ts name value unit))
    ((:Entry::PaperResolved ...)
      (:trading::rundb::log-paper-resolved db ...))))
```

### Lab stats-translator

```scheme
(:wat::core::define
  (:trading::telemetry::translate-stats
    (stats :wat::std::telemetry::Stats)
    -> :Vec<trading::telemetry::Entry>)
  (:wat::core::let*
    (((ts :i64) (:wat::time::epoch-millis (:wat::time::now)))
     ((dimensions :String) "{\"service\":\"telemetry\"}"))
    (:wat::core::vec :trading::telemetry::Entry
      (:Entry::Metric "telemetry" "self" dimensions ts
        "batches" (:wat::core::i64::to-f64 (:Stats/batches stats))
        "Count")
      ;; ... entries / max-batch-size analogously
      )))
```

### Lab entry-maker

```scheme
(:wat::core::struct :trading::telemetry::EntryMaker
  (now-fn :fn() -> :wat::time::Instant))

(:wat::core::define
  (:trading::telemetry::maker/make
    (now-fn :fn() -> :wat::time::Instant)
    -> :EntryMaker)
  (:trading::telemetry::EntryMaker/new now-fn))

(:wat::core::define
  (:trading::telemetry::EntryMaker/metric
    (maker :EntryMaker)
    (namespace :String) (id :String) (dimensions :String)
    (metric-name :String) (metric-value :f64) (metric-unit :String)
    -> :trading::telemetry::Entry)
  (:wat::core::let*
    (((now-fn :...) (:EntryMaker/now-fn maker))
     ((ts :i64) (:wat::time::epoch-millis (now-fn))))
    (:Entry::Metric namespace id dimensions ts
      metric-name metric-value metric-unit)))
```

Test usage:
```scheme
((maker :EntryMaker)
 (:trading::telemetry::maker/make
   (:wat::core::lambda () -> :wat::time::Instant
     ;; Frozen clock for deterministic assertions
     (:wat::time::epoch-millis-as-instant 1730000000000))))
```

Production usage: `(maker/make (:wat::core::lambda () -> :Instant (:wat::time::now)))`.

### Producers (cache reporter, treasury reporter, …)

Cache reporter from proof_004 retrofits to use the entry-maker:

```scheme
(:wat::core::define
  (:trading::cache::reporter/make
    (req-tx :Sqlite::ReqTx) (ack-tx :AckTx) (ack-rx :AckRx)
    (maker :trading::telemetry::EntryMaker)
    (cache-id :String) (layer :String)
    -> :Reporter)
  (:wat::core::lambda
    ((report :Report) -> :())
    (:wat::core::match report -> :()
      ((:Report::Metrics stats)
        (:wat::core::let*
          (((dim :String) (... cache-id, layer ...))
           ((entries :Vec<Entry>)
            (:wat::core::vec :Entry
              (:EntryMaker/metric maker "cache" cache-id dim
                "lookups" (... stats.lookups ...) "Count")
              ;; ... rest of the 5 metrics, all via maker ...
              ))
           ((_ :())
            (:trading::telemetry::Sqlite/batch-log
              req-tx ack-tx ack-rx entries)))
          ())))))
```

Treasury (already a heavy rundb consumer per existing call sites) updates similarly — every metric construction goes through the maker.

---

## Slice plan

Three slices, each with its own green checkpoint per the iterative-complexity discipline.

### Slice 1 — Lab entry enum + dispatcher + stats-translator + entry-maker

`wat/io/telemetry/Entry.wat` + `wat/io/telemetry/dispatch.wat` + `wat/io/telemetry/maker.wat`:
- `Entry` enum (Metric + PaperResolved at first; grow as needed).
- `dispatch` fn — match-dispatches.
- `translate-stats` fn — encodes substrate Stats as Entry::Metric values.
- `maker/make` factory.

Tests at `wat-tests/io/telemetry/`:
- entry-maker with frozen clock — assert deterministic timestamps.
- dispatch is a stub at this point (writes to a Vec, not sqlite); pure unit tests.
- Stats translation — feed in known Stats; assert vec contents.

### Slice 2 — Replace `:trading::rundb::Service` with `:trading::telemetry::Sqlite`

Lab thin wrapper:
```scheme
(:wat::core::define
  (:trading::telemetry::Sqlite
    (path :String) (count :i64)
    (cadence :MetricsCadence<G>)
    -> :Spawn<Entry>)
  (:wat::std::telemetry::Sqlite path count
    :trading::telemetry::dispatch
    :trading::telemetry::translate-stats
    cadence))
```

Sweep:
- Update all 6 call sites (proof_002, proof_003, proof_004, treasury, main, wat-tests/io/RunDbService.wat).
- Old `:trading::rundb::Service` deletes from `wat/io/RunDbService.wat`.
- `:trading::rundb::RunDb` (the wat-side wrapper) stays — it's the value passed to the dispatcher.

Tests:
- proof_002, proof_003, proof_004 still pass unchanged.
- wat-suite still passes.

### Slice 3 — proof_005 (rundb self-heartbeat) + cache reporter migration

- proof_005 — Service spawns with a counter-cadence; sends N batches; assert telemetry table has the heartbeat rows tagged `service:"telemetry"`.
- cache reporter migrates to use the entry-maker. proof_004 still passes (functionally unchanged; just routed through the maker).
- Treasury reporter migrates similarly.

---

## Open questions

### Q1 — Should the lab Telemetry::Console be wired as a runtime swap?

The trader's `main.wat` currently doesn't even spawn a rundb Service in production (per the earlier audit — only tests spawn it). Once it does (this sub-arc), should it accept a `--console` flag for dev-mode or a config-time choice?

Default: defer. First land Sqlite as the only destination; add Console-swap later when the trader binary actually uses telemetry.

### Q2 — Where does the lab telemetry namespace land?

Current rundb is at `wat/io/RunDbService.wat`. The new home:
- `wat/io/telemetry/Entry.wat`
- `wat/io/telemetry/dispatch.wat`
- `wat/io/telemetry/maker.wat`
- `wat/io/telemetry/Sqlite.wat` (the thin lab wrapper)

`wat/io/RunDb.wat` (the underlying wat value wrapping the sqlite handle) stays at its current path — it's the storage primitive, not the service.

### Q3 — Migrate `wat/io/log/*.wat` (LogEntry, schema, telemetry helpers, rate-gate)?

Today's `wat/io/log/` directory has:
- `LogEntry.wat` — old enum (pre-rename)
- `schema.wat` — DDL strings
- `telemetry.wat` — `emit-metric` helper (lab-side); somewhat duplicates the entry-maker
- `rate-gate.wat` — `tick-gate` (used by MetricsCadence factories)

After this sub-arc:
- `LogEntry.wat` retires (replaced by `telemetry/Entry.wat`).
- `schema.wat` stays (DDL is dispatcher-side).
- `telemetry.wat` retires (replaced by `telemetry/maker.wat`).
- `rate-gate.wat` stays (still useful as the body of cadence tick-fns).

Cross-ref in the slice 2 commit message.

---

## Test strategy

- Slice 1: pure data tests (frozen clock, stub dispatcher).
- Slice 2: full-stack regression — proof_002/003/004 + wat-suite all pass.
- Slice 3: proof_005 demonstrates the substrate's tick-window fires + the lab's translate-stats encodes correctly + the dispatcher writes to telemetry table. Verified via SQL on `runs/proof-005-*.db`.

---

## Dependencies

**Upstream (must ship before this sub-arc starts):**
- Arc 079 (wat-edn shims) — only needed for the optional Console destination; not strictly load-bearing for sqlite-only path.
- Arc 080 (substrate Sqlite Service) — REQUIRED. The substrate's generic Service shell + Stats + MetricsCadence types are what the lab consumes.
- Arc 081 (telemetry::Console) — only needed if the lab wants the dev-mode Console swap as part of this sub-arc; can defer.

**Downstream:**
- 059-001 milestone 3 closes when proof_005 lands. T7 (telemetry rows in rundb at gate cadence) is fully covered.

**Parallel-safe with:** Arc 082 (SERVICE-PROGRAMS docs) — the docs slice unblocks reading + writing this kind of multi-driver code more cleanly, but doesn't gate the implementation.

PERSEVERARE.
