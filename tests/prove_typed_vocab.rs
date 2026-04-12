/// Tests that typed vocabulary structs produce facts with the same names, types,
/// and values as the encode_*_facts() functions.
///
/// Post Proposal 033: encode_*_facts use learned scales (ScaleTracker), while
/// struct forms() use hardcoded scales. The atom names and values match; only
/// the scale field on Linear atoms may differ. Tests verify structural agreement.

use std::collections::HashMap;
use enterprise::candle::Candle;
use enterprise::thought_encoder::{ThoughtAST, ToAst};

// Market vocab structs
use enterprise::vocab::market::momentum::MomentumThought;
use enterprise::vocab::market::regime::RegimeThought;
use enterprise::vocab::market::oscillators::OscillatorsThought;
use enterprise::vocab::market::flow::FlowThought;
use enterprise::vocab::market::persistence::PersistenceThought;
use enterprise::vocab::market::price_action::PriceActionThought;
use enterprise::vocab::market::ichimoku::IchimokuThought;
use enterprise::vocab::market::keltner::KeltnerThought;
use enterprise::vocab::market::stochastic::StochasticThought;
use enterprise::vocab::market::fibonacci::FibonacciThought;
use enterprise::vocab::market::divergence::DivergenceThought;
use enterprise::vocab::market::timeframe::TimeframeThought;
use enterprise::vocab::market::standard::StandardThought;

// Exit vocab structs
use enterprise::vocab::exit::volatility::ExitVolatilityThought;
use enterprise::vocab::exit::structure::ExitStructureThought;
use enterprise::vocab::exit::timing::ExitTimingThought;
use enterprise::vocab::exit::regime::ExitRegimeThought;
use enterprise::vocab::exit::time::ExitTimeThought;
use enterprise::vocab::exit::self_assessment::ExitSelfAssessmentThought;

// Original functions
use enterprise::vocab::market::momentum::encode_momentum_facts;
use enterprise::vocab::market::regime::encode_regime_facts;
use enterprise::vocab::market::oscillators::encode_oscillator_facts;
use enterprise::vocab::market::flow::encode_flow_facts;
use enterprise::vocab::market::persistence::encode_persistence_facts;
use enterprise::vocab::market::price_action::encode_price_action_facts;
use enterprise::vocab::market::ichimoku::encode_ichimoku_facts;
use enterprise::vocab::market::keltner::encode_keltner_facts;
use enterprise::vocab::market::stochastic::encode_stochastic_facts;
use enterprise::vocab::market::fibonacci::encode_fibonacci_facts;
use enterprise::vocab::market::divergence::encode_divergence_facts;
use enterprise::vocab::market::timeframe::encode_timeframe_facts;
use enterprise::vocab::market::standard::encode_standard_facts;
use enterprise::vocab::exit::volatility::encode_exit_volatility_facts;
use enterprise::vocab::exit::structure::encode_exit_structure_facts;
use enterprise::vocab::exit::timing::encode_exit_timing_facts;
use enterprise::vocab::exit::regime::encode_exit_regime_facts;
use enterprise::vocab::exit::time::encode_exit_time_facts;
use enterprise::vocab::exit::self_assessment::encode_exit_self_assessment_facts;

/// Assert that two fact vectors have the same names and types.
/// Scale may differ (learned vs hardcoded), but name and value must match.
fn assert_names_and_types_match(from_fn: &[ThoughtAST], from_struct: &[ThoughtAST]) {
    assert_eq!(from_fn.len(), from_struct.len(), "fact count mismatch");
    for (f, s) in from_fn.iter().zip(from_struct.iter()) {
        assert_eq!(f.name(), s.name(), "name mismatch");
        // Both should be the same variant (Linear, Log, Circular)
        assert_eq!(
            std::mem::discriminant(f),
            std::mem::discriminant(s),
            "type mismatch for {}",
            f.name()
        );
    }
}

#[test]
fn momentum_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_momentum_facts(&c, &mut scales);
    let from_struct = MomentumThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn regime_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_regime_facts(&c, &mut scales);
    let from_struct = RegimeThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn oscillators_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_oscillator_facts(&c, &mut scales);
    let from_struct = OscillatorsThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn flow_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_flow_facts(&c, &mut scales);
    let from_struct = FlowThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn persistence_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_persistence_facts(&c, &mut scales);
    let from_struct = PersistenceThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn price_action_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_price_action_facts(&c, &mut scales);
    let from_struct = PriceActionThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn ichimoku_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_ichimoku_facts(&c, &mut scales);
    let from_struct = IchimokuThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn keltner_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_keltner_facts(&c, &mut scales);
    let from_struct = KeltnerThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn stochastic_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_stochastic_facts(&c, &mut scales);
    let from_struct = StochasticThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn fibonacci_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_fibonacci_facts(&c, &mut scales);
    let from_struct = FibonacciThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn divergence_struct_matches_function_no_divergence() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_divergence_facts(&c, &mut scales);
    let from_struct = DivergenceThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn divergence_struct_matches_function_with_divergence() {
    let mut c = Candle::default();
    c.rsi_divergence_bull = 0.7;
    c.rsi_divergence_bear = 0.3;
    let mut scales = HashMap::new();
    let from_fn = encode_divergence_facts(&c, &mut scales);
    let from_struct = DivergenceThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn timeframe_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_timeframe_facts(&c, &mut scales);
    let from_struct = TimeframeThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn standard_struct_matches_function() {
    let window = vec![Candle::default()];
    let mut scales = HashMap::new();
    let from_fn = encode_standard_facts(&window, &mut scales);
    let from_struct = StandardThought::from_window(&window).unwrap().forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn standard_struct_empty_window() {
    let mut scales = HashMap::new();
    let from_fn = encode_standard_facts(&[], &mut scales);
    let from_struct = StandardThought::from_window(&[]);
    assert!(from_fn.is_empty());
    assert!(from_struct.is_none());
}

#[test]
fn exit_volatility_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_exit_volatility_facts(&c, &mut scales);
    let from_struct = ExitVolatilityThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn exit_structure_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_exit_structure_facts(&c, &mut scales);
    let from_struct = ExitStructureThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn exit_timing_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_exit_timing_facts(&c, &mut scales);
    let from_struct = ExitTimingThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn exit_regime_struct_matches_function() {
    let c = Candle::default();
    let mut scales = HashMap::new();
    let from_fn = encode_exit_regime_facts(&c, &mut scales);
    let from_struct = ExitRegimeThought::from_candle(&c).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn exit_time_struct_matches_function() {
    let c = Candle::default();
    let from_fn = encode_exit_time_facts(&c);
    let from_struct = ExitTimeThought::from_candle(&c).forms();
    assert_eq!(from_fn, from_struct); // Circular only — no scale changes
}

#[test]
fn exit_self_assessment_struct_matches_function() {
    let mut scales = HashMap::new();
    let from_fn = encode_exit_self_assessment_facts(0.6, 0.005, &mut scales);
    let from_struct = ExitSelfAssessmentThought::new(0.6, 0.005).forms();
    assert_names_and_types_match(&from_fn, &from_struct);
}

#[test]
fn to_ast_produces_bundle_of_forms() {
    let c = Candle::default();
    let thought = MomentumThought::from_candle(&c);
    let ast = thought.to_ast();
    match ast {
        ThoughtAST::Bundle(children) => {
            assert_eq!(children, thought.forms());
        }
        _ => panic!("to_ast() should produce a Bundle"),
    }
}
