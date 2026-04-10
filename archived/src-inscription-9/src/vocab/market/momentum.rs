/// SMA-relative, MACD triplet, CCI, DI-spread.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

pub fn encode_momentum_facts(c: &Candle) -> Vec<ThoughtAST> {
    let close = c.close;
    let sma20 = c.sma20;
    let sma50 = c.sma50;
    let sma200 = c.sma200;

    vec![
        // SMA-relative: signed distance as fraction
        ThoughtAST::Linear { name: "close-sma20".into(), value: if sma20 == 0.0 { 0.0 } else { (close - sma20) / sma20 }, scale: 0.1 },
        ThoughtAST::Linear { name: "close-sma50".into(), value: if sma50 == 0.0 { 0.0 } else { (close - sma50) / sma50 }, scale: 0.1 },
        ThoughtAST::Linear { name: "close-sma200".into(), value: if sma200 == 0.0 { 0.0 } else { (close - sma200) / sma200 }, scale: 0.1 },
        // SMA stack: relative positions between averages
        ThoughtAST::Linear { name: "sma20-sma50".into(), value: if sma50 == 0.0 { 0.0 } else { (sma20 - sma50) / sma50 }, scale: 0.1 },
        ThoughtAST::Linear { name: "sma50-sma200".into(), value: if sma200 == 0.0 { 0.0 } else { (sma50 - sma200) / sma200 }, scale: 0.1 },
        // MACD triplet
        ThoughtAST::Linear { name: "macd".into(), value: c.macd, scale: 0.01 },
        ThoughtAST::Linear { name: "macd-signal".into(), value: c.macd_signal, scale: 0.01 },
        ThoughtAST::Linear { name: "macd-hist".into(), value: c.macd_hist, scale: 0.01 },
        // DI spread — signed: positive = bullish, negative = bearish
        ThoughtAST::Linear { name: "di-spread".into(), value: c.plus_di - c.minus_di, scale: 100.0 },
        // CCI as linear with wider scale
        ThoughtAST::Linear { name: "cci".into(), value: c.cci, scale: 300.0 },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_momentum_facts_non_empty() {
        let c = Candle::default();
        let facts = encode_momentum_facts(&c);
        assert!(!facts.is_empty());
        assert_eq!(facts.len(), 10);
    }
}
