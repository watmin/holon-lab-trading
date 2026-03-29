# Trading Enterprise — wat specs

Domain-specific wat specifications for the BTC trading enterprise.

## Dependencies

This directory depends on the wat language repo at `~/work/holon/wat/`:

```
~/work/holon/wat/              ← the language (corelib + stdlib + modules)
  core/primitives.wat          ← six primitives
  std/common.wat               ← shared vocabulary
  std/channels.wat             ← publish/subscribe contract
  mod/                         ← domain vocabulary modules
  LANGUAGE.md                  ← formal grammar

~/work/holon/holon-lab-trading/wat/  ← this directory (application specs)
  manager.wat                  ← manager encoding spec
  expert/                      ← per-expert specs
  generalist.wat               ← generalist spec
  risk.wat                     ← risk branch spec
  treasury.wat                 ← treasury spec
  ledger.wat                   ← ledger spec
  position.wat                 ← position lifecycle spec
  DISCOVERIES.md               ← findings from implementation
```

## Relationship

```scheme
;; Application specs import from the language:
(require core/primitives)      ; from ~/work/holon/wat/
(require std/common)           ; from ~/work/holon/wat/
(require std/channels)         ; from ~/work/holon/wat/
(require mod/oscillators)      ; from ~/work/holon/wat/

;; Then define domain-specific structures:
(define manager ...)           ; in this directory
(define expert ...)            ; in this directory
```

The wat repo IS the language. This directory IS the application.
