# `market.derivative_quotes` — completeness audit

**Probed:** 2026-09-15 · **Table:** 12,716,010,805 rows / 98.29 GiB · ClickHouse 24.8.14.39
**Reproduce:** `./probes/derivative_quotes_audit.sh`

Ground truth for "what *should* be there" is `market.nse_fo_bhavcopy` (the official
NSE F&O end-of-day bhavcopy, 1,898 trading days, 2019-01-01 → 2026-09-09). Every
claim below is a diff against that table or against the table's own partition
metadata.

---

## Summary of what is missing

| # | Gap | Dates | Scope |
|---|-----|-------|-------|
| 1 | Feed stopped — no recent data | **2026-08-31 → 2026-09-09** (8 trading days) | all segments |
| 2 | Whole month absent | **2023-12-01 → 2023-12-29** (20 trading days) | `mfo` |
| 3 | Missing days | **2024-09-13**; **2025-01-30**, **2025-01-31** | `mfo`; `bfo` |
| 4 | Truncated / holed sessions | 19 sessions, worst 2023-06, 2023-07, 2024-12 | `nfo` |
| 5 | **Options chain 24–48% absent** | **2020-01-01 → 2021-08-31** | `nfo`, worst on illiquid symbols |
| 6 | IV + greeks absent | 2020 → 2023 (96–97%); regression from **2025-10-06** | `nfo` options |
| 7 | No greeks at all | 2019 → 2024 | `mfo` |
| 8 | Classification columns blank | 2019-12 → 2024-12 (59.3M rows) | `mfo`, all of `cds` |
| 9 | `expiry_date` unusable | all years (95–97% NULL) | `nfo`, `bfo` |

Clean bills of health: **no duplicate `(symbol, ts)` rows** in any year, and
**zero missing whole trading days for `nfo`** across 1,646 sessions.

---

## 1. The feed is stale — nothing after 2026-08-28

Every segment stops at the same timestamp:

| segment | last row | first row |
|---|---|---|
| `nfo` | 2026-08-28 11:31 UTC | 2020-01-01 |
| `mfo` | 2026-08-28 18:00 UTC | 2019-12-31 |
| `bfo` | 2026-08-28 10:55 UTC | 2023-12-31 |

The bhavcopy already carries **2026-08-31, 09-01, 09-02, 09-03, 09-04, 09-07,
09-08, 09-09** — eight NSE trading days with no quote data at all. Today is
2026-09-15, so counting days the bhavcopy itself has not yet caught up on, the
feed is roughly two weeks behind.

## 2–3. Missing whole trading days

**`mfo` — all of December 2023 is gone.** Last row 2023-11-30, next row
2024-01-01. Twenty consecutive sessions absent:

```
2023-12-01, 12-04, 12-05, 12-06, 12-07, 12-08, 12-11, 12-12, 12-13, 12-14,
2023-12-15, 12-18, 12-19, 12-20, 12-21, 12-22, 12-26, 12-27, 12-28, 12-29
```

The `(mfo, 202312)` partition does not exist. Also missing: **2024-09-13**
(and the day before it, 2024-09-12, is truncated to 341 of ~880 minutes).

**`bfo` — 2025-01-30 and 2025-01-31** are absent; 01-29 and 02-01 are both normal.

## 4. Truncated and holed `nfo` sessions

Of 1,647 weekday sessions, **1,613 have a complete 375-minute core session**
(09:15–15:29 IST). The 34 that do not split into two groups.

*Legitimately short* — Diwali Muhurat evening sessions, correctly stored outside
the normal window: 2021-11-04, 2022-10-24, 2024-11-01, 2025-10-21. Plus
2020-03-13 and 2020-03-23, the COVID circuit-breaker halts.

*Genuine gaps* — these are real missing data (20 sessions; the remaining 8 lose
only 1–4 minutes each and are noise: 2021-03-25, 2022-02-03, 2024-08-08,
2024-10-10, 2025-01-01, 2025-04-24, 2026-03-17, 2026-08-12):

| date | minutes present | missing | shape (IST) |
|---|---|---|---|
| 2024-10-03 | 81 / 375 | 294 | nothing before **14:08**; runs to 17:30 |
| 2021-02-24 | 169 / 375 | 206 | dead from 12:58 onward; runs to 17:00 |
| 2023-06-13 | 186 / 375 | 189 | shredded, 34 separate holes |
| 2023-07-28 | 190 / 375 | 185 | shredded from the open |
| 2023-07-27 | 203 / 375 | 172 | nothing 12:07–14:47 |
| 2023-07-25 | 224 / 375 | 151 | nothing 12:29–14:24 |
| 2024-12-24 | 224 / 375 | 151 | **ends 12:58** |
| 2024-12-31 | 226 / 375 | 149 | **ends 13:00** |
| 2023-06-15 | 229 / 375 | 146 | 49 separate holes |
| 2023-06-19 | 236 / 375 | 139 | 53 separate holes |
| 2023-06-14 | 252 / 375 | 123 | 51 separate holes |
| 2023-08-03 | 257 / 375 | 118 | shredded from the open |
| 2024-12-27 | 259 / 375 | 116 | **ends 13:34** |
| 2023-08-04 | 268 / 375 | 107 | shredded from the open |
| 2021-07-22 | 270 / 375 | 105 | nothing 10:24–12:08 |
| 2023-07-24 | 279 / 375 | 96 | 58 separate holes |
| 2023-07-26 | 289 / 375 | 86 | 39 separate holes |
| 2023-08-07 | 334 / 375 | 41 | nothing 12:15–12:55 |
| 2025-04-28 | 351 / 375 | 24 | ragged open 09:15–09:41 |
| 2022-10-06 | 355 / 375 | 20 | nothing before 09:35 |

Two clusters dominate: **2023-06-13…06-19** and **2023-07-24…08-07** (capture
dropping minutes throughout the day), and **2024-12-24/27/31** (the afternoon
session simply never arrives).

A related integrity note: on several of these days timestamps run past the
15:30 close (2021-02-24 → 17:00, 2023-06-13 → 17:05, 2024-10-03 → 17:30), so
that day's bars are not only incomplete but time-shifted.

## 5. The big one — 2020 to Aug 2021 is missing a third of the options chain

Diffing every `(underlying, expiry month, strike, option_type)` in the bhavcopy
against the table, per day:

| month | contracts missing | matched | missing |
|---|---|---|---|
| 2020-01 | 168,943 | 531,124 | 24.1% |
| 2020-03 | 367,619 | 393,006 | **48.3%** |
| 2020-06 | 254,687 | 527,767 | 32.5% |
| 2020-10 | 278,972 | 392,047 | 41.6% |
| 2021-01 | 332,936 | 515,270 | 39.3% |
| 2021-04 | 381,963 | 546,965 | 41.1% |
| 2021-07 | 441,464 | 575,915 | **43.4%** |
| 2021-08 | 112,132 | 924,091 | 10.8% |
| **2021-09** | **1,114** | **1,121,566** | **0.1%** |
| 2021-10 onward | ~0 | — | ~0% |

Over 2020-01-01 → 2021-08-31: **5,779,661 of 16,102,966 contract-days missing (35.9%)**.
The problem ends abruptly in **September 2021** and never returns — spot checks of
May 2023 and August 2026 show *zero* missing contracts.

**It is an expiry-horizon problem, not a symbol problem.** July 2021:

| expiry | CE missing | PE missing |
|---|---|---|
| current month | 3.1% | 10.3% |
| next month | 31.6% | 40.6% |
| 2 months out | **89.6%** | **90.5%** |
| 3 months out | 95.5% | 96.1% |
| 5+ months (long-dated) | 31–100% | 22–100% |
| futures (all expiries) | 0.0% | — |

So for that era the table is usable for front-month options and futures, and
should not be trusted for anything beyond the next expiry.

**Which symbols are worst hit** (near expiry = current + next month, 2020-01 → 2021-08):

| symbol | near-expiry missing | all expiries |
|---|---|---|
| NIFTYIT | **95.6%** | 96.3% |
| PAGEIND | 52.6% | 66.4% |
| MRF | 46.5% | 62.0% |
| BOSCHLTD | 46.1% | 61.9% |
| SHREECEM | 39.1% | 56.6% |
| NIITTECH | 36.7% | 53.6% |
| PIIND | 35.7% | 51.3% |
| RAMCOCEM | 32.5% | 52.6% |
| **FINNIFTY** | 32.2% | 51.3% |
| ALKEM / MPHASIS / PFIZER | ~29% | ~48% |
| NESTLEIND / NAUKRI / COFORGE | ~28% | ~49% |

and the best covered:

| symbol | near-expiry missing | all expiries |
|---|---|---|
| NIFTY | **0.6%** | 42.2% |
| ICICIBANK | 2.5% | 18.9% |
| SBIN | 2.9% | 15.1% |
| TATAMOTORS / LT | 3.1% | ~21% |
| AXISBANK / INFY | 3.3% | ~24% |
| BANKNIFTY | 3.6% | 22.2% |

The gradient tracks liquidity almost perfectly: high-priced or thinly traded
underlyings (NIFTYIT, PAGEIND, MRF, BOSCHLTD) lost half their near-expiry chain,
while NIFTY and the large-cap banks are essentially intact. Note that even NIFTY
is 42.2% missing once far expiries are included.

Also worth knowing: only 27 symbols are ever missing at the *underlying* level,
all on isolated days in 2020–21, concentrated on **2021-02-26** (16 symbols:
LTI, NAM-INDIA, ALKEM, CUB, PIIND, GUJGASLTD, LTTS, AUBANK, IRCTC, NAVINFLUOR,
TRENT, DEEPAKNTR, MPHASIS, PFIZER, GRANULES, APLLTD) and **2020-02-27 → 03-02**
(TATACONSUM, BANDHANBNK, HDFCLIFE, NAUKRI).

## 6–7. IV and greeks

`nfo`, **options rows only** (futures legitimately have none):

| year | rows | IV NULL | delta NULL |
|---|---|---|---|
| 2020 | 869.5M | **97.5%** | 97.5% |
| 2022 | 1.41B | **96.3%** | 96.3% |
| 2023 | 1.63B | **95.7%** | 95.7% |
| 2024 | 1.84B | 45.1% | 25.1% |
| 2025 | 1.90B | 41.8% | 28.0% |
| 2026 | 1.49B | 49.2% | **49.2%** |

The table comment says greeks before 2024-01-01 were computed (Black-76,
backfilled Aug 2026) — in practice that backfill reached only **~3–4% of option
rows**. For 2020–2023 the greeks are effectively absent.

There is also a **regression with an exact start date: 2025-10-06.** Before it,
delta was populated on far more rows than IV (delta ~21–25% NULL vs IV ~40%).
From 2025-10-06 onward `delta NULL` and `iv NULL` are identical to two decimals
every single day — greeks are now all-or-nothing, costing ~20 percentage points
of delta coverage:

```
2025-10-01   iv_null 38.60   delta_null 28.19
2025-10-03   iv_null 37.11   delta_null 22.42
2025-10-06   iv_null 40.21   delta_null 40.21   <-- break
2025-10-07   iv_null 40.43   delta_null 40.43
...
2026-08      iv_null 46.24   delta_null 46.23
```

`mfo` has **no greeks or IV whatsoever for 2019–2024** (100% NULL); they only
begin in 2025. `bfo` IV is 85–96% NULL throughout, and its delta NULL rate
degrades from 3.0% (2024) → 22.4% (2025) → **83.5% (2026)**.

## 8. Rows whose classification columns were never parsed

**59,328,702 `mfo` rows** carry `underlying=''`, `expiry_ym=0`, `strike=0` and
`option_type=''` — every classification column blank, even though the symbol
string holds the information:

```
symbol=GOLDM23NOVFUT  underlying=''  expiry_ym=0  strike=0  option_type=''  close=59620
```

| year | unparsed rows | share of that year's `mfo` |
|---|---|---|
| 2020 | 8,638,183 | 24.6% |
| 2021 | 10,069,313 | 23.6% |
| 2022 | 8,989,616 | 14.6% |
| 2023 | 10,732,431 | 6.1% |
| 2024 | 20,899,070 | 2.7% |
| 2025+ | 0 | fixed |

These rows are unreachable by any query filtering on `underlying`, `strike`,
`option_type` or `expiry_ym`, and because the table is sorted on exactly those
columns they all collapse into one degenerate key range. They can only be
reached by parsing `symbol`. The same defect covers **the entire `cds` segment**
(36,612 rows, 11,495 symbols).

## 9. `expiry_date` is unusable; `expiry_ym` collapses weeklies

`expiry_date` is NULL for **95–97% of all `nfo` rows in every year**, and 51–66%
of `bfo`. Only `expiry_ym` (year-month) is reliably populated — which merges all
weekly expiries in a month into one value. On 2026-08-28 the table shows NIFTY
`expiry_ym=202609` as a single bucket where the bhavcopy has five distinct
expiries (09-01, 09-08, 09-15, 09-22, 09-29).

The real expiry *is* recoverable from `symbol` (`NIFTY2690125000CE` = 2026,
month 9, day 01; `NIFTY26SEP25000CE` = monthly; `NIFTY26SEPFUT` = future), but
not from the typed columns. This also means the contract-gap numbers in §5 are a
**lower bound** — they can only detect a strike missing for a whole month, not a
single weekly expiry missing within it.

## 10. Stray one-off segments

Four segments contain exactly one day, **2026-08-21**, and nothing else:

| segment | rows | symbols |
|---|---|---|
| `nfo_intraday` | 1,025,452 | 35,558 |
| `bfo_intraday` | 226,114 | 39,506 |
| `mfo_intraday` | 358,928 | 8,005 |
| `cds` | 36,612 | 11,495 |

`nfo_intraday` holds 1.03M rows for a day where `nfo` itself holds 8.16M, so it
is a partial duplicate load, not a replacement. These look like a test or aborted
migration. `cds` (currency derivatives) is the only trace of that market in the
table, and is unparsed per §8.

## 11. Confirmed pre-existing defects

The volume overflow documented in the table comment is real and bounded: rows
with `volume > 1e12` run 0.006–0.047% per year across 2020–2023 plus `mfo`, and
**zero from 2025 onward**. Use `total_volume` deltas as the comment advises.

---

## Practical guidance

- **Safe window for full options-chain work: 2021-09-01 onward.** Before that,
  restrict to front-month options and futures, and exclude NIFTYIT, PAGEIND, MRF,
  BOSCHLTD, SHREECEM entirely.
- **Greeks/IV: 2024-01-01 onward only**, and expect ~40–50% NULL. For `mfo`,
  2025 onward.
- **Always filter `volume < 1e12`** or derive volume from `total_volume`.
- **Never join on `expiry_date`** — parse `symbol` instead.
- **Exclude `segment LIKE '%_intraday'` and `segment='cds'`** from any analysis.
- Backfill priorities, highest value first: (1) the 8 missing days to 2026-09-09,
  (2) `mfo` December 2023, (3) the 2024-12-24/27/31 afternoons, (4) the 2025-10-06
  delta regression.
