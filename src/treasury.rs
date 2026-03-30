use std::collections::HashMap;

// ─── Treasury ────────────────────────────────────────────────────────────────
// The treasury is a map of what we hold. Not a dollar amount — a portfolio.
// Each asset has a balance. Trades convert between assets (USDC → WBTC → USDC).
// The risk managers read this to see total exposure, concentration, liquidity.
// Pure accounting. No predictions. No thoughts. A ledger.

pub struct Treasury {
    pub balances:         HashMap<String, f64>,  // asset → amount (e.g. "USDC" → 10000.0, "WBTC" → 0.15)
    pub deployed:         HashMap<String, f64>,  // asset → amount locked in active positions
    pub n_open:           usize,                 // number of active positions
    pub max_positions:    usize,
    pub max_utilization:  f64,                   // max fraction of base asset deployed
    pub total_fees_paid:  f64,
    pub total_slippage:   f64,
    pub base_asset:       String,                // quote currency for P&L (e.g. "USDC")
}

impl Treasury {
    pub fn new(base_asset: &str, initial_amount: f64, max_positions: usize, max_utilization: f64) -> Self {
        let mut balances = HashMap::new();
        balances.insert(base_asset.to_string(), initial_amount);
        Self {
            balances,
            deployed: HashMap::new(),
            n_open: 0,
            max_positions,
            max_utilization,
            total_fees_paid: 0.0,
            total_slippage: 0.0,
            base_asset: base_asset.to_string(),
        }
    }

    /// Deposit capital into the treasury.
    pub fn deposit(&mut self, asset: &str, amount: f64) {
        *self.balances.entry(asset.to_string()).or_insert(0.0) += amount;
    }

    /// Withdraw capital from available balance. Cannot touch deployed.
    pub fn withdraw(&mut self, asset: &str, amount: f64) {
        let bal = self.balances.entry(asset.to_string()).or_insert(0.0);
        *bal = (*bal - amount).max(0.0);
    }

    /// Balance of an asset (available, not deployed).
    pub fn balance(&self, asset: &str) -> f64 {
        *self.balances.get(asset).unwrap_or(&0.0)
    }

    /// Amount of an asset locked in active positions.
    pub fn deployed(&self, asset: &str) -> f64 {
        *self.deployed.get(asset).unwrap_or(&0.0)
    }

    /// Total holdings of an asset (available + deployed).
    pub fn total(&self, asset: &str) -> f64 {
        self.balance(asset) + self.deployed(asset)
    }

    /// How much of the base asset can be allocated to a new position?
    pub fn allocatable(&self) -> f64 {
        if self.n_open >= self.max_positions { return 0.0; }
        let total_base = self.total(&self.base_asset);
        let max_deploy = total_base * self.max_utilization;
        let deployed_base = self.deployed(&self.base_asset);
        let room = (max_deploy - deployed_base).max(0.0);
        room.min(self.balance(&self.base_asset))
    }

    /// Reserve base asset for a new trade. Returns the amount reserved.
    pub fn open_position(&mut self, amount: f64) -> f64 {
        let available = self.allocatable();
        let reserved = amount.min(available);
        if reserved <= 0.0 { return 0.0; }
        *self.balances.get_mut(&self.base_asset).unwrap() -= reserved;
        *self.deployed.entry(self.base_asset.clone()).or_insert(0.0) += reserved;
        self.n_open += 1;
        reserved
    }

    /// Close a position. Return capital ± P&L to available balance.
    pub fn close_position(&mut self, deployed_amount: f64, pnl: f64, fees: f64, slippage: f64) {
        let returned = (deployed_amount + pnl - fees - slippage).max(0.0);
        let dep = self.deployed.entry(self.base_asset.clone()).or_insert(0.0);
        *dep = (*dep - deployed_amount).max(0.0);
        *self.balances.entry(self.base_asset.clone()).or_insert(0.0) += returned;
        self.n_open = self.n_open.saturating_sub(1);
        self.total_fees_paid += fees;
        self.total_slippage += slippage;
    }

    /// Portfolio utilization: fraction of base asset currently deployed.
    pub fn utilization(&self) -> f64 {
        let total = self.total(&self.base_asset);
        if total <= 0.0 { return 0.0; }
        self.deployed(&self.base_asset) / total
    }

    /// Claim assets for a position. Moves from available balance to deployed.
    /// Returns the amount actually claimed (may be less than requested).
    pub fn claim(&mut self, asset: &str, amount: f64) -> f64 {
        let available = self.balance(asset);
        let claimed = amount.min(available);
        if claimed <= 0.0 { return 0.0; }
        *self.balances.get_mut(asset).unwrap() -= claimed;
        *self.deployed.entry(asset.to_string()).or_insert(0.0) += claimed;
        self.n_open += 1;
        claimed
    }

    /// Release assets from a position. Moves from deployed back to available.
    pub fn release(&mut self, asset: &str, amount: f64) {
        let dep = self.deployed.entry(asset.to_string()).or_insert(0.0);
        let released = amount.min(*dep);
        *dep -= released;
        *self.balances.entry(asset.to_string()).or_insert(0.0) += released;
        if self.n_open > 0 { self.n_open -= 1; }
    }

    /// Swap one asset for another at a given price, minus fees.
    /// `from` asset is sold, `to` asset is bought.
    /// `price` = how many units of `from` per unit of `to` (e.g. 87000 USDC per WBTC).
    /// `fee_rate` = fraction taken per swap (e.g. 0.0035 = 35bps).
    /// Returns (from_amount_spent, to_amount_received).
    pub fn swap(
        &mut self,
        from: &str,
        to: &str,
        amount_from: f64,
        price: f64,
        fee_rate: f64,
    ) -> (f64, f64) {
        let available = self.balance(from);
        let spend = amount_from.min(available);
        if spend <= 0.0 || price <= 0.0 { return (0.0, 0.0); }

        let after_fee = spend * (1.0 - fee_rate);
        let received = after_fee / price; // convert from → to at price
        let fee_amount = spend * fee_rate;

        *self.balances.entry(from.to_string()).or_insert(0.0) -= spend;
        *self.balances.entry(to.to_string()).or_insert(0.0) += received;
        self.total_fees_paid += fee_amount;

        (spend, received)
    }

    /// Total portfolio value in a given denomination.
    /// Build a price map from asset prices. Base asset is always 1.0.
    /// For single-asset: pass one price for the non-base asset.
    /// For multi-asset: each desk provides its asset's price.
    pub fn price_map(&self, asset_prices: &[(&str, f64)]) -> HashMap<String, f64> {
        let mut prices = HashMap::new();
        prices.insert(self.base_asset.clone(), 1.0);
        for &(asset, price) in asset_prices {
            prices.insert(asset.to_string(), price);
        }
        prices
    }

    /// Requires a price map: asset → price_in_base_asset.
    pub fn total_value(&self, prices: &HashMap<String, f64>) -> f64 {
        let mut total = 0.0;
        for (asset, &bal) in &self.balances {
            let price = prices.get(asset).copied().unwrap_or(1.0); // base asset = 1.0
            total += bal * price;
        }
        for (asset, &dep) in &self.deployed {
            let price = prices.get(asset).copied().unwrap_or(1.0);
            total += dep * price;
        }
        total
    }
}
