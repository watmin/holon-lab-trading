;; wat-tests-integ/experiment/015-causal-time/explore-causal-time.wat
;;
;; Causal-time verifier — proof 010.
;;
;; A drop-in pure verification function for existing systems.
;; Takes (receipt, expected-form, current-time, freshness-policy)
;; and returns a verdict the caller can act on. Detects time-claim
;; lies via causal-anchor consistency. No external services, no
;; trusted authority, no new infrastructure.
;;
;; ─── The architecture, said plainly ──────────────────────────
;;
;;     caller provides:    receipt + expected-form + cited
;;                         anchors + reference-data + own clock +
;;                         freshness policy
;;     substrate computes: is the time-claim internally
;;                         consistent with the cited anchors?
;;     output:             sound | unsound(reason) | unanchored
;;
;; The substrate is a pure function. The caller is responsible
;; for sourcing trustworthy reference data (Bitcoin block hashes,
;; DRAND rounds, git commit hashes — any publicly verifiable
;; chain). The substrate runs the lie-detection function on
;; whatever the caller supplies.
;;
;; This is the same pattern as every cryptographic verifier:
;; PGP doesn't fetch your public key, you supply it; Bitcoin
;; nodes don't fetch external truth, they verify what's submitted
;; against rules they all run identically. The substrate inherits
;; the pattern.
;;
;; ─── What lies this catches ──────────────────────────────────
;;
;; T1  Honest path — claim time falls in the verifiable window
;;     [latest_anchor_time, now]. Approve.
;; T2  Backdating beyond cited anchor — claim time predates
;;     the receipt's own cited evidence. Internal contradiction;
;;     reject.
;; T3  Forward-dating — claim time exceeds the verifier's
;;     current clock. Future-claim impossibility; reject.
;; T4  Stale-anchor under freshness policy — receipt's latest
;;     anchor is older than the policy permits. The receipt
;;     COULD have been created at any time after the stale
;;     anchor; freshness policy collapses that window. Reject.
;; T5  No causal anchors — receipt has no time evidence at all.
;;     Return UNANCHORED so the caller decides whether to accept
;;     based on their own policy (some apps don't require time
;;     evidence; others reject anything unanchored).
;; T6  Multi-anchor receipt — uses MAX(anchor times) as the
;;     lower bound. A receipt with multiple anchors is bounded
;;     by its newest anchor; tightening the window.
;;
;; ─── What it does NOT catch ──────────────────────────────────
;;
;; - Backdating to a time AFTER the latest anchor but before
;;   actual creation. The caller must enforce a freshness policy
;;   to bound this gap. With a 30-second freshness policy and
;;   DRAND (30-second rounds), the time-claim window collapses
;;   to ~1 minute.
;; - The trustworthiness of the reference data itself. The
;;   caller is accountable for sourcing it from a chain whose
;;   consensus model they trust.
;;
;; ─── The function signature ──────────────────────────────────
;;
;;     verify-time-claim
;;       (receipt          :TimedReceipt)
;;       (expected-form    :HolonAST)
;;       (now              :wat::core::i64)            ; epoch seconds
;;       (max-anchor-age   :wat::core::i64)            ; freshness policy; 0 disables
;;       -> :TimeVerdict
;;
;; A consumer's HTTP handler / smart-contract / CI gate / audit
;; tool calls this function with their own inputs and routes on
;; the verdict. Runs in the caller's process.

(:wat::test::make-deftest :deftest
  (;; ─── Receipt + binding (from proof 005) ──────────────────
   (:wat::core::struct :exp::Receipt
     (bytes :wat::core::Bytes)
     (form :wat::holon::HolonAST))

   (:wat::core::define
     (:exp::issue (form :wat::holon::HolonAST) -> :exp::Receipt)
     (:wat::core::let*
       (((v :wat::holon::Vector) (:wat::holon::encode form))
        ((bytes :wat::core::Bytes) (:wat::holon::vector-bytes v)))
       (:exp::Receipt/new bytes form)))

   (:wat::core::define
     (:exp::verify-binding (r :exp::Receipt)
                           (candidate :wat::holon::HolonAST)
                           -> :wat::core::bool)
     (:wat::core::match
       (:wat::holon::bytes-vector (:exp::Receipt/bytes r))
       -> :wat::core::bool
       ((Some v) (:wat::holon::coincident? candidate v))
       (:None false)))


   ;; ─── CausalAnchor — public reference data ────────────────
   ;;
   ;; A reference to a publicly verifiable event. The caller
   ;; supplies the publication-time after looking up the chain;
   ;; the substrate uses it for consistency checks.
   ;;
   ;; Examples in real deployment:
   ;;   - Bitcoin block: chain="bitcoin", id=block-hash, publication-time=mining-time
   ;;   - DRAND round: chain="drand", id=round-number, publication-time=round-time
   ;;   - Git commit: chain="git", id=commit-hash, publication-time=commit-time
   ;;   - NPM publish: chain="npm-tx", id=publish-id, publication-time=publish-time
   (:wat::core::struct :exp::CausalAnchor
     (chain :wat::core::String)
     (id :wat::core::String)
     (publication-time :wat::core::i64))


   ;; ─── TimedReceipt — Receipt + time claim + cited anchors ──
   ;;
   ;; The anchors Vec mirrors what's IN the form F (so the
   ;; receipt's bytes commit to them). The struct fields are
   ;; verifier-convenience; binding ensures the form matches.
   (:wat::core::struct :exp::TimedReceipt
     (bytes :wat::core::Bytes)
     (form :wat::holon::HolonAST)
     (claim-time :wat::core::i64)
     (anchors :Vec<exp::CausalAnchor>))


   ;; ─── TimeVerdict — what the verifier returns ─────────────
   (:wat::core::struct :exp::TimeVerdict
     (binding-sound :wat::core::bool)
     (claim-sound :wat::core::bool)
     (decision :wat::core::String)    ;; "sound" | "unsound" | "unanchored" | "binding-failed"
     (reason :wat::core::String))     ;; human-readable explanation


   ;; ─── Latest-anchor-time helper (max over cited anchors) ──
   (:wat::core::define
     (:exp::latest-anchor-time
       (anchors :Vec<exp::CausalAnchor>)
       -> :wat::core::i64)
     (:wat::core::foldl anchors 0
       (:wat::core::lambda ((acc :wat::core::i64) (a :exp::CausalAnchor) -> :wat::core::i64)
         (:wat::core::if (:wat::core::> (:exp::CausalAnchor/publication-time a) acc)
           -> :wat::core::i64
           (:exp::CausalAnchor/publication-time a)
           acc))))


   ;; ─── verify-time-claim — the function the caller calls ──
   ;;
   ;; Pure. Deterministic. No I/O. Any caller with the same
   ;; inputs gets the same verdict.
   ;;
   ;; max-anchor-age: 0 disables the freshness policy.
   ;; Otherwise, the latest cited anchor must be no older
   ;; than max-anchor-age seconds relative to now.
   (:wat::core::define
     (:exp::verify-time-claim
       (tr :exp::TimedReceipt)
       (expected-form :wat::holon::HolonAST)
       (now :wat::core::i64)
       (max-anchor-age :wat::core::i64)
       -> :exp::TimeVerdict)
     (:wat::core::let*
       (((r :exp::Receipt)
         (:exp::Receipt/new (:exp::TimedReceipt/bytes tr)
                            (:exp::TimedReceipt/form tr)))
        ((binding-ok :wat::core::bool) (:exp::verify-binding r expected-form))
        ((anchors :Vec<exp::CausalAnchor>) (:exp::TimedReceipt/anchors tr))
        ((claim-time :wat::core::i64) (:exp::TimedReceipt/claim-time tr))
        ((no-anchors :wat::core::bool) (:wat::core::= (:wat::core::length anchors) 0))
        ((latest-time :wat::core::i64) (:exp::latest-anchor-time anchors))
        ((claim-in-future :wat::core::bool) (:wat::core::> claim-time now))
        ((claim-predates-anchor :wat::core::bool)
          (:wat::core::and (:wat::core::not no-anchors)
                            (:wat::core::< claim-time latest-time)))
        ((anchor-stale :wat::core::bool)
          (:wat::core::and (:wat::core::and (:wat::core::not no-anchors)
                                              (:wat::core::> max-anchor-age 0))
                            (:wat::core::> (:wat::core::- now latest-time) max-anchor-age)))

        ((decision :wat::core::String)
          (:wat::core::cond -> :wat::core::String
            ((:wat::core::not binding-ok) "binding-failed")
            (no-anchors "unanchored")
            (claim-in-future "unsound")
            (claim-predates-anchor "unsound")
            (anchor-stale "unsound")
            (:else "sound")))

        ((reason :wat::core::String)
          (:wat::core::cond -> :wat::core::String
            ((:wat::core::not binding-ok) "form does not encode to bytes")
            (no-anchors "no causal anchors cited")
            (claim-in-future "claim time exceeds verifier's current clock")
            (claim-predates-anchor "claim time predates latest cited anchor")
            (anchor-stale "latest cited anchor exceeds freshness policy window")
            (:else "claim is consistent with cited anchors and verifier clock")))

        ((claim-sound :wat::core::bool)
          (:wat::core::and (:wat::core::not no-anchors)
            (:wat::core::and (:wat::core::not claim-in-future)
              (:wat::core::and (:wat::core::not claim-predates-anchor)
                                (:wat::core::not anchor-stale))))))
       (:exp::TimeVerdict/new binding-ok claim-sound decision reason)))))


;; ════════════════════════════════════════════════════════════════
;;  T1 — Honest path: claim time falls in [anchor_time, now]
;; ════════════════════════════════════════════════════════════════
;;
;; Issuer creates Receipt at 2026-04-15. Cites Bitcoin block 873541
;; (mined 2026-04-01). Claim time: 2026-04-15. Verifier checks at
;; 2026-04-26 with no freshness policy. The claim is internally
;; consistent (after the anchor, before now). Approve.
;;
;; This is what a normal honest receipt looks like in production.

(:deftest :exp::t1-honest-path
  (:wat::core::let*
    (;; The form F includes the anchor as a sub-form so V_bytes
     ;; commits to it. The struct's anchors field echoes for
     ;; verifier convenience.
     ((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:audit/event
          (action "deploy")
          (target "production")
          (claim-time 1713139200)   ;; 2026-04-15 00:00:00 UTC
          (anchor (chain "bitcoin")
                  (id "0000abc111222333")
                  (height 873541)
                  (publication-time 1711929600))))))   ;; 2026-04-01 00:00:00 UTC

     ((receipt :exp::Receipt) (:exp::issue form))
     ((anchors :Vec<exp::CausalAnchor>)
      (:wat::core::vec :exp::CausalAnchor
        (:exp::CausalAnchor/new "bitcoin" "0000abc111222333" 1711929600)))

     ((tr :exp::TimedReceipt)
      (:exp::TimedReceipt/new
        (:exp::Receipt/bytes receipt)
        (:exp::Receipt/form receipt)
        1713139200    ;; claim time = 2026-04-15
        anchors))

     ;; Verifier's clock: 2026-04-26. No freshness policy (0).
     ((verdict :exp::TimeVerdict)
      (:exp::verify-time-claim tr form 1714089600 0))

     ((_b :()) (:wat::test::assert-eq (:exp::TimeVerdict/binding-sound verdict) true))
     ((_c :()) (:wat::test::assert-eq (:exp::TimeVerdict/claim-sound verdict) true)))
    (:wat::test::assert-eq (:exp::TimeVerdict/decision verdict) "sound")))


;; ════════════════════════════════════════════════════════════════
;;  T2 — Backdating caught: claim predates cited anchor
;; ════════════════════════════════════════════════════════════════
;;
;; Adversary fabricates a Receipt at 2026-04-26 and tries to claim
;; it was created 2025-12-01. Includes Bitcoin block 873541 as
;; anchor (mined 2026-04-01). Verifier checks: claim-time
;; 2025-12-01 < anchor-publication-time 2026-04-01 — IMPOSSIBLE,
;; the receipt cites a hash that didn't exist at the claimed time.
;; Reject as unsound with reason "claim predates cited anchor."
;;
;; This is the canonical lie-detection case. The receipt
;; INTERNALLY CONTRADICTS itself. The substrate sees both the
;; claim and the cited evidence; the math closes the case.

(:deftest :exp::t2-backdating-caught
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:audit/event
          (action "approve-large-trade")
          (claim-time 1701388800)     ;; 2025-12-01 — backdated
          (anchor (chain "bitcoin")
                  (id "0000abc111222333")
                  (height 873541)
                  (publication-time 1711929600))))))   ;; 2026-04-01

     ((receipt :exp::Receipt) (:exp::issue form))
     ((anchors :Vec<exp::CausalAnchor>)
      (:wat::core::vec :exp::CausalAnchor
        (:exp::CausalAnchor/new "bitcoin" "0000abc111222333" 1711929600)))

     ((tr :exp::TimedReceipt)
      (:exp::TimedReceipt/new
        (:exp::Receipt/bytes receipt)
        (:exp::Receipt/form receipt)
        1701388800    ;; claim = 2025-12-01 (predates anchor)
        anchors))

     ((verdict :exp::TimeVerdict)
      (:exp::verify-time-claim tr form 1714089600 0))

     ;; Binding is sound — the receipt is internally consistent
     ;; in the binding sense (form matches bytes). The lie is
     ;; that the form's claim contradicts the form's anchor.
     ((_b :()) (:wat::test::assert-eq (:exp::TimeVerdict/binding-sound verdict) true))
     ((_c :()) (:wat::test::assert-eq (:exp::TimeVerdict/claim-sound verdict) false))
     ((_d :()) (:wat::test::assert-eq (:exp::TimeVerdict/decision verdict) "unsound")))
    (:wat::test::assert-eq (:exp::TimeVerdict/reason verdict)
                            "claim time predates latest cited anchor")))


;; ════════════════════════════════════════════════════════════════
;;  T3 — Forward-dating caught: claim exceeds verifier's clock
;; ════════════════════════════════════════════════════════════════
;;
;; Receipt claims to be created in 2030. Verifier's clock is
;; 2026-04-26. Receipts from the future are by definition
;; impossible from the verifier's frame. Reject.

(:deftest :exp::t3-forward-dating-caught
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:audit/event
          (action "preemptive-claim")
          (claim-time 1893456000)     ;; 2030-01-01 (future from verifier)
          (anchor (chain "bitcoin") (id "0000abc") (publication-time 1711929600))))))

     ((receipt :exp::Receipt) (:exp::issue form))
     ((anchors :Vec<exp::CausalAnchor>)
      (:wat::core::vec :exp::CausalAnchor
        (:exp::CausalAnchor/new "bitcoin" "0000abc" 1711929600)))

     ((tr :exp::TimedReceipt)
      (:exp::TimedReceipt/new
        (:exp::Receipt/bytes receipt)
        (:exp::Receipt/form receipt)
        1893456000    ;; 2030 — future from verifier
        anchors))

     ;; Verifier at 2026-04-26.
     ((verdict :exp::TimeVerdict)
      (:exp::verify-time-claim tr form 1714089600 0))

     ((_d :()) (:wat::test::assert-eq (:exp::TimeVerdict/decision verdict) "unsound")))
    (:wat::test::assert-eq (:exp::TimeVerdict/reason verdict)
                            "claim time exceeds verifier's current clock")))


;; ════════════════════════════════════════════════════════════════
;;  T4 — Stale anchor caught under freshness policy
;; ════════════════════════════════════════════════════════════════
;;
;; Receipt cites Bitcoin block 800000 (mined 2025-01-01 — over a
;; year before the verifier's clock of 2026-04-26). Without a
;; freshness policy, this would be sound (claim is after the
;; anchor, before now). With a 1-hour freshness policy (3600s),
;; the anchor is over a year old and violates the policy.
;;
;; This collapses the time-claim window to whatever the policy
;; permits. With DRAND (30-second rounds) and a 60-second policy,
;; the window is ≤ 1 minute. With Bitcoin (~10-minute blocks)
;; and a 1-hour policy, the window is ≤ 1 hour.
;;
;; The freshness policy is the caller's domain decision. The
;; substrate enforces whatever the caller specifies.

(:deftest :exp::t4-stale-anchor-policy
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:audit/event
          (action "delayed-claim")
          (claim-time 1713139200)     ;; 2026-04-15
          (anchor (chain "bitcoin")
                  (id "0000aaa")
                  (height 800000)
                  (publication-time 1704067200))))))   ;; 2025-01-01 (year-old)

     ((receipt :exp::Receipt) (:exp::issue form))
     ((anchors :Vec<exp::CausalAnchor>)
      (:wat::core::vec :exp::CausalAnchor
        (:exp::CausalAnchor/new "bitcoin" "0000aaa" 1704067200)))

     ((tr :exp::TimedReceipt)
      (:exp::TimedReceipt/new
        (:exp::Receipt/bytes receipt)
        (:exp::Receipt/form receipt)
        1713139200    ;; claim = 2026-04-15
        anchors))

     ;; Verifier at 2026-04-26 with 1-hour freshness policy.
     ((verdict :exp::TimeVerdict)
      (:exp::verify-time-claim tr form 1714089600 3600))

     ((_d :()) (:wat::test::assert-eq (:exp::TimeVerdict/decision verdict) "unsound")))
    (:wat::test::assert-eq (:exp::TimeVerdict/reason verdict)
                            "latest cited anchor exceeds freshness policy window")))


;; ════════════════════════════════════════════════════════════════
;;  T5 — Unanchored: receipt has no causal anchors
;; ════════════════════════════════════════════════════════════════
;;
;; Receipt with a claim time but NO cited anchors. The substrate
;; cannot detect lies — there's nothing to compare against. Returns
;; UNANCHORED (a distinct verdict from "unsound") so the caller's
;; policy decides:
;;
;;   - Some apps accept unanchored receipts (low-stakes audit logs)
;;   - Some apps reject (anything financial / regulated)
;;   - Some apps escalate to a human reviewer
;;
;; The substrate is honest about what it doesn't know.

(:deftest :exp::t5-unanchored
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:audit/event
          (action "no-anchor-claim")
          (claim-time 1713139200)))))

     ((receipt :exp::Receipt) (:exp::issue form))
     ((anchors :Vec<exp::CausalAnchor>) (:wat::core::vec :exp::CausalAnchor))

     ((tr :exp::TimedReceipt)
      (:exp::TimedReceipt/new
        (:exp::Receipt/bytes receipt)
        (:exp::Receipt/form receipt)
        1713139200
        anchors))

     ((verdict :exp::TimeVerdict)
      (:exp::verify-time-claim tr form 1714089600 0))

     ;; Binding sound (form encodes correctly).
     ((_b :()) (:wat::test::assert-eq (:exp::TimeVerdict/binding-sound verdict) true))
     ;; Claim NOT sound — there's no evidence to verify.
     ((_c :()) (:wat::test::assert-eq (:exp::TimeVerdict/claim-sound verdict) false))
     ;; Decision is "unanchored" — distinct from "unsound" so
     ;; the caller knows whether it's a lie or just no evidence.
     ((_d :()) (:wat::test::assert-eq (:exp::TimeVerdict/decision verdict) "unanchored")))
    (:wat::test::assert-eq (:exp::TimeVerdict/reason verdict)
                            "no causal anchors cited")))


;; ════════════════════════════════════════════════════════════════
;;  T6 — Multi-anchor: tightest window via MAX(anchor_times)
;; ════════════════════════════════════════════════════════════════
;;
;; Receipt cites TWO anchors: Bitcoin block 873541 (2026-04-01)
;; and DRAND round 5000 (2026-04-12). The substrate uses the
;; LATER anchor (2026-04-12) as the lower bound for the claim
;; time. Multiple anchors tighten the window.
;;
;; Practical implication: callers can include multiple anchors
;; to pin their receipts more precisely. A receipt anchored to
;; (block hash + DRAND round) has a tighter time window than one
;; anchored to just the older of the two. Triangulation across
;; chains.

(:deftest :exp::t6-multi-anchor-tightest-window
  (:wat::core::let*
    (((form :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:audit/event
          (action "well-anchored-claim")
          (claim-time 1713139200)     ;; 2026-04-15
          (anchor-bitcoin (chain "bitcoin")
                          (id "0000abc")
                          (publication-time 1711929600))   ;; 2026-04-01
          (anchor-drand (chain "drand")
                        (id "round-5000")
                        (publication-time 1712880000))))))   ;; 2026-04-12

     ((receipt :exp::Receipt) (:exp::issue form))
     ((anchors :Vec<exp::CausalAnchor>)
      (:wat::core::vec :exp::CausalAnchor
        (:exp::CausalAnchor/new "bitcoin" "0000abc" 1711929600)
        (:exp::CausalAnchor/new "drand" "round-5000" 1712880000)))

     ((tr :exp::TimedReceipt)
      (:exp::TimedReceipt/new
        (:exp::Receipt/bytes receipt)
        (:exp::Receipt/form receipt)
        1713139200    ;; claim = 2026-04-15 (after both anchors)
        anchors))

     ;; Verifier at 2026-04-26. No freshness policy.
     ((verdict :exp::TimeVerdict)
      (:exp::verify-time-claim tr form 1714089600 0))

     ((_b :()) (:wat::test::assert-eq (:exp::TimeVerdict/binding-sound verdict) true))
     ((_c :()) (:wat::test::assert-eq (:exp::TimeVerdict/claim-sound verdict) true)))
    ;; The latest-anchor-time helper picked the DRAND round
    ;; (later than the Bitcoin block) as the lower bound. The
    ;; claim cleared it; the verdict is sound.
    (:wat::test::assert-eq (:exp::TimeVerdict/decision verdict) "sound")))
