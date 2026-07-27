## Overview

This project scrapes the Pennsylvania state health department's website every day to track new measles cases confirmed in each county, keeping a running daily and weekly record of the outbreak.

## How it works

The GitHub Action runs daily at 5:05pm ET:

1. **Scraper** fetches the DOH measles page and compares published totals against `measles_daily.tsv`
2. If cases have increased, new delta rows are appended to `measles_daily.tsv`
3. `measles_weekly.tsv` is synced: `new_cases` is refreshed from `measles_daily.tsv`'s scrape-date rollup for every week except ones flagged `adjusted`, then the DOH dashboard's cumulative hospitalization total is diffed against prior weeks to fill in the current week's `hospitalizations`

You can also trigger it manually: **Actions → Scrape → Run workflow**

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
`adjusted` (see "Weekly tracking" below) so the scraper never overwrites
them — splitting that one gap into 9 cases (week of 2026-07-13) and 29
cases (week of 2026-07-20). Flag a row `adjusted` any time a similar gap
needs correcting — it'll persist across scrape runs instead of being
synced back to the (wrong) daily-rollup figure.

Separately, the Power BI report dropped its "January – March" (prior
outbreak) table sometime around 2026-07-24, presumably because that
outbreak has been fully contained for a while — the scraper only reports on
whatever outbreak tables the report currently exposes (right now just the
current, April–present outbreak). That's expected and not a bug; the prior
outbreak's already-recorded 12 cases in `measles_daily.tsv` remain accurate
and just won't get touched again.

## Weekly tracking

`data/measles_weekly.tsv` is the full, authoritative weekly record — one
row per week going back to 2026-04-20 (the outbreak's first week). It has
two independently maintained columns:

- **`new_cases`** — refreshed from `measles_daily.tsv`'s scrape-date rollup
  on every run, for every week. The exception is any week with `adjusted`
  set to `TRUE`: the scraper leaves `new_cases` alone for those and never
  overwrites it, so a hand correction (e.g. for a lump-sum catch-up delta
  landing in the wrong week — see "Known data gaps" above) sticks
  permanently instead of getting synced back to the wrong daily-rollup
  figure. Set `adjusted` to `TRUE` whenever you hand-edit a week's
  `new_cases`.
- **`hospitalizations`** — statewide cumulative hospitalizations aren't
  reported by county or by day, only as a running year-to-date total on the
  DOH dashboard's "Hospitalized" card. Each scrape run reads that total and
  derives *this week's* new hospitalizations by subtracting the sum of
  every other week already recorded here, then writes the result back into
  the current week's row — the same delta approach used for daily case
  counts, just applied weekly and statewide instead of daily and
  per-county. Tracking started the week of 2026-07-20 (the first row with a
  non-blank value), so every earlier week is blank/unknown rather than
  zero — there's no way to know how the current cumulative total was
  distributed across weeks before we started capturing it.

## Repo structure

```
measles-tracker/
├── scraper/
│   └── measles_scraper.R      # Scrapes DOH page, updates the TSVs
├── data/
│   ├── measles_daily.tsv      # One row per scraped delta (county, outbreak, date)
│   └── measles_weekly.tsv     # One row per week: manual case-count corrections + scraped hospitalizations — see "Weekly tracking"
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
