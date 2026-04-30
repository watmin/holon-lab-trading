;; wat/programs/run.wat — per-run identity helpers.
;;
;; Each run of the lab binary owns three files:
;;   runs/<descriptor>-<epoch-seconds>.out  — :info / :debug lines
;;   runs/<descriptor>-<epoch-seconds>.err  — :warn / :error lines
;;   runs/<descriptor>-<epoch-seconds>.db   — high-fidelity LogEntry rows
;;
;; The descriptor identifies the program; the epoch-seconds suffix
;; makes each run unique. Per memory `feedback_never_delete_runs`,
;; runs are training data — they accumulate; never `rm -rf runs/`.

(:wat::core::struct :trading::run::Paths
  (out :wat::core::String)
  (err :wat::core::String)
  (db  :wat::core::String))


;; Build the three paths from a descriptor + the wall-clock epoch
;; seconds. Pure data — no I/O.
(:wat::core::define
  (:trading::run/paths/make
    (descriptor :wat::core::String)
    (now :wat::time::Instant)
    -> :trading::run::Paths)
  (:wat::core::let*
    (((stem :wat::core::String)
      (:wat::core::string::concat "runs/"
        (:wat::core::string::concat descriptor
          (:wat::core::string::concat "-"
            (:wat::core::i64::to-string
              (:wat::time::epoch-seconds now)))))))
    (:trading::run::Paths/new
      (:wat::core::string::concat stem ".out")
      (:wat::core::string::concat stem ".err")
      (:wat::core::string::concat stem ".db"))))
