/// Typed inputs for the broker thread. The compiler enforces that the broker
/// receives the RIGHT ASTs — you can't pass the wrong stage's data.
///
/// Each struct binds an AST to its anomaly vector. The extraction method
/// lives on the struct, so you can't accidentally extract market facts
/// from the exit anomaly or vice versa.

use holon::kernel::vector::Vector;

use crate::encoding::thought_encoder::{collect_facts, extract, ThoughtAST};

/// Market-stage input: the AST and anomaly from a market observer.
pub struct BrokerMarketInput {
    pub ast: ThoughtAST,
    pub anomaly: Vector,
}

/// Exit-stage input: the AST and anomaly from an exit observer.
pub struct BrokerExitInput {
    pub ast: ThoughtAST,
    pub anomaly: Vector,
}

impl BrokerMarketInput {
    /// Extract the facts present in the market anomaly above the noise floor.
    /// The encode_fn handles caching internally — no misses to propagate.
    pub fn extract_facts<F>(&self, encode_fn: F, noise_floor: f64) -> Vec<ThoughtAST>
    where
        F: Fn(&ThoughtAST) -> Vector,
    {
        let facts = collect_facts(&self.ast);
        let extracted = extract(&self.anomaly, &facts, encode_fn);
        extracted
            .into_iter()
            .filter(|(_, cos)| cos.abs() > noise_floor)
            .map(|(ast, _)| ast)
            .collect()
    }
}

impl BrokerExitInput {
    /// Extract the facts present in the exit anomaly above the noise floor.
    /// The encode_fn handles caching internally — no misses to propagate.
    pub fn extract_facts<F>(&self, encode_fn: F, noise_floor: f64) -> Vec<ThoughtAST>
    where
        F: Fn(&ThoughtAST) -> Vector,
    {
        let facts = collect_facts(&self.ast);
        let extracted = extract(&self.anomaly, &facts, encode_fn);
        extracted
            .into_iter()
            .filter(|(_, cos)| cos.abs() > noise_floor)
            .map(|(ast, _)| ast)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encoding::thought_encoder::ThoughtEncoder;
    use holon::kernel::vector_manager::VectorManager;

    const DIMS: usize = 4096;

    fn make_encoder() -> ThoughtEncoder {
        let vm = VectorManager::new(DIMS);
        ThoughtEncoder::new(vm)
    }

    #[test]
    fn test_broker_market_input_extract_facts() {
        let encoder = make_encoder();

        // Build an AST with known facts
        let facts = vec![
            ThoughtAST::linear("rsi", 0.7, 1.0),
            ThoughtAST::log("vol", 100.0),
            ThoughtAST::linear("trend", 0.3, 1.0),
        ];
        let ast = ThoughtAST::Bundle(facts);

        // Encode the AST to get the anomaly vector
        let (anomaly, _) = encoder.encode(&ast);

        let input = BrokerMarketInput {
            ast: ast.clone(),
            anomaly,
        };

        let extracted = input.extract_facts(|a| encoder.encode(a).0, 0.0);
        // All three facts should be present (self-cosine is high)
        assert_eq!(extracted.len(), 3);
    }

    #[test]
    fn test_broker_market_input_noise_floor_filters() {
        let encoder = make_encoder();

        let facts = vec![
            ThoughtAST::linear("rsi", 0.7, 1.0),
            ThoughtAST::log("vol", 100.0),
        ];
        let ast = ThoughtAST::Bundle(facts);
        let (anomaly, _) = encoder.encode(&ast);

        let input = BrokerMarketInput {
            ast: ast.clone(),
            anomaly,
        };

        // With a very high noise floor, nothing should pass
        let extracted = input.extract_facts(|a| encoder.encode(a).0, 0.99);
        assert!(extracted.is_empty());
    }

    #[test]
    fn test_broker_exit_input_extract_facts() {
        let encoder = make_encoder();

        let facts = vec![
            ThoughtAST::linear("trail-distance", 0.015, 1.0),
            ThoughtAST::linear("stop-distance", 0.030, 1.0),
        ];
        let ast = ThoughtAST::Bundle(facts);
        let (anomaly, _) = encoder.encode(&ast);

        let input = BrokerExitInput {
            ast: ast.clone(),
            anomaly,
        };

        let extracted = input.extract_facts(|a| encoder.encode(a).0, 0.0);
        assert_eq!(extracted.len(), 2);
    }
}
