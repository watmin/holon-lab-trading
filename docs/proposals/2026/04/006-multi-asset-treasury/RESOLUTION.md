# Resolution: Proposal 006 — Multi-Asset Treasury

**Status:** APPROVED with conditions resolved
**Date:** 2026-04-01

## Designer Verdicts

- **Hickey:** CONDITIONAL — fix position struct (source/target), allocatable per-asset, acknowledge concentration risk
- **Beckman:** CONDITIONAL — fix Short asymmetry, decide utilization scope, acknowledge resource coupling, keep lots

## Datamancer Decisions

### 1. Symmetry is the law. Token-to-token.

Both designers flagged the Long/Short asymmetry. The datamancer agrees: a swap is a swap. One token goes out, another comes in. Long or Short is the reason, not the mechanism. The position struct speaks source/target, not base/quote. One formula. Both directions. The `match direction` in `return_pct` dies.

`claim` locks capital on both sides. If you swap USDC for WBTC, the WBTC is claimed. If you swap WBTC for USDC, the USDC is claimed. Symmetric. What's claimed is locked. What's locked can't be touched by other trades.

### 2. Keep lots. Track in units.

Beckman is right: lots are values, percentages are references. A position tracks units: 0.02 WBTC claimed, or 100.50 USDC claimed. The percentage is what CHOSE those units at entry time — the price of the candle determines the units reserved for the percentage selected. After that, the lot owns units, not percentages.

### 3. Kill the seed distinction.

The seed being locked was an accident, not a design. The treasury is a map of token to units — available and deployed. If there are available units, the enterprise can deploy them. No special reserves. No seed magic.

### 4. Portfolio-wide utilization. Risk decides.

Beckman asked per-asset vs portfolio-wide. Answer: portfolio-wide. The risk branch determines what we can actually deploy. The trade desks indicate a change is exploitable. The risk team determines what we can do about it. The treasury decides if we will act.

`allocatable(asset)` computes how many units of that asset are available given risk constraints. The dollar denomination comes from the current candle — the treasury resolves token units to dollar value on demand. Traders don't need dollar values. Risk and treasury do.

### 5. Desks are independent. Period.

Beckman noted resource coupling through the shared treasury pool. The datamancer's response: trades are ingested sequentially. If funds aren't available for a trade, it doesn't execute. The (SOL, BTC) sell completing before the (USDC, BTC) buy is just sequential ordering — not coupling. The signal was valid, the treasury checked, it acted or didn't.

Desks are independent signal generators. Others may tap their voices (stop loss experts, horizon experts) but this is the signalling problem we already modeled. Not a channel, but a channel in spirit.

### 6. Concentration risk: acknowledged, deferred.

Hickey is right that BTC and ETH are correlated. The datamancer does not agree this needs solving now. If we choose to introduce asset-class awareness, that's another expert — one that thinks about correlation. Not now. Acknowledged for when N > 1.

### 7. Hickey's "Buy when you already hold" concern

If we hold BTC and the traders say Buy more BTC — do it. Risk chooses the percentage. We don't deny a Buy because we already hold the asset. The desk monitors (USDC, WBTC) and says "get BTC" — the treasury checks if it has USDC, risk approves the amount, and it executes. Having BTC already doesn't make the Buy signal wrong. It means the system is confident.

### 8. Design for N, prove with 1.

Implement as `Vec<Desk>` with one element: `[(USDC, WBTC)]`. The code handles a list. The list has one entry today and 20 tomorrow. Forcing the list now solves headaches later. This is not premature generalization — it's the architecture the proposal describes.

### 9. Paper realm vs reality.

Traders and risk (and others we'll build later) exist in the paper realm. They keep learning from all signals, including ones the treasury can't act on. The treasury handles reality — actual swaps, actual claims, actual units. The pending entry path is paper. The ManagedPosition path is real. They must never be confused again.

## Implementation Order

1. **Position struct: source/target.** Kill base_deployed/quote_held. Source asset, source amount, target asset, target amount, exchange rate. One lifecycle, both directions.

2. **Symmetric claim.** Both Buy and Sell create positions that claim received assets. Release on exit. No free-floating capital movements.

3. **Kill seed distinction.** Treasury balance is treasury balance. All available units are deployable.

4. **`allocatable(asset, prices, risk_policy)`** — per-asset query, portfolio-wide constraint. Risk determines deployable fraction. Treasury resolves units.

5. **`Vec<Desk>`** with one desk. Candle stream per desk. Observer panel per desk. Manager per desk. The enterprise iterates the list.

6. **Prove with (USDC, WBTC).** Match or exceed the good run ($19.7k, 65.5% accuracy). Then add pairs.
