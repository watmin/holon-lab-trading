// rune:forge(bare-type) — amount, fee_rate, price are all bare f64.
// Newtypes (Rate, FeeRate) would prevent swap(price) vs swap(1/price) errors.
// Deferred: requires API change across treasury, desk, position, enterprise.
// The symmetric position model (rate going up = good) reduces the risk.

use std::collections::HashMap;
use std::fmt;

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

    /// Swap one token for another at a given price, minus fees.
    /// `price` = how many units of `from` per unit of `to`.
    /// Returns (from_amount_spent, to_amount_received).
    pub fn swap(
        &mut self,
        from: &Asset,
        to: &Asset,
        amount_from: f64,
        price: f64,
        fee_rate: f64,
    ) -> (f64, f64) {
        let available = self.balance(from);
        let spend = amount_from.min(available);
        if spend <= 0.0 || price <= 0.0 { return (0.0, 0.0); }

        let after_fee = spend * (1.0 - fee_rate);
        let received = after_fee / price;
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
