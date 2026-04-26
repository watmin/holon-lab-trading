;; :trading::log::tick-gate — values-up rate gate.
;;
;; Mirrors the archive's
;; `archived/pre-wat-native/src/programs/telemetry.rs::make_rate_gate`
;; semantically — "open every N ms; closed otherwise" — without the
;; archive's `Mutex<Instant>` (zero-mutex per substrate principle).
;;
;; The Ruby shape that motivated this:
;;
;;   can_emit = -> do
;;     time = Time.at(0)
;;     now = Time.now
;;     if now.to_i > time.to_i + 5
;;       time = now
;;       true
;;     else
;;       false
;;     end
;;   end
;;
;; Wat closures don't have first-class mutable captures (Environment
;; is Arc<EnvCell> with no interior mutability; lookup returns
;; Value.clone(); no `set!`). The semantic equivalent is values-up:
;; the GATE STATE is just an `:wat::time::Instant`, and the caller
;; threads it through their loop, replacing it with the new instant
;; whenever the gate fires.
;;
;; Usage shape:
;;
;;   ;; Initialize at loop start.
;;   ((gate :wat::time::Instant) (:trading::log::rate-gate-init))
;;
;;   ;; Each loop iteration:
;;   ((tick :(wat::time::Instant,bool))
;;    (:trading::log::tick-gate gate 5000))
;;   ((gate' :wat::time::Instant) (:wat::core::first tick))
;;   ((fired? :bool) (:wat::core::second tick))
;;   ((_ :())
;;    (:wat::core::if fired?
;;                    -> :()
;;      ;; Emit telemetry (build LogEntry::Telemetry batch + flush via Service)
;;      ...
;;      ()))
;;   ;; Recurse with `gate'` as the new gate.
;;   (recurse ... gate' ...)
;;
;; Default interval per archive: 5000 ms. Caller picks per consumer.

;; Initial gate state — `now()` at construction. Mirror of the
;; archive's `Mutex::new(Instant::now())` seed: first `tick-gate`
;; call returns `false` until `interval-ms` elapses.
(:wat::core::define
  (:trading::log::rate-gate-init -> :wat::time::Instant)
  (:wat::time::now))


;; Tick the gate. Pure values-up:
;;   - inputs: current gate state + interval
;;   - output: (new-gate-state, fired?)
;;
;; If `interval-ms` has elapsed since `last`, returns
;; `(now, true)` and the caller persists `now` as the new state.
;; Otherwise returns `(last, false)` — caller persists `last`
;; unchanged.
(:wat::core::define
  (:trading::log::tick-gate
    (last :wat::time::Instant)
    (interval-ms :i64)
    -> :(wat::time::Instant,bool))
  (:wat::core::let*
    (((now :wat::time::Instant) (:wat::time::now))
     ((elapsed :i64)
      (:wat::core::- (:wat::time::epoch-millis now)
                     (:wat::time::epoch-millis last))))
    (:wat::core::if (:wat::core::>= elapsed interval-ms)
                    -> :(wat::time::Instant,bool)
      (:wat::core::tuple now true)
      (:wat::core::tuple last false))))
