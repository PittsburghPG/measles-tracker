## Overview

This project scrapes the Pennsylvania state health department's website every day to track new measles cases confirmed in each county, keeping a running daily and weekly record of the outbreak.

## How it works

The GitHub Action runs daily at 5:05pm ET:

1. Scraper fetches the DOH measles page and compares published totals against `measles_daily.tsv`
2. If cases have increased, new delta rows are appended to `measles_daily.tsv`
3. `measles_weekly.tsv` is synced: `new_cases` is refreshed from `measles_daily.tsv`'s scrape-date rollup for every week except ones flagged `adjusted`, then the DOH dashboard's cumulative hospitalization total is diffed against prior weeks to fill in the current week's `hospitalizations`

You can also trigger it manually: **Actions → Scrape → Run workflow**

## Output

- `data/measles_daily.tsv` — one row per scraped delta: date observed,
  county, new case count, source, and which outbreak (`1` for
  January–March, `2` for the current April–present outbreak) it belongs to.
- `data/measles_weekly.tsv` — one row per week: new cases and statewide
  hospitalizations, plus an `adjusted` flag for any hand-corrected week and
  a free-text `note` explaining it (see "Known data gaps").

## Known data gaps

The DOH page changed its format (moved case counts into an embedded Power BI
dashboard) sometime after 2026-07-08, which broke the scraper until it was
fixed on 2026-07-24. No data was collected for that ~16-day span, so
`measles_daily.tsv` records the whole gap as a single lump-sum catch-up
delta dated 2026-07-24 (its actual scrape date) rather than daily
increments — we don't know the exact date(s) or county breakdown of when
those cases were really confirmed within the gap, and we're not attempting
to reconstruct that in the TSV. The daily file always reflects real scrape
dates, gaps included.

That lump sum would otherwise throw off the weekly/cumulative chart, showing
one artificial 38-case spike in the week of 2026-07-24. Since PA DOH
separately reported 29 new cases in the 7 days before 2026-07-24, we
hand-corrected two rows in `data/measles_weekly.tsv` and flagged them
`adjusted` — splitting that one gap into 9 cases (week of 2026-07-13) and 29
cases (week of 2026-07-20). The scraper skips re-syncing `new_cases` for any
week flagged `adjusted`, so a correction like this sticks permanently
instead of getting overwritten by the (wrong) daily-rollup figure on the
next run — flag a row `adjusted` any time a similar gap needs correcting.

Separately, the Power BI report dropped its "January – March" (prior
outbreak) table sometime around 2026-07-24, presumably because that
outbreak has been fully contained for a while — the scraper only reports on
whatever outbreak tables the report currently exposes (right now just the
current, April–present outbreak). That's expected and not a bug; the prior
outbreak's already-recorded 12 cases in `measles_daily.tsv` remain accurate
and just won't get touched again.

Statewide hospitalization tracking in `measles_weekly.tsv` didn't start
until the week of 2026-07-20 (the first week with a non-blank
`hospitalizations` value) — every earlier week is blank/unknown rather than
zero, since there's no way to know how the cumulative total DOH reports was
distributed across weeks before we started capturing it.

## Repo structure

```
measles-tracker/
├── scraper/
│   └── measles_scraper.R      # Scrapes DOH page, updates the TSVs
├── data/
│   ├── measles_daily.tsv      # One row per scraped delta (county, outbreak, date)
│   └── measles_weekly.tsv     # One row per week: case counts + hospitalizations — see "Output"
└── .github/
    └── workflows/
        └── scrape.yml
```

## Local development

```bash
Rscript scraper/measles_scraper.R
```

Requires the R packages listed at the top of `measles_scraper.R` (install once via
`install.packages(c("httr2", "rvest", "dplyr", "readr", "stringr", "jsonlite"))`).
