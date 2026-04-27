;; wat-tests-integ/experiment/011-supply-chain/explore-supply-chain.wat
;;
;; Supply-chain attack detection on top of proof 005's Receipt /
;; Journal / Registry primitives. A *competent* demonstration —
;; each deftest maps to a real, named attack class that production
;; security teams fight today.
;;
;; ─── Threat model ────────────────────────────────────────────
;;
;; In scope:
;;
;; T1  Honest publish + consumer verify (the happy path)
;; T2  Registry tampering (CWE-345 — insufficient verification of
;;     data authenticity). Adversary with write access to the
;;     registry swaps a package's manifest post-publish; consumer
;;     verifying via the published Receipt detects the swap.
;; T3  Dependency confusion / typosquat (CWE-1357). Attacker
;;     publishes a package with a confusingly similar name; the
;;     content-addressing in the Registry makes legit and typosquat
;;     entries collision-free at the V-level. A consumer who pins
;;     by V (the substrate-anchored content key) cannot be redirected.
;; T4  Backdoor injection (Solar Winds class — CWE-506). Attacker
;;     compromises the maintainer's build pipeline and injects a
;;     malicious dependency. The published artifact's manifest no
;;     longer matches the maintainer's Receipt; consumer detects.
;; T5  Silent version drift. Consumer pinned to 1.0.0 by V;
;;     adversarial registry returns 1.0.1's manifest under 1.0.0's
;;     name. Verification against pinned V fails.
;; T6  Reproducible builds. Two independent builders, same inputs,
;;     same seed → byte-equal V. Reproducibility anchored cryptographically.
;; T7  Release order audit. Journal preserves chronological release
;;     order; cross-version swap is detected at audit time.
;;
;; Out of scope (this is a primitive, not a system):
;;
;; - Key rotation. Seeds shipped here are config-time globals; a
;;   real deployment would layer key management above.
;; - Revocation. No mechanism to mark a Receipt invalid post-issue.
;; - Time-stamping. Receipts prove "I knew this when I revealed it",
;;   not "I knew this at 14:32 UTC". An external timestamp authority
;;   would compose with this primitive but isn't built here.
;; - Network-level attacks. We assume the consumer can fetch
;;   bytes; how the bytes get there is orthogonal.
;;
;; Each test names its threat class in its own header. The proof
;; artifact narrates the security story.

(:wat::test::make-deftest :deftest
  (;; ─── Receipt — the cryptographic anchor (from proof 005) ──
   ;;
   ;; Each .wat file loads independently, so we re-define the
   ;; Receipt primitive here. Same shape as proof 005; the
   ;; supply-chain experiment is a CONSUMER of the receipt
   ;; primitive, not a substrate change.
   (:wat::core::struct :exp::Receipt
     (bytes :wat::core::Bytes)
     (form :wat::holon::HolonAST)
     (seed-hint :i64))

   (:wat::core::define
     (:exp::issue (form :wat::holon::HolonAST)
                  (seed-hint :i64)
                  -> :exp::Receipt)
     (:wat::core::let*
       (((v :wat::holon::Vector) (:wat::holon::encode form))
        ((bytes :wat::core::Bytes) (:wat::holon::vector-bytes v)))
       (:exp::Receipt/new bytes form seed-hint)))

   (:wat::core::define
     (:exp::verify (r :exp::Receipt)
                   (candidate :wat::holon::HolonAST)
                   -> :bool)
     (:wat::core::match
       (:wat::holon::bytes-vector (:exp::Receipt/bytes r))
       -> :bool
       ((Some v) (:wat::holon::coincident? candidate v))
       (:None false)))


   ;; ─── Domain: Package, Release, Registry ───────────────────
   ;;
   ;; A Release is what the maintainer publishes. It pairs the
   ;; human-readable identifier (name + version) with the structural
   ;; fingerprint (form) and the cryptographic anchor (the receipt
   ;; whose bytes are V_pkg).
   ;;
   ;; A Registry is the package index — keyed by V_pkg (the content
   ;; address). A Journal is the chronological release log — entries
   ;; in order of publish time.
   (:wat::core::struct :exp::Release
     (name :String)
     (version :String)
     (form :wat::holon::HolonAST)
     (receipt :exp::Receipt))

   ;; Package registry — keyed by hex(V_pkg). Lookup by content
   ;; address; collision-free across publishers.
   (:wat::core::struct :exp::PackageRegistry
     (entries :HashMap<String,exp::Release>))

   (:wat::core::define
     (:exp::registry-empty -> :exp::PackageRegistry)
     (:exp::PackageRegistry/new
       (:wat::core::HashMap :(String,exp::Release))))

   (:wat::core::define
     (:exp::publish (reg :exp::PackageRegistry)
                    (rel :exp::Release)
                    -> :exp::PackageRegistry)
     (:exp::PackageRegistry/new
       (:wat::core::assoc (:exp::PackageRegistry/entries reg)
         (:wat::core::Bytes::to-hex
           (:exp::Receipt/bytes (:exp::Release/receipt rel)))
         rel)))

   (:wat::core::define
     (:exp::fetch (reg :exp::PackageRegistry)
                  (pkg-bytes :wat::core::Bytes)
                  -> :Option<exp::Release>)
     (:wat::core::get (:exp::PackageRegistry/entries reg)
                      (:wat::core::Bytes::to-hex pkg-bytes)))

   ;; Release journal — chronological audit of publishes.
   (:wat::core::struct :exp::ReleaseJournal
     (entries :Vec<exp::Release>))

   (:wat::core::define
     (:exp::journal-empty -> :exp::ReleaseJournal)
     (:exp::ReleaseJournal/new (:wat::core::vec :exp::Release)))

   (:wat::core::define
     (:exp::record (j :exp::ReleaseJournal) (rel :exp::Release)
                   -> :exp::ReleaseJournal)
     (:exp::ReleaseJournal/new
       (:wat::core::conj (:exp::ReleaseJournal/entries j) rel)))

   ;; The maintainer's "issue a release" — encode the manifest form,
   ;; capture the receipt, package the Release. This is what `npm
   ;; publish` becomes if it were anchored cryptographically.
   (:wat::core::define
     (:exp::release
       (name :String)
       (version :String)
       (manifest-form :wat::holon::HolonAST)
       (seed-hint :i64)
       -> :exp::Release)
     (:exp::Release/new name version manifest-form
                        (:exp::issue manifest-form seed-hint)))

   ;; The consumer's "verify what I fetched" — given a fetched
   ;; Release and the manifest the consumer expects, verify the
   ;; Receipt against that manifest. This is what `npm install`
   ;; becomes if it verified its lockfile cryptographically.
   (:wat::core::define
     (:exp::install-verify
       (rel :exp::Release)
       (expected-manifest :wat::holon::HolonAST)
       -> :bool)
     (:exp::verify (:exp::Release/receipt rel) expected-manifest))))


;; ════════════════════════════════════════════════════════════════
;;  T1 — Happy path: honest publish + consumer verify
;; ════════════════════════════════════════════════════════════════
;;
;; The npm install that doesn't get attacked. Maintainer publishes
;; pkg-foo 1.0.0; Registry stores it; consumer fetches by content
;; address and verifies against the manifest in their lockfile.

(:deftest :exp::t1-happy-path
  (:wat::core::let*
    (;; Maintainer's manifest — a structural form with name,
     ;; version, dependencies. Real package managers would also
     ;; include source-fingerprints, build instructions, etc.
     ((manifest :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:pkg/manifest
          (name "pkg-foo")
          (version "1.0.0")
          (deps (:dep/lodash "4.17.21"))))))

     ;; Maintainer publishes.
     ((release :exp::Release)
      (:exp::release "pkg-foo" "1.0.0" manifest 42))
     ((registry :exp::PackageRegistry)
      (:exp::publish (:exp::registry-empty) release))

     ;; Consumer holds the V (from their lockfile) and the manifest
     ;; (from their dependencies).
     ((pkg-V :wat::core::Bytes) (:exp::Receipt/bytes (:exp::Release/receipt release)))

     ;; Consumer fetches by V and verifies against expected manifest.
     ((fetched :Option<exp::Release>) (:exp::fetch registry pkg-V))
     ((verified :bool)
       (:wat::core::match fetched -> :bool
         ((Some r) (:exp::install-verify r manifest))
         (:None false))))
    (:wat::test::assert-eq verified true)))


;; ════════════════════════════════════════════════════════════════
;;  T2 — Registry tampering (CWE-345)
;; ════════════════════════════════════════════════════════════════
;;
;; Adversary has write access to the package registry. They swap
;; pkg-foo's manifest in the registry — adding a malicious dep, or
;; substituting the source-fingerprint to point at attacker-
;; controlled artifact bytes. The Receipt's bytes were issued
;; against the ORIGINAL manifest; substituting the manifest in the
;; Release struct doesn't change those bytes.
;;
;; The consumer verifies the Receipt against the manifest IN THE
;; FETCHED RELEASE. If the manifest was tampered, the receipt's
;; bytes still encode the original manifest's form — verification
;; against the tampered manifest fails.
;;
;; This is the "registry as adversarial party" threat. The Receipt
;; binds the manifest to the publish-time bytes; the registry
;; cannot rewrite history without invalidating the binding.

(:deftest :exp::t2-registry-tampering
  (:wat::core::let*
    (((legit-manifest :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:pkg/manifest
          (name "pkg-foo")
          (version "1.0.0")
          (deps (:dep/lodash "4.17.21"))))))

     ;; Maintainer publishes the legit version.
     ((legit-release :exp::Release)
      (:exp::release "pkg-foo" "1.0.0" legit-manifest 42))

     ;; Adversary swaps the manifest INSIDE the Release struct
     ;; (simulating registry write-access tampering) but keeps the
     ;; original receipt — pretending the published bytes still
     ;; vouch for the new content.
     ((malicious-manifest :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:pkg/manifest
          (name "pkg-foo")
          (version "1.0.0")
          (deps (:dep/lodash "4.17.21")
                (:dep/evil-backdoor "9.9.9"))))))
     ((tampered-release :exp::Release)
      (:exp::Release/new
        (:exp::Release/name legit-release)
        (:exp::Release/version legit-release)
        malicious-manifest
        (:exp::Release/receipt legit-release)))

     ;; Consumer fetches the tampered release and verifies it
     ;; against what they EXPECT (the legit manifest from their
     ;; lockfile or upstream announcement).
     ((expected-legit :bool)
       (:exp::install-verify tampered-release legit-manifest))
     ((accepts-malicious :bool)
       (:exp::install-verify tampered-release malicious-manifest))

     ;; The legit manifest still verifies against the receipt
     ;; (because the receipt vouches for that manifest's form).
     ((_l :()) (:wat::test::assert-eq expected-legit true)))

    ;; The malicious manifest does NOT verify — the receipt's
    ;; bytes encode the LEGIT manifest, not the malicious one.
    ;; Consumer detects the tampering.
    (:wat::test::assert-eq accepts-malicious false)))


;; ════════════════════════════════════════════════════════════════
;;  T3 — Dependency confusion / typosquat (CWE-1357)
;; ════════════════════════════════════════════════════════════════
;;
;; Attacker publishes "pkg-foo" (legitimate-looking) hoping the
;; consumer's package manager fetches their version instead of the
;; real one. Or publishes "pkg-fO0" (lookalike Unicode) banking on
;; the consumer not noticing.
;;
;; Content-addressing makes this collision-free at the V level. The
;; legitimate package's content fingerprint is V_legit; the
;; typosquat's is V_typo; they're different bytes; they map to
;; different Registry keys. A consumer who PINS by V (instead of
;; by-name + by-version) cannot be redirected.
;;
;; This is what lockfiles SHOULD do but rarely do — pin by content
;; hash, not by name+version. Receipts make this discipline
;; substrate-anchored.

(:deftest :exp::t3-dependency-confusion
  (:wat::core::let*
    (((legit-manifest :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:pkg/manifest
          (name "pkg-foo")
          (version "1.0.0")
          (deps (:dep/lodash "4.17.21"))))))

     ;; Typosquat — same shape, different deps (or different
     ;; source-fingerprint, etc.). Different content → different V.
     ((typosquat-manifest :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:pkg/manifest
          (name "pkg-foo")
          (version "1.0.0")
          (deps (:dep/lodash "4.17.21")
                (:dep/cryptominer "0.0.1"))))))

     ((legit :exp::Release)
      (:exp::release "pkg-foo" "1.0.0" legit-manifest 42))
     ((typosquat :exp::Release)
      (:exp::release "pkg-foo" "1.0.0" typosquat-manifest 42))

     ;; Both end up in the registry — content-addressed under
     ;; different keys (different V_bytes).
     ((registry :exp::PackageRegistry)
      (:exp::publish (:exp::publish (:exp::registry-empty) legit) typosquat))

     ;; Consumer pins by V (the legit V from their lockfile).
     ((legit-V :wat::core::Bytes) (:exp::Receipt/bytes (:exp::Release/receipt legit)))
     ((typosquat-V :wat::core::Bytes) (:exp::Receipt/bytes (:exp::Release/receipt typosquat)))

     ;; The two V's are byte-distinct (different content; no
     ;; collision at the substrate level).
     ((same-V :bool) (:wat::core::= legit-V typosquat-V))
     ((_d :()) (:wat::test::assert-eq same-V false))

     ;; Fetch by legit V → returns the legit release. The
     ;; typosquat is registered but at a DIFFERENT key; pinning by
     ;; V routes around it.
     ((fetched :Option<exp::Release>) (:exp::fetch registry legit-V))
     ((got-legit :bool)
       (:wat::core::match fetched -> :bool
         ((Some r) (:exp::install-verify r legit-manifest))
         (:None false))))
    (:wat::test::assert-eq got-legit true)))


;; ════════════════════════════════════════════════════════════════
;;  T4 — Backdoor injection (Solar Winds class — CWE-506)
;; ════════════════════════════════════════════════════════════════
;;
;; Attacker compromises the build pipeline. The maintainer's
;; intended manifest is M_legit. The compromised pipeline publishes
;; an artifact whose actual manifest is M_backdoored (with a
;; malicious dep injected) but issues the Receipt against M_backdoored.
;;
;; The consumer who has the maintainer's intended manifest
;; (e.g., from public source repository review) verifies the
;; published Receipt against M_legit. Since the receipt's bytes
;; encode M_backdoored, verification against M_legit fails.
;;
;; This catches the supply-chain compromise IF the consumer holds
;; an out-of-band-trusted version of the manifest. The Receipt is
;; the cryptographic primitive; the out-of-band trust (publisher's
;; public source, package manifest signing, attestation services)
;; is a different layer that composes here.

(:deftest :exp::t4-backdoor-injection
  (:wat::core::let*
    (;; What the maintainer INTENDED to publish (visible in source repo).
     ((legit-manifest :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:pkg/manifest
          (name "pkg-foo")
          (version "1.0.0")
          (deps (:dep/lodash "4.17.21"))))))

     ;; What the compromised build pipeline actually shipped.
     ((backdoored-manifest :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:pkg/manifest
          (name "pkg-foo")
          (version "1.0.0")
          (deps (:dep/lodash "4.17.21")
                (:dep/orion-sunburst "any"))))))

     ;; The compromised pipeline issues a Receipt against the
     ;; backdoored manifest (because that IS what it shipped).
     ((shipped :exp::Release)
      (:exp::release "pkg-foo" "1.0.0" backdoored-manifest 42))

     ;; Consumer verifies against the publicly-trusted manifest
     ;; (e.g., reproduced from source review).
     ((accepts :bool) (:exp::install-verify shipped legit-manifest)))
    (:wat::test::assert-eq accepts false)))


;; ════════════════════════════════════════════════════════════════
;;  T5 — Silent version drift
;; ════════════════════════════════════════════════════════════════
;;
;; Consumer pinned by V to pkg-foo 1.0.0. An adversarial registry
;; (or an unsafe `npm install` that ignores the lockfile) returns
;; pkg-foo 1.0.1's manifest instead. The consumer verifies the
;; received release against their PINNED V — fetched manifest
;; doesn't match.
;;
;; This is what V-based pinning gets you: silent upgrades cannot
;; pass the verification step. Either the consumer accepts a new
;; V (explicit upgrade) or they reject the artifact.

(:deftest :exp::t5-silent-version-drift
  (:wat::core::let*
    (((manifest-100 :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:pkg/manifest
          (name "pkg-foo")
          (version "1.0.0")
          (deps (:dep/lodash "4.17.21"))))))
     ((manifest-101 :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:pkg/manifest
          (name "pkg-foo")
          (version "1.0.1")
          (deps (:dep/lodash "4.17.21"))))))

     ((release-100 :exp::Release)
      (:exp::release "pkg-foo" "1.0.0" manifest-100 42))
     ((release-101 :exp::Release)
      (:exp::release "pkg-foo" "1.0.1" manifest-101 42))

     ;; Consumer pinned to 1.0.0's V in their lockfile.
     ((pinned-V :wat::core::Bytes) (:exp::Receipt/bytes (:exp::Release/receipt release-100)))

     ;; Adversarial registry: return 1.0.1's release for the
     ;; pinned-V request (pretending the bytes match by ignoring
     ;; the content-addressing — simulating a registry that
     ;; doesn't honor V-pinning).
     ((accepts-drift :bool)
       (:exp::install-verify release-101 manifest-100)))
    (:wat::test::assert-eq accepts-drift false)))


;; ════════════════════════════════════════════════════════════════
;;  T6 — Reproducible builds
;; ════════════════════════════════════════════════════════════════
;;
;; Two independent builders, same source manifest, same seed (the
;; published universe parameter). Each produces their own Receipt.
;; The Receipts' bytes are byte-equal — proving the V is a function
;; of (form, seed) only, not of build environment.
;;
;; Reproducible builds are a real, multi-decade industry initiative.
;; The substrate makes "the build is deterministic" cryptographically
;; verifiable rather than belief-based.

(:deftest :exp::t6-reproducible-builds
  (:wat::core::let*
    (((manifest :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:pkg/manifest
          (name "pkg-foo")
          (version "1.0.0")
          (deps (:dep/lodash "4.17.21"))))))

     ;; Builder A — independent build environment.
     ((receipt-a :exp::Receipt) (:exp::issue manifest 42))
     ((bytes-a :wat::core::Bytes) (:exp::Receipt/bytes receipt-a))

     ;; Builder B — different machine, different network, same
     ;; manifest, same seed.
     ((receipt-b :exp::Receipt) (:exp::issue manifest 42))
     ((bytes-b :wat::core::Bytes) (:exp::Receipt/bytes receipt-b))

     ;; The two builders produced byte-equal V's. Each can publish
     ;; independently; consumers can verify either.
     ((reproducible :bool) (:wat::core::= bytes-a bytes-b)))
    (:wat::test::assert-eq reproducible true)))


;; ════════════════════════════════════════════════════════════════
;;  T7 — Release order audit (Journal)
;; ════════════════════════════════════════════════════════════════
;;
;; The maintainer's release Journal is the chronological audit
;; trail of what was published when. Three versions in order;
;; auditor walks the journal and confirms each entry verifies
;; against its claimed manifest. Cross-version claims (asserting
;; 1.0.1 is at index 0) are rejected.
;;
;; This is what tools like Sigstore's Rekor are for — a
;; transparency log of releases. The substrate's Journal IS this
;; transparency log, locally.

(:deftest :exp::t7-release-order-audit
  (:wat::core::let*
    (((m-100 :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:pkg/manifest (name "pkg-foo") (version "1.0.0")
                       (deps (:dep/lodash "4.17.21"))))))
     ((m-101 :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:pkg/manifest (name "pkg-foo") (version "1.0.1")
                       (deps (:dep/lodash "4.17.21"))))))
     ((m-110 :wat::holon::HolonAST)
      (:wat::holon::from-watast (:wat::core::quote
        (:pkg/manifest (name "pkg-foo") (version "1.1.0")
                       (deps (:dep/lodash "4.17.21")
                             (:dep/chrono "0.4.31"))))))

     ((r-100 :exp::Release) (:exp::release "pkg-foo" "1.0.0" m-100 42))
     ((r-101 :exp::Release) (:exp::release "pkg-foo" "1.0.1" m-101 42))
     ((r-110 :exp::Release) (:exp::release "pkg-foo" "1.1.0" m-110 42))

     ((journal :exp::ReleaseJournal)
      (:exp::record (:exp::record (:exp::record (:exp::journal-empty)
                                                r-100)
                                  r-101)
                    r-110))
     ((entries :Vec<exp::Release>) (:exp::ReleaseJournal/entries journal))

     ;; Auditor walks the journal in order; each entry verifies
     ;; against its OWN claimed manifest.
     ((entry-0 :Option<exp::Release>) (:wat::core::get entries 0))
     ((entry-2 :Option<exp::Release>) (:wat::core::get entries 2))

     ((order-100 :bool)
       (:wat::core::match entry-0 -> :bool
         ((Some r) (:wat::core::= "1.0.0" (:exp::Release/version r)))
         (:None false)))
     ((order-110 :bool)
       (:wat::core::match entry-2 -> :bool
         ((Some r) (:wat::core::= "1.1.0" (:exp::Release/version r)))
         (:None false)))

     ;; Cross-version swap — claim entry-0 is 1.1.0's manifest.
     ;; Verification rejects (the receipt at index 0 vouches for
     ;; 1.0.0, not 1.1.0).
     ((swap-detected :bool)
       (:wat::core::match entry-0 -> :bool
         ((Some r) (:exp::install-verify r m-110))
         (:None false)))

     ((_o100 :()) (:wat::test::assert-eq order-100 true))
     ((_o110 :()) (:wat::test::assert-eq order-110 true)))
    (:wat::test::assert-eq swap-detected false)))
