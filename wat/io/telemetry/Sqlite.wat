;; :trading::telemetry::Sqlite — thin wrapper over substrate's
;; :wat::std::telemetry::Sqlite/auto-spawn.
;;
;; Lab proposal 059-002. Replaces:
;;   - arc 029's :trading::rundb::Service (RunDb-shim CSP wrapper)
;;   - arc 083 slice 2's lab-side :trading::telemetry::Sqlite/spawn
;;     (consumer-provides-hooks shape)
;;
;; The substrate (arc 085) walks the :trading::log::LogEntry enum decl
;; at startup, derives one CREATE TABLE per Tagged variant, derives
;; the per-variant INSERT, and dispatches each entry by variant_name
;; through its prepared-statement cache. The lab keeps the enum decl
;; (the source of truth) and a thin spawn wrapper; everything else
;; deletes — dispatch.wat, maker.wat, translate-stats.wat, schema.wat,
;; RunDb.wat, RunDbService.wat, and the lab's Rust WatRunDb shim.
;;
;; Naming consequence: tables are now named per the substrate's
;; PascalCase→snake_case derivation. `PaperResolved` → `paper_resolved`
;; (was `paper_resolutions`); `Telemetry` → `telemetry` (unchanged).
;; Existing on-disk runs from before this arc need either a manual
;; rename of the table or a fresh DB.

(:wat::load-file! "../log/LogEntry.wat")


;; The spawn return shape, aliased so call sites don't carry the
;; nested Service<Spawn<LogEntry>> generics. Matches arc 077's
;; "alias nested generics ≥3 brackets" rule. Aliases through the
;; substrate's already-aliased Spawn<E> — the type-checker
;; transitively expands.
(:wat::core::typealias :trading::telemetry::Spawn
  :wat::std::telemetry::Service::Spawn<trading::log::LogEntry>)


;; Lab's pragma policy. Substrate ships zero defaults; the lab makes
;; its own choice. WAL gives concurrent reads while a writer holds
;; the connection; synchronous=NORMAL trades a tiny crash-window for
;; ~10x flush throughput. Both are the lab's decision, not the
;; language's. Other labs (or future trading subdomains with
;; different durability needs) pick their own.
(:wat::core::define
  (:trading::telemetry::Sqlite::pre-install
    (db :wat::sqlite::Db)
    -> :())
  (:wat::core::let*
    (((_w :()) (:wat::sqlite::pragma db "journal_mode" "WAL"))
     ((_s :()) (:wat::sqlite::pragma db "synchronous" "NORMAL")))
    ()))


(:wat::core::define
  (:trading::telemetry::Sqlite/spawn<G>
    (path :String)
    (count :i64)
    (cadence :wat::std::telemetry::Service::MetricsCadence<G>)
    -> :trading::telemetry::Spawn)
  (:wat::std::telemetry::Sqlite/auto-spawn
    :trading::log::LogEntry path count cadence
    :trading::telemetry::Sqlite::pre-install))
