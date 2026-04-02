# Proposal 006 — Multi-Asset Treasury: Wealth Accumulation Across Pairs

**Scope:** userland
**Date:** 2026-04-01

## Current State

The treasury holds two assets (USDC, WBTC). One desk trades the (USDC, WBTC) pair. Positions are isolated lots — each Buy swaps a fraction of USDC into WBTC, manages the new WBTC as a ManagedPosition with stops and take-profits, then sells it back on exit.

The 50/50 seed splits $10k into $5k USDC and ~1.35 WBTC. The seed WBTC sits in `balance` and never participates in trading. All trades operate on freshly-swapped lots. The seed appreciates passively with BTC price but is never managed.

## The Problem

### 1. Dead capital

The seed WBTC (50% of starting equity) is dead weight. The enterprise trades with $5k USDC, not $10k. A Sell signal sells 1.5% of available WBTC — 0.02 WBTC (~$75) — because position sizing was designed for the USDC→WBTC direction.

### 2. Isolated lots vs portfolio allocation

A Buy signal means "BTC will go up." The correct action is to increase WBTC exposure across the entire treasury — not open a $75 lot while $7k of WBTC sits idle. A Sell signal means "BTC will go down." The correct action is to reduce WBTC exposure — sell a meaningful portion of holdings back to USDC.

The position lifecycle (buy → take profit → runner → stop loss) is correct for managing individual trades. But the treasury's OVERALL allocation between USDC and WBTC is what determines wealth accumulation.

### 3. Single pair

The architecture assumes one pair. To accumulate wealth across assets (SPY, GOLD, BTC, ETH, SOL, ...), we need N desks monitoring N pairs, each an expert in its domain, with the treasury routing capital between them.

## Proposed Design

### Treasury: the wealth pool

The treasury holds N assets. Each asset has a balance (available) and deployed (locked in active positions). Total wealth = sum of all assets valued at current market prices.

```
Treasury {
  assets: { USDC: 5000.0, WBTC: 1.35, SOL: 100.0, ETH: 2.5 }
  deployed: { WBTC: 0.15, SOL: 10.0 }
}
```

### Desks: pair experts

Each desk monitors one pair. A desk has:
- A candle stream for its pair
- An observer panel (5 specialists + 1 generalist) thinking about THAT pair's data
- A manager that predicts direction for THAT pair
- A risk branch measuring THAT pair's portfolio health

**Base desks** trade against USDC: (USDC, BTC), (USDC, ETH), (USDC, SOL), ...
**Extended desks** trade cross-pairs: (SOL, BTC), (ETH, BTC), ...

A desk doesn't know about the treasury. It produces a signal: direction + conviction + sizing fraction. The enterprise decides whether to act.

### Positions: allocation events

A position is not "I bought 0.02 WBTC." A position is "I moved the treasury from X% WBTC to Y% WBTC."

When a (USDC, BTC) desk says Buy with conviction 0.25:
1. Treasury computes target allocation: increase WBTC exposure by `frac` of available USDC
2. Swap USDC → WBTC (the entire swap amount becomes the position)
3. Position manages the trade: take profit reclaims USDC principal, runner rides with trailing stop
4. On exit: WBTC swaps back to USDC. Net effect: treasury gained or lost based on BTC movement during the hold period.

When the same desk says Sell:
1. Treasury computes target: decrease WBTC exposure by `frac` of available WBTC
2. Swap WBTC → USDC (from the treasury's WBTC balance — seed included)
3. Position manages the inverse trade: take profit reclaims WBTC principal, runner rides
4. On exit: USDC swaps back to WBTC. Net effect: treasury preserved value during a BTC decline.

The seed is not special. All available balance is tradeable. The enterprise decides how much to deploy.

### No routing — hold or sit out

A (SOL, BTC) desk says "SOL cheap relative to BTC." The treasury checks: do I hold BTC? If yes, swap BTC → SOL. If no, the signal is valid but unactionable — log it, don't act. No intermediate routing through USDC.

This means the treasury's current holdings determine which desk signals can be executed. A desk for (DOGE, SILVER) is useless if the treasury holds neither. The enterprise accumulates access to more pairs by accumulating more assets. The portfolio grows its surface area naturally.

### No cross-asset manager — desks are independent

Each desk produces signals independently. The treasury executes if it holds the assets and risk allows. Deconfliction is natural: finite capital + risk branches + per-desk proof gates. If the BTC desk says Buy and the ETH desk says Sell, the treasury executes both — they're independent pairs with independent convictions.

A meta-layer learning "which desk combinations predict wealth" is premature. Each desk has its own conviction-accuracy curve. The curves are the judges. If a desk is proven, its signals are valid. If not, its signals are gated. No additional arbitration needed.

## The Algebraic Question

This composes with existing primitives:
- Each desk uses the same six primitives (atom, bind, bundle, cosine, journal, curve)
- The cross-asset manager is another journal with a different vocabulary (desk signals instead of candle indicators)
- Treasury routing is pure accounting (swap, claim, release)
- No new algebraic structures needed

## The Simplicity Question

The key simplification: **a position is a treasury allocation change, not an isolated lot.** This removes the concept of "seed capital" vs "trading capital." All capital is tradeable. The position lifecycle (take profit → runner → stop loss) manages the allocation change, not a detached lot.

There is no special complexity. A swap is token-to-token. If we monitor a pair, we believe it's liquid and tradeable. The treasury holds tokens. Desks produce signals about token pairs. The treasury swaps if it holds the source token and risk allows. That's it.

## Questions for Designers

1. **Position as allocation change vs isolated lot.** The current ManagedPosition tracks a specific `quote_held` amount. Should it instead track "I moved X% of the treasury from asset A to asset B"? Or should the lot model be kept with the treasury simply making its full balance available?

2. **Sell from holdings.** When a Sell signal fires, should the system sell from the treasury's existing balance (including seed), or should it only sell what was previously bought by a Buy position? The former means the seed participates. The latter means the seed is dead capital.

3. **Phasing.** Should we fix the single-pair treasury first (make seed WBTC tradeable, fix position sizing for Sell) before building multi-asset? Or design both together?
