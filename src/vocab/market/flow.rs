// vocab/market/flow.rs — compiled from wat/vocab/market/flow.wat
//
// Volume and pressure. Pure function: candle in, ASTs out.
// atoms: obv-slope, vwap-distance, buying-pressure, selling-pressure,
//        volume-ratio, body-ratio

use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, ToAst, round_to};

pub struct FlowThought {
    pub obv_slope: f64,
    pub vwap_distance: f64,
    pub buying_pressure: f64,
    pub selling_pressure: f64,
    pub volume_ratio: f64,
    pub body_ratio: f64,
}

impl FlowThought {
    pub fn from_candle(c: &Candle) -> Self {
        let range = c.high - c.low;
        let body = c.close - c.open;
        let abs_body = body.abs();
        Self {
            obv_slope: round_to(c.obv_slope_12.exp(), 2),
            vwap_distance: round_to(c.vwap_distance, 4),
            buying_pressure: round_to(if range > 0.0 { (c.close - c.low) / range } else { 0.5 }, 2),
            selling_pressure: round_to(if range > 0.0 { (c.high - c.close) / range } else { 0.5 }, 2),
            volume_ratio: round_to(c.volume_accel.exp().max(0.001), 2),
            body_ratio: round_to(if range > 0.0 { abs_body / range } else { 0.0 }, 2),
        }
    }
}

impl ToAst for FlowThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Log { name: "obv-slope".into(), value: self.obv_slope },
            ThoughtAST::Linear { name: "vwap-distance".into(), value: self.vwap_distance, scale: 0.1 },
            ThoughtAST::Linear { name: "buying-pressure".into(), value: self.buying_pressure, scale: 1.0 },
            ThoughtAST::Linear { name: "selling-pressure".into(), value: self.selling_pressure, scale: 1.0 },
            ThoughtAST::Log { name: "volume-ratio".into(), value: self.volume_ratio },
            ThoughtAST::Linear { name: "body-ratio".into(), value: self.body_ratio, scale: 1.0 },
        ]
    }
}

pub fn encode_flow_facts(c: &Candle) -> Vec<ThoughtAST> {
    FlowThought::from_candle(c).forms()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_flow_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_flow_facts(&c);
        assert_eq!(facts.len(), 6);
    }

    #[test]
    fn test_buying_pressure_default() {
        let c = Candle::default();
        let facts = encode_flow_facts(&c);
        match &facts[2] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "buying-pressure");
                // (42200 - 41500) / (42500 - 41500) = 700/1000 = 0.7
                assert!((value - 0.7).abs() < 1e-9);
            }
            _ => panic!("expected Linear"),
        }
    }
}
