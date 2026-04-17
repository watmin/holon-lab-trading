use std::sync::Arc;
/// rhythm.rs — the generic indicator rhythm function.
///
/// One function. Three callers: market observer, regime observer, broker-observer.
/// Takes a window of values, builds trigrams, bigram-pairs, bundles them.
/// Returns one ThoughtAST — the full tree. The encode function walks it.
///
/// The atom wraps the WHOLE rhythm, not each candle's fact. Proposal 056.

use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, ThoughtASTKind};

/// Spec for a continuous indicator. The lens returns a list of these.
/// The extractor pulls one f64 from a Candle. The bounds are from the
/// indicator's nature — RSI [0,100], ATR ratio [0,0.05], etc.
pub struct IndicatorSpec {
    pub atom_name: &'static str,
    pub extractor: fn(&Candle) -> f64,
    pub value_min: f64,
    pub value_max: f64,
    pub delta_range: f64,
}

/// Build all indicator rhythm ASTs from a window of candles using specs.
/// Returns a Vec of ThoughtAST — one per spec. The caller bundles.
pub fn build_rhythm_asts(
    window: &[Candle],
    specs: &[IndicatorSpec],
) -> Vec<ThoughtAST> {
    specs.iter().map(|spec| {
        let values: Vec<f64> = window.iter().map(|c| (spec.extractor)(c)).collect();
        indicator_rhythm(
            spec.atom_name, &values,
            spec.value_min, spec.value_max, spec.delta_range,
        )
    }).collect()
}

/// Build one indicator rhythm AST from a series of values.
/// Thermometer encoding for values. Thermometer encoding for deltas.
/// Atom wraps the final rhythm — one bind, not N.
///
/// Returns a ThoughtAST. The encode function walks it.
pub fn indicator_rhythm(
    atom_name: &str,
    values: &[f64],
    value_min: f64,
    value_max: f64,
    delta_range: f64,
) -> ThoughtAST {
    if values.len() < 4 {
        return ThoughtAST::new(ThoughtASTKind::Bundle(vec![]));
    }

    // Trim input to only the candles that will survive the pair budget.
    // budget pairs → budget+1 trigrams → budget+3 facts.
    // Building more facts wastes AST nodes that get thrown away.
    let budget = ((10_000 as f64).sqrt()) as usize; // rune:forge(dims) — needs dims param
    let max_facts = budget + 3;
    let values = if values.len() > max_facts {
        &values[values.len() - max_facts..]
    } else {
        values
    };

    // Step 1: each value → thermometer + delta from previous
    let facts: Vec<ThoughtAST> = values
        .iter()
        .enumerate()
        .map(|(i, &val)| {
            let v = ThoughtAST::new(ThoughtASTKind::Thermometer { value: val, min: value_min, max: value_max });
            if i == 0 {
                v
            } else {
                let delta = val - values[i - 1];
                ThoughtAST::new(ThoughtASTKind::Bundle(vec![
                    v,
                    ThoughtAST::new(ThoughtASTKind::Bind(
                        Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("delta".into()))),
                        Arc::new(ThoughtAST::new(ThoughtASTKind::Thermometer { value: delta, min: -delta_range, max: delta_range })),
                    )),
                ]))
            }
        })
        .collect();

    // Step 2: trigrams — sliding window of 3
    let trigrams: Vec<ThoughtAST> = facts
        .windows(3)
        .map(|w| {
            ThoughtAST::new(ThoughtASTKind::Bind(
                Arc::new(ThoughtAST::new(ThoughtASTKind::Bind(
                    Arc::new(w[0].clone()),
                    Arc::new(ThoughtAST::new(ThoughtASTKind::Permute(Arc::new(w[1].clone()), 1))),
                ))),
                Arc::new(ThoughtAST::new(ThoughtASTKind::Permute(Arc::new(w[2].clone()), 2))),
            ))
        })
        .collect();

    // Step 3: bigram-pairs — sliding window of 2 trigrams
    let pairs: Vec<ThoughtAST> = trigrams
        .windows(2)
        .map(|w| {
            ThoughtAST::new(ThoughtASTKind::Bind(
                Arc::new(w[0].clone()),
                Arc::new(w[1].clone()),
            ))
        })
        .collect();

    if pairs.is_empty() {
        return ThoughtAST::new(ThoughtASTKind::Bundle(vec![]));
    }

    // Step 4: trim to capacity, bundle
    let budget = ((10_000 as f64).sqrt()) as usize; // rune:forge(dims) — needs dims param when available
    let start = if pairs.len() > budget { pairs.len() - budget } else { 0 };
    let trimmed: Vec<ThoughtAST> = pairs[start..].to_vec();
    let raw = ThoughtAST::new(ThoughtASTKind::Bundle(trimmed));

    // Step 5: bind atom to the whole rhythm — one bind
    ThoughtAST::new(ThoughtASTKind::Bind(
        Arc::new(ThoughtAST::new(ThoughtASTKind::Atom(atom_name.into()))),
        Arc::new(raw),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use holon::kernel::similarity::Similarity;
    use holon::kernel::vector_manager::VectorManager;
    use crate::encoding::thought_encoder::ThoughtEncoder;

    const DIMS: usize = 10_000;

    fn enc(ast: &ThoughtAST) -> holon::kernel::vector::Vector {
        let vm = VectorManager::new(DIMS);
        let encoder = ThoughtEncoder::new(vm);
        encoder.encode(ast)
    }

    #[test]
    fn deterministic() {
        let values = vec![0.45, 0.48, 0.55, 0.62, 0.68, 0.66, 0.63];

        let ast1 = indicator_rhythm("rsi", &values, 0.0, 100.0, 10.0);
        let ast2 = indicator_rhythm("rsi", &values, 0.0, 100.0, 10.0);

        let v1 = enc(&ast1);
        let v2 = enc(&ast2);

        let cos = Similarity::cosine(&v1, &v2);
        assert!((cos - 1.0).abs() < 1e-6, "same input must produce identical vector, got {}", cos);
    }

    #[test]
    fn different_atoms_orthogonal() {
        let values = vec![0.45, 0.48, 0.55, 0.62, 0.68, 0.66, 0.63];

        let rsi_ast = indicator_rhythm("rsi", &values, 0.0, 100.0, 10.0);
        let macd_ast = indicator_rhythm("macd", &values, 0.0, 100.0, 10.0);

        let rsi = enc(&rsi_ast);
        let macd = enc(&macd_ast);

        let cos = Similarity::cosine(&rsi, &macd);
        assert!(cos.abs() < 0.15, "different atoms should be near-orthogonal, got {}", cos);
    }

    #[test]
    fn ast_is_inspectable() {
        let values = vec![0.45, 0.48, 0.55, 0.62, 0.68];
        let ast = indicator_rhythm("rsi", &values, 0.0, 100.0, 10.0);

        match &ast.kind {
            ThoughtASTKind::Bind(left, _right) => {
                match &left.kind {
                    ThoughtASTKind::Atom(name) => assert_eq!(name, "rsi"),
                    other => panic!("expected Atom, got {:?}", other),
                }
            }
            other => panic!("expected Bind, got {:?}", other),
        }

        let edn = ast.to_edn();
        assert!(edn.contains("rsi"), "EDN should contain atom name");
        assert!(edn.contains("thermometer"), "EDN should contain thermometer");
        assert!(edn.contains("permute"), "EDN should contain permute");
    }

    #[test]
    fn too_few_values_returns_empty_bundle() {
        let values = vec![0.5, 0.6];
        let ast = indicator_rhythm("rsi", &values, 0.0, 100.0, 10.0);
        match &ast.kind {
            ThoughtASTKind::Bundle(v) => assert!(v.is_empty()),
            _ => panic!("expected empty Bundle"),
        }
    }
}
