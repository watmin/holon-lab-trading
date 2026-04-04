use std::collections::HashMap;
use std::fmt;

// ─── Rate ──────────────────────────────────────────────────────────────────

/// Price expressed as "units of FROM per unit of TO" (from_per_to).
/// The newtype prevents swap(rate) vs swap(1/rate) errors.
#[derive(Clone, Copy, Debug)]
pub struct Rate(pub f64);

// ─── Accumulation Ledger ───────────────────────────────────────────────────
// Tracks lifetime harvest per asset. The accumulation model's accounting.
// See wat/accumulation.wat for the full spec.

pub struct AccumulationLedger {
    /// Lifetime residue accumulated per asset (from principal recovery).
    pub total_accumulated: HashMap<Asset, f64>,
    /// Total trades opened (both directions).
    pub trade_count: usize,
    /// Trades where principal was recovered (take-profit → runner).
    pub recovery_count: usize,
    /// Trades stopped out at a loss (active stop-loss).
    pub loss_count: usize,
    /// Lifetime source lost to stop-losses, per asset.
    pub total_lost: HashMap<Asset, f64>,
    /// Lifetime fees paid across all trades.
    pub total_fees: f64,
}

impl AccumulationLedger {
    pub fn new() -> Self {
        Self {
            total_accumulated: HashMap::new(),
            trade_count: 0,
            recovery_count: 0,
            loss_count: 0,
            total_lost: HashMap::new(),
            total_fees: 0.0,
        }
    }

    /// Record a principal recovery: residue deposited as accumulated target.
    pub fn record_recovery(&mut self, asset: &Asset, residue: f64) {
        self.recovery_count += 1;
        *self.total_accumulated.entry(asset.clone()).or_insert(0.0) += residue;
    }

    /// Record a stop-loss: source lost.
    pub fn record_loss(&mut self, asset: &Asset, loss: f64) {
        self.loss_count += 1;
        *self.total_lost.entry(asset.clone()).or_insert(0.0) += loss;
    }

    /// Record a trade opened.
    pub fn record_trade(&mut self) {
        self.trade_count += 1;
    }

    /// Record fees paid.
    pub fn record_fees(&mut self, fees: f64) {
        self.total_fees += fees;
    }

    /// Lifetime residue accumulated for an asset.
    pub fn accumulated(&self, asset: &Asset) -> f64 {
        *self.total_accumulated.get(asset).unwrap_or(&0.0)
    }

    /// Lifetime loss for an asset.
    pub fn lost(&self, asset: &Asset) -> f64 {
        *self.total_lost.get(asset).unwrap_or(&0.0)
    }
}


// ─── Asset ──────────────────────────────────────────────────────────────────

/// A named asset (e.g. "USDC", "WBTC"). Not a price, not an amount.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Asset(pub String);

impl Asset {
    pub fn new(name: &str) -> Self { Self(name.to_string()) }
    pub fn as_str(&self) -> &str { &self.0 }
}

impl fmt::Display for Asset {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

// ─── Treasury ────────────────────────────────────────────────────────────────
// The treasury is a map of tokens to units. Not dollar-denominated.
// Each token has a balance (available) and deployed (locked in active positions).
// Dollar valuation is computed on demand from current prices.
// Pure accounting. No predictions. No thoughts. A ledger.

// rune:scry(aspirational) — treasury.wat specifies alpha tracking: cumulative trading value
// vs counterfactual inaction (snapshot before each swap, compare after). Treasury struct has
// no alpha field, no snapshot field, no counterfactual comparison. Risk alpha-journal depends
// on this.

pub struct Treasury {
    pub balances:         HashMap<Asset, f64>,  // token → available units
    pub deployed:         HashMap<Asset, f64>,  // token → units locked in active positions
    pub max_positions:    usize,
    pub max_utilization:  f64,                  // max fraction of total portfolio deployed
    pub total_fees_paid:  f64,
    pub total_slippage:   f64,
}

impl Treasury {
    pub fn new(max_positions: usize, max_utilization: f64) -> Self {
        Self {
            balances: HashMap::new(),
            deployed: HashMap::new(),
            max_positions,
            max_utilization,
            total_fees_paid: 0.0,
            total_slippage: 0.0,
        }
    }

    /// Seed the treasury with an initial amount of an asset.
    pub fn deposit(&mut self, asset: &Asset, amount: f64) {
        *self.balances.entry(asset.clone()).or_insert(0.0) += amount;
    }

    /// Withdraw from available balance. Returns actual amount withdrawn.
    pub fn withdraw(&mut self, asset: &Asset, amount: f64) -> f64 {
        let bal = self.balances.entry(asset.clone()).or_insert(0.0);
        let actual = amount.min(*bal);
        *bal -= actual;
        actual
    }

    /// Available units of an asset (not deployed).
    pub fn balance(&self, asset: &Asset) -> f64 {
        *self.balances.get(asset).unwrap_or(&0.0)
    }

    /// Units of an asset locked in active positions.
    pub fn deployed(&self, asset: &Asset) -> f64 {
        *self.deployed.get(asset).unwrap_or(&0.0)
    }

    /// Total units of an asset (available + deployed).
    pub fn total(&self, asset: &Asset) -> f64 {
        self.balance(asset) + self.deployed(asset)
    }

    /// How many units of `asset` can be deployed for a new position?
    /// Considers portfolio-wide utilization limit and position count.
    /// `n_open` is passed in — position counting is the enterprise's concern.
    pub fn allocatable(&self, asset: &Asset, prices: &HashMap<Asset, f64>, n_open: usize) -> f64 {
        if n_open >= self.max_positions { return 0.0; }
        let portfolio_value = self.total_value(prices);
        if portfolio_value <= 0.0 { return 0.0; }
        let total_deployed_value = self.deployed_value(prices);
        let deploy_room = (portfolio_value * self.max_utilization - total_deployed_value).max(0.0);
        // Convert room (in portfolio units, e.g. USD) to asset units
        let asset_price = prices.get(asset).copied().unwrap_or(1.0);
        let max_units = deploy_room / asset_price;
        max_units.min(self.balance(asset))
    }

    /// Portfolio utilization: fraction of total value currently deployed.
    pub fn utilization(&self, prices: &HashMap<Asset, f64>) -> f64 {
        let total = self.total_value(prices);
        if total <= 0.0 { return 0.0; }
        self.deployed_value(prices) / total
    }

    /// Move units from available to deployed. Returns amount actually claimed.
    /// Does NOT modify n_open — position counting is the enterprise's concern.
    pub fn claim(&mut self, asset: &Asset, amount: f64) -> f64 {
        let available = self.balance(asset);
        let claimed = amount.min(available);
        if claimed <= 0.0 { return 0.0; }
        *self.balances.get_mut(asset).unwrap() -= claimed;
        *self.deployed.entry(asset.clone()).or_insert(0.0) += claimed;
        claimed
    }

    /// Move units from deployed back to available.
    /// Does NOT modify n_open — position counting is the enterprise's concern.
    pub fn release(&mut self, asset: &Asset, amount: f64) {
        let dep = self.deployed.entry(asset.clone()).or_insert(0.0);
        let released = amount.min(*dep);
        *dep -= released;
        *self.balances.entry(asset.clone()).or_insert(0.0) += released;
    }

    /// Swap one token for another at a given rate, minus fees.
    /// `rate` = how many units of `from` per unit of `to` (from_per_to).
    /// Returns (from_amount_spent, to_amount_received).
    pub fn swap(
        &mut self,
        from: &Asset,
        to: &Asset,
        amount_from: f64,
        rate: Rate,
        fee_rate: f64,
    ) -> (f64, f64) {
        let available = self.balance(from);
        let spend = amount_from.min(available);
        if spend <= 0.0 || rate.0 <= 0.0 { return (0.0, 0.0); }

        let after_fee = spend * (1.0 - fee_rate);
        let received = after_fee / rate.0;
        let fee_amount = spend * fee_rate;

        *self.balances.entry(from.clone()).or_insert(0.0) -= spend;
        *self.balances.entry(to.clone()).or_insert(0.0) += received;
        self.total_fees_paid += fee_amount;

        (spend, received)
    }

    /// Build a price map. Base asset (USDC) is always 1.0.
    pub fn price_map(&self, asset_prices: &[(&Asset, f64)]) -> HashMap<Asset, f64> {
        let mut prices = HashMap::new();
        // All assets default to 1.0 (stablecoins)
        for asset in self.balances.keys().chain(self.deployed.keys()) {
            prices.entry(asset.clone()).or_insert(1.0);
        }
        for &(asset, price) in asset_prices {
            prices.insert(asset.clone(), price);
        }
        prices
    }

    /// Total portfolio value in a common denomination.
    pub fn total_value(&self, prices: &HashMap<Asset, f64>) -> f64 {
        let mut total = 0.0;
        for (asset, &bal) in &self.balances {
            total += bal * prices.get(asset).copied().unwrap_or(1.0);
        }
        for (asset, &dep) in &self.deployed {
            total += dep * prices.get(asset).copied().unwrap_or(1.0);
        }
        total
    }

    /// Total deployed value in a common denomination.
    fn deployed_value(&self, prices: &HashMap<Asset, f64>) -> f64 {
        self.deployed.iter()
            .map(|(asset, &dep)| dep * prices.get(asset).copied().unwrap_or(1.0))
            .sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn usdc() -> Asset { Asset::new("USDC") }
    fn wbtc() -> Asset { Asset::new("WBTC") }

    fn price_map(btc_price: f64) -> HashMap<Asset, f64> {
        let mut m = HashMap::new();
        m.insert(usdc(), 1.0);
        m.insert(wbtc(), btc_price);
        m
    }

    #[test]
    fn deposit_adds_to_balance() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 1000.0);
        assert_eq!(t.balance(&usdc()), 1000.0);
        t.deposit(&usdc(), 500.0);
        assert_eq!(t.balance(&usdc()), 1500.0);
    }

    #[test]
    fn withdraw_removes_capped_at_available() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 100.0);
        let got = t.withdraw(&usdc(), 60.0);
        assert_eq!(got, 60.0);
        assert_eq!(t.balance(&usdc()), 40.0);

        // withdraw more than available
        let got = t.withdraw(&usdc(), 999.0);
        assert_eq!(got, 40.0);
        assert_eq!(t.balance(&usdc()), 0.0);
    }

    #[test]
    fn swap_converts_at_rate_minus_fees() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 1000.0);
        // rate = 50000 USDC per BTC, fee = 1%
        let (spent, received) = t.swap(&usdc(), &wbtc(), 1000.0, Rate(50000.0), 0.01);
        assert_eq!(spent, 1000.0);
        // after fee: 990 USDC / 50000 = 0.0198 BTC
        assert!((received - 0.0198).abs() < 1e-10);
        assert_eq!(t.balance(&usdc()), 0.0);
        assert!((t.balance(&wbtc()) - 0.0198).abs() < 1e-10);
        assert!((t.total_fees_paid - 10.0).abs() < 1e-10);
    }

    #[test]
    fn swap_capped_at_available() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 100.0);
        let (spent, received) = t.swap(&usdc(), &wbtc(), 500.0, Rate(50000.0), 0.0);
        assert_eq!(spent, 100.0);
        assert!((received - 100.0 / 50000.0).abs() < 1e-12);
    }

    #[test]
    fn swap_zero_rate_returns_nothing() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 100.0);
        let (spent, received) = t.swap(&usdc(), &wbtc(), 50.0, Rate(0.0), 0.0);
        assert_eq!(spent, 0.0);
        assert_eq!(received, 0.0);
        assert_eq!(t.balance(&usdc()), 100.0);
    }

    #[test]
    fn claim_moves_balance_to_deployed() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 1000.0);
        let claimed = t.claim(&usdc(), 400.0);
        assert_eq!(claimed, 400.0);
        assert_eq!(t.balance(&usdc()), 600.0);
        assert_eq!(t.deployed(&usdc()), 400.0);
        assert_eq!(t.total(&usdc()), 1000.0);
    }

    #[test]
    fn claim_capped_at_balance() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 100.0);
        let claimed = t.claim(&usdc(), 999.0);
        assert_eq!(claimed, 100.0);
        assert_eq!(t.balance(&usdc()), 0.0);
        assert_eq!(t.deployed(&usdc()), 100.0);
    }

    #[test]
    fn release_moves_deployed_to_balance() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 1000.0);
        t.claim(&usdc(), 600.0);
        t.release(&usdc(), 200.0);
        assert_eq!(t.balance(&usdc()), 600.0);   // 400 + 200
        assert_eq!(t.deployed(&usdc()), 400.0);   // 600 - 200
    }

    #[test]
    fn release_capped_at_deployed() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 100.0);
        t.claim(&usdc(), 50.0);
        t.release(&usdc(), 999.0);
        assert_eq!(t.balance(&usdc()), 100.0);
        assert_eq!(t.deployed(&usdc()), 0.0);
    }

    #[test]
    fn rate_newtype_used_in_swap() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 50000.0);
        // Rate(50000) means 50000 USDC per BTC
        let (_, received) = t.swap(&usdc(), &wbtc(), 50000.0, Rate(50000.0), 0.0);
        assert!((received - 1.0).abs() < 1e-10); // exactly 1 BTC
    }

    #[test]
    fn total_value_sums_across_assets_at_given_prices() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 5000.0);
        t.deposit(&wbtc(), 0.1);
        t.claim(&wbtc(), 0.05); // 0.05 in balance, 0.05 deployed

        let prices = price_map(60000.0);
        // USDC: 5000 * 1.0 = 5000
        // WBTC balance: 0.05 * 60000 = 3000
        // WBTC deployed: 0.05 * 60000 = 3000
        let expected = 5000.0 + 3000.0 + 3000.0;
        assert!((t.total_value(&prices) - expected).abs() < 1e-10);
    }

    #[test]
    fn asset_as_str_returns_name() {
        let a = Asset::new("WBTC");
        assert_eq!(a.as_str(), "WBTC");
    }

    #[test]
    fn asset_display_formats_name() {
        let a = Asset::new("USDC");
        assert_eq!(format!("{}", a), "USDC");
    }

    #[test]
    fn deployed_returns_zero_for_unknown_asset() {
        let t = Treasury::new(5, 0.5);
        assert_eq!(t.deployed(&wbtc()), 0.0);
    }

    #[test]
    fn allocatable_respects_max_positions() {
        let mut t = Treasury::new(2, 0.8);
        t.deposit(&usdc(), 10000.0);
        let prices = price_map(50000.0);
        // n_open == max_positions → no room
        assert_eq!(t.allocatable(&usdc(), &prices, 2), 0.0);
        // n_open < max_positions → some room
        assert!(t.allocatable(&usdc(), &prices, 0) > 0.0);
    }

    #[test]
    fn allocatable_respects_utilization_limit() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 10000.0);
        let prices = price_map(50000.0);
        // With 0 deployed, room = 10000 * 0.5 = 5000, but balance is 10000 → capped at 5000
        let alloc = t.allocatable(&usdc(), &prices, 0);
        assert!((alloc - 5000.0).abs() < 1e-6);
    }

    #[test]
    fn allocatable_accounts_for_deployed() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 10000.0);
        t.claim(&usdc(), 4000.0); // 4000 deployed, 6000 available
        let prices = price_map(50000.0);
        // total value = 10000, max deployed = 5000, already deployed 4000 → room = 1000
        let alloc = t.allocatable(&usdc(), &prices, 1);
        assert!((alloc - 1000.0).abs() < 1e-6);
    }

    #[test]
    fn allocatable_converts_to_asset_units() {
        let mut t = Treasury::new(5, 0.8);
        t.deposit(&usdc(), 10000.0);
        t.deposit(&wbtc(), 0.1);
        let prices = price_map(50000.0);
        // total value = 10000 + 0.1*50000 = 15000
        // max deploy = 15000 * 0.8 = 12000
        // deploy_room in USD = 12000 - 0 = 12000
        // in WBTC units = 12000 / 50000 = 0.24, but only 0.1 available → 0.1
        let alloc = t.allocatable(&wbtc(), &prices, 0);
        assert!((alloc - 0.1).abs() < 1e-10);
    }

    #[test]
    fn allocatable_zero_portfolio_value() {
        let t = Treasury::new(5, 0.5);
        let prices = price_map(50000.0);
        assert_eq!(t.allocatable(&usdc(), &prices, 0), 0.0);
    }

    #[test]
    fn utilization_with_no_deployed() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 10000.0);
        let prices = price_map(50000.0);
        assert_eq!(t.utilization(&prices), 0.0);
    }

    #[test]
    fn utilization_fraction_of_deployed() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 10000.0);
        t.claim(&usdc(), 2500.0);
        let prices = price_map(50000.0);
        // deployed = 2500, total = 10000 → 0.25
        assert!((t.utilization(&prices) - 0.25).abs() < 1e-10);
    }

    #[test]
    fn utilization_zero_total_value() {
        let t = Treasury::new(5, 0.5);
        let prices = price_map(50000.0);
        assert_eq!(t.utilization(&prices), 0.0);
    }

    #[test]
    fn swap_from_empty_asset_returns_zero() {
        let mut t = Treasury::new(5, 0.5);
        // no deposits at all
        let (spent, received) = t.swap(&usdc(), &wbtc(), 100.0, Rate(50000.0), 0.01);
        assert_eq!(spent, 0.0);
        assert_eq!(received, 0.0);
    }

    #[test]
    fn claim_zero_returns_zero() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 100.0);
        let claimed = t.claim(&usdc(), 0.0);
        assert_eq!(claimed, 0.0);
        assert_eq!(t.balance(&usdc()), 100.0);
        assert_eq!(t.deployed(&usdc()), 0.0);
    }

    #[test]
    fn release_on_undeployed_asset_is_noop() {
        let mut t = Treasury::new(5, 0.5);
        t.deposit(&usdc(), 100.0);
        // release without claiming first
        t.release(&usdc(), 50.0);
        assert_eq!(t.balance(&usdc()), 100.0);
        assert_eq!(t.deployed(&usdc()), 0.0);
    }
}
