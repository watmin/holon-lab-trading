;; :trading::log::schema-* — DDL strings, one per LogEntry variant.
;;
;; Read-locality: schema lives next to the variant it describes.
;; Each constant is the CREATE TABLE IF NOT EXISTS for one
;; variant's destination table. The slice-2
;; `:trading::rundb::Service` driver iterates `:trading::log::all-schemas`
;; at startup and `execute-ddl`'s each. Adding a variant is "add
;; a string + register it"; no service code changes.
;;
;; Schema unchanged from arc 027 — only the row source moved
;; (struct field → per-call parameter). The `paper_resolutions`
;; PRIMARY KEY (run_name, paper_id) makes INSERT OR REPLACE
;; semantics idempotent on repeat runs.

(:wat::load-file! "LogEntry.wat")


(:wat::core::define
  (:trading::log::schema-paper-resolved -> :String)
  "CREATE TABLE IF NOT EXISTS paper_resolutions (
     run_name     TEXT NOT NULL,
     thinker      TEXT NOT NULL,
     predictor    TEXT NOT NULL,
     paper_id     INTEGER NOT NULL,
     direction    TEXT NOT NULL,
     opened_at    INTEGER NOT NULL,
     resolved_at  INTEGER NOT NULL,
     state        TEXT NOT NULL,
     residue      REAL NOT NULL,
     loss         REAL NOT NULL,
     PRIMARY KEY (run_name, paper_id)
   );")


;; The registry. The service installs every entry at startup.
;; Future variants append: (:trading::log::schema-telemetry), etc.
(:wat::core::define
  (:trading::log::all-schemas -> :Vec<String>)
  (:wat::core::vec :String
    (:trading::log::schema-paper-resolved)))
