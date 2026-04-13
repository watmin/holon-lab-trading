#!/usr/bin/env bash
# Run summary — row counts, candle range, time per namespace
DB="${1:?Usage: $0 <db-path>}"
sqlite3 -header "$DB" "
SELECT 'telemetry' as tbl, COUNT(*) as rows FROM telemetry
UNION ALL SELECT 'observer_snapshots', COUNT(*) FROM observer_snapshots
UNION ALL SELECT 'exit_observer_snapshots', COUNT(*) FROM exit_observer_snapshots;
"
echo ""
sqlite3 -header "$DB" "
SELECT namespace,
       COUNT(DISTINCT id) as batches,
       COUNT(*) as metrics
FROM telemetry GROUP BY namespace;
"
