#!/usr/bin/env bash
# Completeness audit for market.derivative_quotes (ClickHouse).
#
# Reads credentials from the environment:
#   CLICKHOUSE_HOST CLICKHOUSE_PORT CLICKHOUSE_USER CLICKHOUSE_PASSWORD CLICKHOUSE_DB
#
# Usage:  ./probes/derivative_quotes_audit.sh [outdir]
#
# Notes learned the hard way while writing this:
#  * The server caps total query memory at ~2.4 GiB, so every aggregation is
#    chunked by year/quarter and run SEQUENTIALLY. Running these in parallel
#    reliably trips MEMORY_LIMIT_EXCEEDED.
#  * uniqExact() over the full table blows the memory cap; uniq() (HLL) is used
#    wherever an approximate distinct count is good enough.
#  * ts is stored in UTC. The NSE cash/F&O session 09:15-15:30 IST is
#    03:45-10:00 UTC, i.e. minute-of-day 225..599 (375 one-minute bars).
#  * ClickHouse formatDateTime uses %i for minutes; %M is the month name.

set -uo pipefail
OUT="${1:-audit_out}"
mkdir -p "$OUT"

chq() { # chq <sql> [format] [timeout_seconds]
  curl -sS --max-time "${3:-900}" \
    --user "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" \
    --data-binary "${1} FORMAT ${2:-TSV}" \
    "${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/?database=${CLICKHOUSE_DB}&max_execution_time=880&max_threads=8"
}

YEARS="2020 2021 2022 2023 2024 2025 2026"

echo "==> 1. partition-level row counts by segment and month (cheap, metadata only)"
chq "SELECT splitByChar(',', replaceRegexpAll(partition,'[()'' ]',''))[1] AS segment,
            toUInt32(splitByChar(',', replaceRegexpAll(partition,'[()'' ]',''))[2]) AS ym,
            sum(rows) AS rows
     FROM system.parts
     WHERE database='market' AND table='derivative_quotes' AND active
     GROUP BY segment, ym ORDER BY segment, ym" TSVWithNames > "$OUT/01_partitions.tsv"

echo "==> 2. per segment-day row counts and session window"
: > "$OUT/02_daily.tsv"
for Y in $YEARS; do
  chq "SELECT segment, toDate(ts) AS d, count() AS rows,
              formatDateTime(min(ts),'%H:%i') AS utc_start,
              formatDateTime(max(ts),'%H:%i') AS utc_end,
              uniqExact(toStartOfMinute(ts)) AS minutes
       FROM market.derivative_quotes
       WHERE ts >= '$Y-01-01' AND ts < '$((Y+1))-01-01'
       GROUP BY segment, d ORDER BY segment, d" TSV >> "$OUT/02_daily.tsv"
done

echo "==> 3. trading calendar ground truth (official NSE F&O bhavcopy)"
chq "SELECT trade_date, count() AS contracts, uniqExact(symbol) AS symbols
     FROM market.nse_fo_bhavcopy GROUP BY trade_date ORDER BY trade_date" TSVWithNames > "$OUT/03_calendar.tsv"

echo "==> 4. intraday minute coverage for nfo (detects mid-session holes)"
: > "$OUT/04_nfo_minutes.tsv"
for Y in $YEARS; do
  chq "SELECT toDate(ts) AS d, toHour(ts)*60+toMinute(ts) AS minute_of_day, count() AS rows
       FROM market.derivative_quotes
       WHERE segment='nfo' AND ts >= '$Y-01-01' AND ts < '$((Y+1))-01-01'
       GROUP BY d, minute_of_day ORDER BY d, minute_of_day" TSV >> "$OUT/04_nfo_minutes.tsv"
done

echo "==> 5. field-level null / zero rates"
: > "$OUT/05_field_nulls.tsv"
NULLQ="count() AS rows,
 round(100*countIf(expiry_date IS NULL)/count(),2) AS expiry_date_null_pct,
 round(100*countIf(iv IS NULL)/count(),2) AS iv_null_pct,
 round(100*countIf(delta IS NULL)/count(),2) AS delta_null_pct,
 round(100*countIf(close=0)/count(),2) AS close_zero_pct,
 round(100*countIf(volume=0)/count(),2) AS volume_zero_pct,
 round(100*countIf(volume>1e12)/count(),4) AS volume_overflow_pct"
for Y in $YEARS; do
  chq "SELECT 'nfo' AS segment, toYear(ts) AS y,
              if(option_type IN ('CE','PE'),'OPT','FUT') AS kind, $NULLQ
       FROM market.derivative_quotes
       WHERE segment='nfo' AND ts >= '$Y-01-01' AND ts < '$((Y+1))-01-01'
       GROUP BY segment, y, kind ORDER BY kind" TSV >> "$OUT/05_field_nulls.tsv"
done
for S in mfo bfo; do
  chq "SELECT segment, toYear(ts) AS y,
              if(option_type IN ('CE','PE'),'OPT','FUT') AS kind, $NULLQ
       FROM market.derivative_quotes WHERE segment='$S'
       GROUP BY segment, y, kind ORDER BY y, kind" TSV >> "$OUT/05_field_nulls.tsv"
done

echo "==> 6. rows whose classification columns failed to parse"
chq "SELECT segment, toYear(ts) AS y, count() AS rows, uniq(symbol) AS symbols
     FROM market.derivative_quotes
     WHERE underlying='' OR option_type NOT IN ('CE','PE','FUT')
     GROUP BY segment, y ORDER BY segment, y" TSVWithNames > "$OUT/06_unparsed.tsv"

echo "==> 7. contract-chain completeness vs official bhavcopy (nfo)"
# A contract is keyed (underlying, expiry month, strike, option_type). Weekly
# expiries collapse into their month because derivative_quotes only stores
# expiry_ym reliably -- this makes the result a LOWER BOUND on what is missing.
: > "$OUT/07_contract_gap.tsv"
for Y in $YEARS; do
  for Q in 01:04 04:07 07:10 10:13; do
    a="$Y-${Q%%:*}-01"
    bm="${Q#*:}"
    if [ "$bm" = "13" ]; then b="$((Y+1))-01-01"; else b="$Y-$bm-01"; fi
    chq "SELECT day,
                countIf(bhav>0 AND dq=0) AS missing_in_dq,
                countIf(dq>0 AND bhav=0) AS only_in_dq,
                countIf(bhav>0 AND dq>0) AS matched
         FROM (
           SELECT day, sym, eym, k, ot, max(src='bh') AS bhav, max(src='dq') AS dq
           FROM (
             SELECT trade_date AS day, symbol AS sym, toYYYYMM(expiry_date) AS eym,
                    strike AS k, if(instrument LIKE 'FUT%','FUT',option_type) AS ot, 'bh' AS src
             FROM market.nse_fo_bhavcopy WHERE trade_date >= '$a' AND trade_date < '$b'
             UNION ALL
             SELECT toDate(ts), underlying, expiry_ym, toFloat64(strike), option_type, 'dq'
             FROM market.derivative_quotes
             WHERE segment='nfo' AND ts >= '$a' AND ts < '$b'
           ) GROUP BY day, sym, eym, k, ot)
         GROUP BY day ORDER BY day" TSV >> "$OUT/07_contract_gap.tsv"
  done
done

echo "==> 8. contract gap broken down by symbol and expiry horizon"
: > "$OUT/08_gap_by_symbol.tsv"
for Y in $YEARS; do
  for Q in 01:04 04:07 07:10 10:13; do
    a="$Y-${Q%%:*}-01"
    bm="${Q#*:}"
    if [ "$bm" = "13" ]; then b="$((Y+1))-01-01"; else b="$Y-$bm-01"; fi
    chq "SELECT sym, least(exp_offset,3) AS months_to_expiry, ot,
                countIf(bhav>0 AND dq=0) AS missing, countIf(bhav>0) AS expected
         FROM (
           SELECT day, sym, eym, k, ot,
                  dateDiff('month',
                           toDate(concat(substring(toString(day),1,7),'-01')),
                           toDate(parseDateTimeBestEffort(concat(toString(eym),'01')))) AS exp_offset,
                  max(src='bh') AS bhav, max(src='dq') AS dq
           FROM (
             SELECT trade_date AS day, symbol AS sym, toYYYYMM(expiry_date) AS eym,
                    strike AS k, if(instrument LIKE 'FUT%','FUT',option_type) AS ot, 'bh' AS src
             FROM market.nse_fo_bhavcopy WHERE trade_date >= '$a' AND trade_date < '$b'
             UNION ALL
             SELECT toDate(ts), underlying, expiry_ym, toFloat64(strike), option_type, 'dq'
             FROM market.derivative_quotes
             WHERE segment='nfo' AND ts >= '$a' AND ts < '$b'
           ) GROUP BY day, sym, eym, k, ot)
         WHERE bhav>0 GROUP BY sym, months_to_expiry, ot" TSV >> "$OUT/08_gap_by_symbol.tsv"
  done
done

echo "==> 9. duplicate (symbol, ts) check"
: > "$OUT/09_duplicates.tsv"
for Y in $YEARS; do
  chq "SELECT '$Y' AS y, sum(c) AS rows, sum(c)-count() AS duplicate_excess
       FROM (SELECT symbol, ts, count() AS c FROM market.derivative_quotes
             WHERE segment='nfo' AND ts >= '$Y-01-01' AND ts < '$((Y+1))-01-01'
             GROUP BY symbol, ts HAVING c > 1)" TSV >> "$OUT/09_duplicates.tsv"
done

echo "==> done. results in $OUT/"
