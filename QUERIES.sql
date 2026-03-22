-- QUERIES.sql — Standard analysis queries for run databases
-- Usage: sqlite3 orchestration_results/<name>.db < QUERIES.sql
--    or: sqlite3 <db> "query here"

-- ═══ Conviction Calibration ═══

-- Thought conviction vs accuracy (margin-based conviction)
-- Expect: higher band = higher accuracy (positive calibration)
SELECT '=== Thought Conviction Calibration ===' as '';
SELECT 
  CASE 
    WHEN thought_conviction < 0.01 THEN '<0.01'
    WHEN thought_conviction < 0.03 THEN '0.01-0.03'
    WHEN thought_conviction < 0.05 THEN '0.03-0.05'
    WHEN thought_conviction < 0.10 THEN '0.05-0.10'
    WHEN thought_conviction < 0.20 THEN '0.10-0.20'
    WHEN thought_conviction < 0.30 THEN '0.20-0.30'
    ELSE '0.30+'
  END as band,
  COUNT(*) as trades,
  SUM(CASE WHEN (thought_pred='Buy' AND actual='Buy') OR (thought_pred='Sell' AND actual='Sell') THEN 1 ELSE 0 END) as correct,
  ROUND(100.0*SUM(CASE WHEN (thought_pred='Buy' AND actual='Buy') OR (thought_pred='Sell' AND actual='Sell') THEN 1 ELSE 0 END)/COUNT(*),1) as accuracy
FROM candle_log WHERE thought_pred IS NOT NULL AND actual IS NOT NULL AND actual!='Noise'
GROUP BY band ORDER BY band;

-- Visual conviction vs accuracy
SELECT '=== Visual Conviction Calibration ===' as '';
SELECT 
  CASE 
    WHEN vis_conviction < 0.005 THEN '<0.005'
    WHEN vis_conviction < 0.01 THEN '0.005-0.01'
    WHEN vis_conviction < 0.02 THEN '0.01-0.02'
    WHEN vis_conviction < 0.05 THEN '0.02-0.05'
    WHEN vis_conviction < 0.10 THEN '0.05-0.10'
    ELSE '0.10+'
  END as band,
  COUNT(*) as trades,
  SUM(CASE WHEN (vis_pred='Buy' AND actual='Buy') OR (vis_pred='Sell' AND actual='Sell') THEN 1 ELSE 0 END) as correct,
  ROUND(100.0*SUM(CASE WHEN (vis_pred='Buy' AND actual='Buy') OR (vis_pred='Sell' AND actual='Sell') THEN 1 ELSE 0 END)/COUNT(*),1) as accuracy
FROM candle_log WHERE vis_pred IS NOT NULL AND actual IS NOT NULL AND actual!='Noise'
GROUP BY band ORDER BY band;


-- ═══ Accuracy Over Time ═══

-- Thought accuracy by 10k candle bucket
SELECT '=== Thought Accuracy by 10k Bucket ===' as '';
SELECT 
  (step / 10000) * 10 as bucket_k,
  COUNT(*) as trades,
  SUM(CASE WHEN (thought_pred='Buy' AND actual='Buy') OR (thought_pred='Sell' AND actual='Sell') THEN 1 ELSE 0 END) as correct,
  ROUND(100.0*SUM(CASE WHEN (thought_pred='Buy' AND actual='Buy') OR (thought_pred='Sell' AND actual='Sell') THEN 1 ELSE 0 END)/COUNT(*),1) as accuracy
FROM candle_log WHERE thought_pred IS NOT NULL AND actual IS NOT NULL AND actual!='Noise'
GROUP BY bucket_k ORDER BY bucket_k;

-- Visual accuracy by 10k candle bucket
SELECT '=== Visual Accuracy by 10k Bucket ===' as '';
SELECT 
  (step / 10000) * 10 as bucket_k,
  COUNT(*) as trades,
  SUM(CASE WHEN (vis_pred='Buy' AND actual='Buy') OR (vis_pred='Sell' AND actual='Sell') THEN 1 ELSE 0 END) as correct,
  ROUND(100.0*SUM(CASE WHEN (vis_pred='Buy' AND actual='Buy') OR (vis_pred='Sell' AND actual='Sell') THEN 1 ELSE 0 END)/COUNT(*),1) as accuracy
FROM candle_log WHERE vis_pred IS NOT NULL AND actual IS NOT NULL AND actual!='Noise'
GROUP BY bucket_k ORDER BY bucket_k;


-- ═══ Prototype Health ═══

-- Recalibration log: prototype separation and sample counts over time
-- Watch for: cos_buy_sell rising toward 1.0, sample counts exploding
SELECT '=== Prototype Health (Recalib Log) ===' as '';
SELECT 
  step, system, 
  ROUND(cos_buy_sell, 4) as cos,
  buy_count, sell_count, 
  confuser_buy_count as conf_buy, confuser_sell_count as conf_sell
FROM recalib_log ORDER BY system, step;


-- ═══ Prediction Balance ═══

-- Direction balance by 10k bucket (detect skew from prototype convergence)
SELECT '=== Thought Direction Balance by 10k Bucket ===' as '';
SELECT 
  (step / 10000) * 10 as bucket_k,
  SUM(CASE WHEN thought_pred='Buy' THEN 1 ELSE 0 END) as buys,
  SUM(CASE WHEN thought_pred='Sell' THEN 1 ELSE 0 END) as sells,
  ROUND(100.0*SUM(CASE WHEN thought_pred='Buy' THEN 1 ELSE 0 END)/COUNT(*),1) as buy_pct
FROM candle_log WHERE thought_pred IS NOT NULL
GROUP BY bucket_k ORDER BY bucket_k;


-- ═══ Sim Distributions ═══

-- Visual sim magnitude bands vs accuracy
SELECT '=== Visual Accuracy by Max Sim Band ===' as '';
SELECT 
  CASE 
    WHEN MAX(ABS(vis_buy_sim), ABS(vis_sell_sim)) < 0.01 THEN '<0.01'
    WHEN MAX(ABS(vis_buy_sim), ABS(vis_sell_sim)) < 0.02 THEN '0.01-0.02'
    WHEN MAX(ABS(vis_buy_sim), ABS(vis_sell_sim)) < 0.03 THEN '0.02-0.03'
    WHEN MAX(ABS(vis_buy_sim), ABS(vis_sell_sim)) < 0.05 THEN '0.03-0.05'
    WHEN MAX(ABS(vis_buy_sim), ABS(vis_sell_sim)) < 0.10 THEN '0.05-0.10'
    ELSE '0.10+'
  END as band,
  COUNT(*) as trades,
  SUM(CASE WHEN (vis_pred='Buy' AND actual='Buy') OR (vis_pred='Sell' AND actual='Sell') THEN 1 ELSE 0 END) as correct,
  ROUND(100.0*SUM(CASE WHEN (vis_pred='Buy' AND actual='Buy') OR (vis_pred='Sell' AND actual='Sell') THEN 1 ELSE 0 END)/COUNT(*),1) as accuracy
FROM candle_log WHERE vis_pred IS NOT NULL AND actual IS NOT NULL AND actual!='Noise'
GROUP BY band ORDER BY band;

-- Near-zero sim rejection rate
SELECT '=== Near-Zero Sim Rejection Rates ===' as '';
SELECT 
  'visual' as system,
  COUNT(CASE WHEN MAX(ABS(vis_buy_sim), ABS(vis_sell_sim)) < 0.03 THEN 1 END) as would_reject,
  COUNT(*) as total,
  ROUND(100.0*COUNT(CASE WHEN MAX(ABS(vis_buy_sim), ABS(vis_sell_sim)) < 0.03 THEN 1 END)/COUNT(*),1) as reject_pct
FROM candle_log WHERE vis_pred IS NOT NULL;


-- ═══ Confuser Impact ═══

-- Confuser flip stats (should be 0 after conviction fix)
SELECT '=== Confuser Flips ===' as '';
SELECT 
  SUM(vis_confuser_flipped) as total_flips,
  COUNT(*) as total_preds,
  ROUND(100.0*SUM(vis_confuser_flipped)/COUNT(*),2) as flip_pct
FROM candle_log WHERE vis_pred IS NOT NULL;


-- ═══ Agreement Signal ═══

-- When thought and visual agree vs disagree
SELECT '=== Agreement vs Accuracy ===' as '';
SELECT 
  CASE WHEN agree=1 THEN 'agree' ELSE 'disagree' END as agreement,
  COUNT(*) as trades,
  SUM(CASE WHEN (vis_pred='Buy' AND actual='Buy') OR (vis_pred='Sell' AND actual='Sell') THEN 1 ELSE 0 END) as vis_correct,
  ROUND(100.0*SUM(CASE WHEN (vis_pred='Buy' AND actual='Buy') OR (vis_pred='Sell' AND actual='Sell') THEN 1 ELSE 0 END)/COUNT(*),1) as vis_acc,
  SUM(CASE WHEN (thought_pred='Buy' AND actual='Buy') OR (thought_pred='Sell' AND actual='Sell') THEN 1 ELSE 0 END) as thought_correct,
  ROUND(100.0*SUM(CASE WHEN (thought_pred='Buy' AND actual='Buy') OR (thought_pred='Sell' AND actual='Sell') THEN 1 ELSE 0 END)/COUNT(*),1) as thought_acc
FROM candle_log 
WHERE vis_pred IS NOT NULL AND thought_pred IS NOT NULL 
  AND actual IS NOT NULL AND actual!='Noise' AND agree IS NOT NULL
GROUP BY agreement;


-- ═══ Summary Stats ═══

SELECT '=== Overall Summary ===' as '';
SELECT 
  COUNT(*) as total_candles,
  SUM(CASE WHEN actual='Buy' THEN 1 ELSE 0 END) as buy_outcomes,
  SUM(CASE WHEN actual='Sell' THEN 1 ELSE 0 END) as sell_outcomes,
  SUM(CASE WHEN actual='Noise' THEN 1 ELSE 0 END) as noise_outcomes,
  SUM(CASE WHEN action IS NOT NULL THEN 1 ELSE 0 END) as trades_taken,
  ROUND(MAX(equity),2) as max_equity,
  ROUND(MIN(CASE WHEN equity > 0 THEN equity END),2) as min_equity
FROM candle_log;
