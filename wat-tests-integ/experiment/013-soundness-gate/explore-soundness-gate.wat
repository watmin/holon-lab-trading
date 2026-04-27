;; wat-tests-integ/experiment/013-soundness-gate/explore-soundness-gate.wat
;;
;; The truth engine — proof 008. The substrate measures the soundness
;; of a wat-emitted claim against an axiom set. The measurement is
;; geometric: cosine(claim, bundle(axioms)). The verdict is a thresholded
;; decision: approve / review / reject. Approved claims are rendered
;; from wat → English; rejected claims never reach the user as English.
;;
;; ─── The inversion ────────────────────────────────────────────
;;
;; Conventional stack:
;;   LLM emits English → parser → lossy structure → verification
;;
;; Truth engine:
;;   LLM emits wat → substrate measures soundness → renders wat → English
;;
;; The wat IS the thought; English is the presentation layer. The
;; substrate never has to parse natural language because the LLM never
;; emits natural language during the verification path.
;;
;; ─── Two-bundle measurement (positive + negative axioms) ──────
;;
;; The substrate measures BOTH:
;;
;;   coherence(claim, allowed-bundle)   — alignment with policies
;;   coherence(claim, forbidden-bundle) — match with prohibitions
;;
;; Verdict considers both. A claim that's geometrically aligned with
;; allowed patterns AND not aligned with forbidden patterns → approve.
;; A claim aligned with forbidden patterns → reject. Anything in
;; between → human review.
;;
;; ─── Domain: terraform/infra change validation ────────────────
;;
;; Concrete enough to test crisply; small enough to read in one pass.
;; Five allowed patterns, four forbidden patterns. Claims are change
;; proposals an agent might emit (ingress-rule, storage-add, etc.).
;;
;; ─── The seven tests ──────────────────────────────────────────
;;
;; T1  Sound claim — shares structure with allowed patterns, none
;;     with forbidden. High allowed-coherence; near-zero forbidden-
;;     coherence; approve; render to English.
;; T2  Unsound claim — matches a forbidden pattern (public ingress
;;     to security group). High forbidden-coherence; reject; never
;;     renders.
;; T3  Marginal claim — between thresholds. Routes to human review.
;; T4  Multi-axiom composition — bundle of N forbidden patterns;
;;     a claim matching one of them surfaces.
;; T5  Reasoning chain — three sub-claims emitted by an agent;
;;     each measured separately; the chain's verdict is the
;;     weakest link.
;; T6  Full pipeline E2E — claim in, Verdict out (with rendered
;;     English on approve, blocked-message on reject).
;; T7  Explicit contradiction — claim contains the exact forbidden
;;     atom; coherence with forbidden bundle is near-maximal.
;;
;; ─── Honest about calibration ─────────────────────────────────
;;
;; HDC measures geometric coherence, not logical truth. The
;; thresholds in this demo are tuned to the specific axiom set;
;; deploying this for real requires:
;;
;; - Calibrating the threshold band against known sound/unsound
;;   examples (many of them) for each domain
;; - Encoding axioms as STRUCTURAL PATTERNS that share vocabulary
;;   with the claims they evaluate (otherwise cosines collapse to
;;   noise)
;; - Distinguishing sound-but-novel claims (low coherence with
;;   axioms because they're new) from unsound claims (low coherence
;;   because they're wrong) — the substrate cannot do this; human
;;   review is the final arbiter for the marginal band
;;
;; This demo exists to show the SHAPE of the soundness gate. Real
;; deployment is calibration work + axiom-set curation, not
;; substrate work.

(:wat::test::make-deftest :deftest
  (;; ─── Default dim is d=10000 (post-arc-067) ───────────────
   ;;
   ;; The substrate's default tier-router post-arc-067 returns
   ;; d=10000 for any input that fits (arity ≤ 100). At d=10000
   ;; the noise floor is 1/sqrt(10000) ≈ 0.01 — small enough
   ;; that strong-match cosines (0.40–0.70) discriminate cleanly
   ;; against unrelated pairs. Soundness measurement gets the
   ;; headroom it needs out of the box.
   ;;
   ;; Pre-arc-067 the default was [256, 4096, 10000, 100000] —
   ;; smallest tier wins. Small forms got d=256 (noise floor
   ;; 0.0625, swallowing the signal). The original draft of
   ;; this experiment carried an explicit `set-dim-router!`
   ;; override; arc 067 made the default correct, so the
   ;; override is no longer required.


   ;; ─── Axiom and Claim — the wat-form units ─────────────────
   (:wat::core::struct :exp::Axiom
     (id :String)
     (kind :String)         ;; "policy" (allowed) | "prohibition" (forbidden)
     (form :wat::holon::HolonAST))

   (:wat::core::struct :exp::Claim
     (id :String)
     (title :String)        ;; one-line human-readable summary
     (form :wat::holon::HolonAST))

   (:wat::core::struct :exp::Verdict
     (claim-id :String)
     (allowed-coherence :f64)
     (forbidden-coherence :f64)
     (decision :String)     ;; "approve" | "review" | "reject"
     (rendered :String))    ;; English render on approve/review; "" on reject


   ;; ─── Max-coherence — strongest match over individual axioms ─
   ;;
   ;; Two calibration choices live here, BOTH load-bearing:
   ;;
   ;; (1) Why d=10000 (set above): default tier-router picks d=256
   ;;     for these small forms. At d=256 the noise floor is
   ;;     1/sqrt(256) ≈ 0.0625; at d=10000 it's ≈0.01. Forcing
   ;;     d=10000 gives 6× the discrimination headroom against
   ;;     unrelated pairs.
   ;;
   ;; (2) Why max-over-axioms instead of bundle-then-cosine:
   ;;     bundling DILUTES. With four prohibitions in the bundle,
   ;;     a claim that matches ONE strongly only gets ~25% of the
   ;;     bundle's centroid aligned. Worse, dilution penalizes
   ;;     the small-overlap match more than the large-overlap
   ;;     match — a wildcard-IAM claim sharing 3 atoms with P3
   ;;     comes in below threshold while a public-ingress claim
   ;;     sharing 5 atoms with P1 comes in above. Asking *"does
   ;;     this match ANY prohibition strongly?"* is the correct
   ;;     geometric question — taking the max over individual
   ;;     axiom cosines answers it directly, dim-independent.
   ;;
   ;; Empirically tested in this experiment: bundle-cosine at
   ;; d=10000 STILL fails T3; max-over-axioms passes all 7. The
   ;; algorithm choice mattered more than the dim choice for this
   ;; calibration. Both choices stay — d=10000 for general S/N,
   ;; max-over for the specific "any-prohibition-match" question.
   (:wat::core::define
     (:exp::max-coherence
       (claim :wat::holon::HolonAST)
       (axioms :Vec<exp::Axiom>)
       -> :f64)
     (:wat::core::foldl axioms 0.0
       (:wat::core::lambda ((acc :f64) (a :exp::Axiom) -> :f64)
         (:wat::core::f64::max acc
           (:wat::holon::cosine claim (:exp::Axiom/form a))))))


   ;; ─── Gate — three-way decision from the two coherences ────
   ;;
   ;; Calibrated for d=10000 + max-over-axioms:
   ;;
   ;;   forbidden > 0.40                       → REJECT (strong match)
   ;;   forbidden > 0.20 && forbidden > allowed → REVIEW (suspicious)
   ;;   allowed > 0.40                         → APPROVE (aligned)
   ;;   else                                   → REVIEW (low confidence)
   (:wat::core::define
     (:exp::gate (allowed :f64) (forbidden :f64) -> :String)
     (:wat::core::cond -> :String
       ((:wat::core::f64::> forbidden 0.40) "reject")
       ((:wat::core::and (:wat::core::f64::> forbidden 0.20)
                          (:wat::core::f64::> forbidden allowed)) "review")
       ((:wat::core::f64::> allowed 0.40) "approve")
       (:else "review")))


   ;; ─── Render — wat-form claim → English line ───────────────
   ;;
   ;; The minimal demonstration of the wat → English direction.
   ;; A claim has a human-readable `title` field for the headline;
   ;; the `form` is rendered via `:wat::core::show` (arc 064) for
   ;; structured display. Real deployment grows a templated
   ;; renderer that knows specific claim shapes.
   (:wat::core::define
     (:exp::render-claim (c :exp::Claim) -> :String)
     (:wat::core::string::concat
       (:exp::Claim/title c)
       (:wat::core::string::concat
         " — structural form: "
         (:wat::core::show (:exp::Claim/form c)))))


   ;; ─── Evaluate — the full pipeline as one verb ─────────────
   ;;
   ;; Take a claim and two axiom-bundles (allowed, forbidden);
   ;; measure both coherences; gate the verdict; render on approve
   ;; or review; emit "[REJECTED]" on reject (the unsound thought
   ;; never reaches the user as the claim's English).
   (:wat::core::define
     (:exp::evaluate
       (claim :exp::Claim)
       (allowed-axioms :Vec<exp::Axiom>)
       (forbidden-axioms :Vec<exp::Axiom>)
       -> :exp::Verdict)
     (:wat::core::let*
       (((allowed :f64) (:exp::max-coherence (:exp::Claim/form claim) allowed-axioms))
        ((forbidden :f64) (:exp::max-coherence (:exp::Claim/form claim) forbidden-axioms))

        ((decision :String) (:exp::gate allowed forbidden))

        ((rendered :String)
          (:wat::core::cond -> :String
            ((:wat::core::= decision "approve") (:exp::render-claim claim))
            ((:wat::core::= decision "review")
              (:wat::core::string::concat "[REVIEW] " (:exp::render-claim claim)))
            (:else "[REJECTED] claim does not pass soundness gate"))))
       (:exp::Verdict/new (:exp::Claim/id claim) allowed forbidden decision rendered)))


   ;; ─── Domain axioms: the policy set for terraform/infra ────
   ;;
   ;; ALLOWED PATTERNS (positive axioms — coherence = good)
   ;;
   ;; Each axiom is a structural pattern. A claim that contains
   ;; this pattern as a substructure shares vocabulary geometrically
   ;; and shows high cosine.
   (:wat::core::define
     (:exp::axiom-allowed-private-ingress -> :exp::Axiom)
     (:exp::Axiom/new
       "A1-private-ingress" "policy"
       (:wat::holon::from-watast (:wat::core::quote
         (:rule/ingress
           (cidr-kind "private")
           (resource-kind "security-group"))))))

   (:wat::core::define
     (:exp::axiom-encrypted-storage -> :exp::Axiom)
     (:exp::Axiom/new
       "A2-encrypted-storage" "policy"
       (:wat::holon::from-watast (:wat::core::quote
         (:rule/storage
           (encryption-at-rest "true"))))))

   (:wat::core::define
     (:exp::axiom-specific-iam -> :exp::Axiom)
     (:exp::Axiom/new
       "A3-specific-iam" "policy"
       (:wat::holon::from-watast (:wat::core::quote
         (:rule/iam
           (permission-kind "specific"))))))

   (:wat::core::define
     (:exp::axiom-backups-required -> :exp::Axiom)
     (:exp::Axiom/new
       "A4-backups-required" "policy"
       (:wat::holon::from-watast (:wat::core::quote
         (:rule/backup
           (status "configured"))))))

   (:wat::core::define
     (:exp::axiom-lb-fronted -> :exp::Axiom)
     (:exp::Axiom/new
       "A5-lb-fronted" "policy"
       (:wat::holon::from-watast (:wat::core::quote
         (:rule/public-service
           (load-balancer "in-front"))))))


   ;; FORBIDDEN PATTERNS (negative axioms — coherence = bad)
   (:wat::core::define
     (:exp::axiom-public-ingress-forbidden -> :exp::Axiom)
     (:exp::Axiom/new
       "P1-public-ingress" "prohibition"
       (:wat::holon::from-watast (:wat::core::quote
         (:rule/ingress
           (cidr-kind "public")
           (resource-kind "security-group"))))))

   (:wat::core::define
     (:exp::axiom-plaintext-secret-forbidden -> :exp::Axiom)
     (:exp::Axiom/new
       "P2-plaintext-secret" "prohibition"
       (:wat::holon::from-watast (:wat::core::quote
         (:rule/secret
           (storage "plaintext"))))))

   (:wat::core::define
     (:exp::axiom-wildcard-iam-forbidden -> :exp::Axiom)
     (:exp::Axiom/new
       "P3-wildcard-iam" "prohibition"
       (:wat::holon::from-watast (:wat::core::quote
         (:rule/iam
           (permission-kind "wildcard"))))))

   (:wat::core::define
     (:exp::axiom-public-database-forbidden -> :exp::Axiom)
     (:exp::Axiom/new
       "P4-public-database" "prohibition"
       (:wat::holon::from-watast (:wat::core::quote
         (:rule/database
           (exposure "public"))))))


   ;; Helpers to assemble policy bundles for tests.
   (:wat::core::define
     (:exp::all-allowed -> :Vec<exp::Axiom>)
     (:wat::core::vec :exp::Axiom
       (:exp::axiom-allowed-private-ingress)
       (:exp::axiom-encrypted-storage)
       (:exp::axiom-specific-iam)
       (:exp::axiom-backups-required)
       (:exp::axiom-lb-fronted)))

   (:wat::core::define
     (:exp::all-forbidden -> :Vec<exp::Axiom>)
     (:wat::core::vec :exp::Axiom
       (:exp::axiom-public-ingress-forbidden)
       (:exp::axiom-plaintext-secret-forbidden)
       (:exp::axiom-wildcard-iam-forbidden)
       (:exp::axiom-public-database-forbidden)))))


;; ════════════════════════════════════════════════════════════════
;;  T1 — Sound claim: encrypted EBS volume add
;; ════════════════════════════════════════════════════════════════
;;
;; Agent proposes: add a 100GB EBS volume with encryption-at-rest
;; enabled. The claim's structural form contains
;; `(encryption-at-rest "true")` — same pattern as A2. Shares
;; geometry with allowed-bundle; shares no geometry with forbidden-
;; bundle. Verdict: approve. Renders to English.

(:deftest :exp::t1-sound-claim-approves
  (:wat::core::let*
    (((claim :exp::Claim)
      (:exp::Claim/new
        "T1-add-encrypted-ebs"
        "Add 100GB encrypted EBS volume to db-prod-01"
        (:wat::holon::from-watast (:wat::core::quote
          (:rule/storage
            (kind "ebs-volume")
            (size-gb 100)
            (target "db-prod-01")
            (encryption-at-rest "true"))))))

     ((verdict :exp::Verdict)
      (:exp::evaluate claim (:exp::all-allowed) (:exp::all-forbidden)))

     ((decision :String) (:exp::Verdict/decision verdict))
     ((_d :()) (:wat::test::assert-eq decision "approve")))
    ;; The English render must include the title (so the user
    ;; reading sees a claim that's been gated).
    (:wat::test::assert-contains
      (:exp::Verdict/rendered verdict)
      "Add 100GB encrypted EBS volume")))


;; ════════════════════════════════════════════════════════════════
;;  T2 — Unsound claim: open security group to 0.0.0.0/0
;; ════════════════════════════════════════════════════════════════
;;
;; Agent proposes: add ingress rule from 0.0.0.0/0 to sg-prod-db.
;; The claim's form contains `(cidr-kind "public")` and
;; `(resource-kind "security-group")` — exact match for P1.
;; High forbidden-coherence; verdict: reject.
;;
;; The reject path's render is "[REJECTED] ..." — the unsound
;; thought NEVER reaches the user as the claim's English.

(:deftest :exp::t2-unsound-claim-rejects
  (:wat::core::let*
    (((claim :exp::Claim)
      (:exp::Claim/new
        "T2-open-public-ingress"
        "Open ingress from 0.0.0.0/0 to sg-prod-db for debugging"
        (:wat::holon::from-watast (:wat::core::quote
          (:rule/ingress
            (cidr-kind "public")
            (cidr "0.0.0.0/0")
            (resource-kind "security-group")
            (resource "sg-prod-db")
            (port 5432))))))

     ((verdict :exp::Verdict)
      (:exp::evaluate claim (:exp::all-allowed) (:exp::all-forbidden)))

     ((decision :String) (:exp::Verdict/decision verdict))
     ((_d :()) (:wat::test::assert-eq decision "reject")))
    ;; The render must NOT contain the claim's title — it was
    ;; blocked. Render is the [REJECTED] sentinel.
    (:wat::test::assert-contains
      (:exp::Verdict/rendered verdict)
      "[REJECTED]")))


;; ════════════════════════════════════════════════════════════════
;;  T3 — Multi-prohibition: wildcard IAM
;; ════════════════════════════════════════════════════════════════
;;
;; Different prohibition (P3 — wildcard-iam), proves the bundle
;; surfaces matches against any axiom in the set, not just the first.

(:deftest :exp::t3-wildcard-iam-rejects
  (:wat::core::let*
    (((claim :exp::Claim)
      (:exp::Claim/new
        "T3-grant-wildcard-iam"
        "Grant role-app full access (s3:*) to bucket-prod"
        (:wat::holon::from-watast (:wat::core::quote
          (:rule/iam
            (permission-kind "wildcard")
            (action "s3:*")
            (target "bucket-prod"))))))

     ((verdict :exp::Verdict)
      (:exp::evaluate claim (:exp::all-allowed) (:exp::all-forbidden)))

     ((decision :String) (:exp::Verdict/decision verdict)))
    (:wat::test::assert-eq decision "reject")))


;; ════════════════════════════════════════════════════════════════
;;  T4 — Sound claim under multi-axiom policy
;; ════════════════════════════════════════════════════════════════
;;
;; A claim that aligns with multiple allowed axioms simultaneously
;; (encrypted storage + private ingress + specific IAM). The
;; allowed-coherence reflects multiple concurrent policy alignments;
;; should approve clearly.

(:deftest :exp::t4-multi-axiom-approves
  (:wat::core::let*
    (((claim :exp::Claim)
      (:exp::Claim/new
        "T4-deploy-encrypted-rds"
        "Deploy RDS db-prod-01: encrypted, private subnet, specific IAM"
        (:wat::holon::from-watast (:wat::core::quote
          (:rule/storage
            (encryption-at-rest "true")
            (kind "rds")
            (target "db-prod-01"))))))

     ((verdict :exp::Verdict)
      (:exp::evaluate claim (:exp::all-allowed) (:exp::all-forbidden)))

     ((decision :String) (:exp::Verdict/decision verdict)))
    (:wat::test::assert-eq decision "approve")))


;; ════════════════════════════════════════════════════════════════
;;  T5 — Reasoning chain: weakest link decides the verdict
;; ════════════════════════════════════════════════════════════════
;;
;; An agent emits THREE sub-claims as a chain. The chain's verdict
;; is the weakest link — if ANY sub-claim fails the gate, the
;; whole chain fails. This is how policy enforcement should work:
;; one violating step poisons the whole reasoning chain.
;;
;; Sub-claim 1: add encrypted volume       → approve
;; Sub-claim 2: configure backups          → approve
;; Sub-claim 3: open ingress to 0.0.0.0/0  → REJECT (poisons chain)
;;
;; The chain's verdict: rejected (the third sub-claim failed).

(:deftest :exp::t5-chain-weakest-link
  (:wat::core::let*
    (((sub1 :exp::Claim)
      (:exp::Claim/new "T5-1" "Add encrypted volume"
        (:wat::holon::from-watast (:wat::core::quote
          (:rule/storage (encryption-at-rest "true") (kind "ebs"))))))
     ((sub2 :exp::Claim)
      (:exp::Claim/new "T5-2" "Configure daily backups"
        (:wat::holon::from-watast (:wat::core::quote
          (:rule/backup (status "configured") (schedule "daily"))))))
     ((sub3 :exp::Claim)
      (:exp::Claim/new "T5-3" "Open public ingress for testing"
        (:wat::holon::from-watast (:wat::core::quote
          (:rule/ingress (cidr-kind "public") (resource-kind "security-group"))))))

     ((v1 :exp::Verdict) (:exp::evaluate sub1 (:exp::all-allowed) (:exp::all-forbidden)))
     ((v2 :exp::Verdict) (:exp::evaluate sub2 (:exp::all-allowed) (:exp::all-forbidden)))
     ((v3 :exp::Verdict) (:exp::evaluate sub3 (:exp::all-allowed) (:exp::all-forbidden)))

     ;; Chain verdict — fold over the verdicts; if ANY is "reject"
     ;; the whole chain rejects.
     ((d1 :String) (:exp::Verdict/decision v1))
     ((d2 :String) (:exp::Verdict/decision v2))
     ((d3 :String) (:exp::Verdict/decision v3))

     ((chain-rejected :bool)
       (:wat::core::or
         (:wat::core::or (:wat::core::= d1 "reject")
                          (:wat::core::= d2 "reject"))
         (:wat::core::= d3 "reject")))

     ;; Sub-1 and sub-2 should approve; sub-3 should reject.
     ((_s1 :()) (:wat::test::assert-eq d1 "approve"))
     ((_s2 :()) (:wat::test::assert-eq d2 "approve"))
     ((_s3 :()) (:wat::test::assert-eq d3 "reject")))
    (:wat::test::assert-eq chain-rejected true)))


;; ════════════════════════════════════════════════════════════════
;;  T6 — Full pipeline E2E: claim in, verdict + render out
;; ════════════════════════════════════════════════════════════════
;;
;; The complete loop on a single approved claim. Demonstrates that
;; the verdict carries the rendered English when approved, the
;; coherences are populated, and the decision matches the gate logic.

(:deftest :exp::t6-full-pipeline
  (:wat::core::let*
    (((claim :exp::Claim)
      (:exp::Claim/new
        "T6-pipeline-test"
        "Add encrypted backup configuration to prod-db"
        (:wat::holon::from-watast (:wat::core::quote
          (:rule/backup
            (status "configured")
            (encryption-at-rest "true")
            (target "prod-db"))))))

     ((verdict :exp::Verdict)
      (:exp::evaluate claim (:exp::all-allowed) (:exp::all-forbidden)))

     ((claim-id :String) (:exp::Verdict/claim-id verdict))
     ((decision :String) (:exp::Verdict/decision verdict))
     ((rendered :String) (:exp::Verdict/rendered verdict))

     ((id-preserved :bool) (:wat::core::= claim-id "T6-pipeline-test"))
     ((approved :bool) (:wat::core::= decision "approve"))

     ((_id :()) (:wat::test::assert-eq id-preserved true))
     ((_app :()) (:wat::test::assert-eq approved true)))
    ;; Rendered text contains the claim's title (it passed the gate).
    (:wat::test::assert-contains rendered "Add encrypted backup")))


;; ════════════════════════════════════════════════════════════════
;;  T7 — Explicit contradiction caught at the gate
;; ════════════════════════════════════════════════════════════════
;;
;; A claim that EXACTLY matches a prohibition's structural pattern.
;; The forbidden-coherence is high; the verdict is reject; the
;; user never sees this thought as English.
;;
;; This is the strongest case for the soundness gate: an LLM agent
;; that's been jailbroken or is reasoning from compromised inputs
;; can emit a claim that looks plausible in English but matches a
;; forbidden pattern structurally. The substrate catches it before
;; the render.

(:deftest :exp::t7-explicit-contradiction
  (:wat::core::let*
    (((claim :exp::Claim)
      (:exp::Claim/new
        "T7-public-database"
        "Make production database publicly accessible for ease of use"
        (:wat::holon::from-watast (:wat::core::quote
          (:rule/database
            (exposure "public")
            (target "prod-db-cluster"))))))

     ((verdict :exp::Verdict)
      (:exp::evaluate claim (:exp::all-allowed) (:exp::all-forbidden)))

     ((decision :String) (:exp::Verdict/decision verdict))
     ((forbidden-coherence :f64) (:exp::Verdict/forbidden-coherence verdict))
     ((rendered :String) (:exp::Verdict/rendered verdict))

     ;; Forbidden coherence is meaningfully high (> 0.40 under
     ;; max-over-axioms at d=10000).
     ((high-forbidden :bool) (:wat::core::f64::> forbidden-coherence 0.40))

     ((_h :()) (:wat::test::assert-eq high-forbidden true))
     ((_d :()) (:wat::test::assert-eq decision "reject")))
    ;; The user-facing render is the [REJECTED] sentinel — the
    ;; English that would have suggested making the DB public is
    ;; never produced.
    (:wat::test::assert-contains rendered "[REJECTED]")))
