## Overview

This project checks the Pennsylvania Department of Health's (PDOH) website every day for new measles cases in each county, and keeps a running daily and weekly count of the outbreak.

## How it works

A scheduled job runs every day at 5:05pm ET:

1. The scraper checks PDOH's measles page and compares the numbers it finds there to what's already saved in `cases_by_county.tsv`
2. If a county's case count went up, it adds a new row to `cases_by_county.tsv` for that increase, recording that county's running case total for the year (across both outbreaks) as `cumulative_cases` and its running total for that outbreak alone as `cumulative_outbreak_cases`
3. It then updates `summary_weekly.tsv`: for each week, it adds up that week's new cases from `cases_by_county.tsv`, skipping any week we've corrected by hand, and recomputes `cumulative_cases` as a running total across all weeks
4. It also updates `cases_by_age_group.tsv`: PDOH's dashboard only exposes a statewide year-to-date cumulative case count broken out by age group (not by day), so each run compares each age group's cumulative total (`cumulative_cases`) to what's already recorded and, for any group that went up, adds a row for the increase (`new_cases`)
5. It also updates `hospitalization_by_age_group.tsv`: PDOH's Hospitalization tab exposes a statewide running total broken out into three cards — total, under 18 ("children"), and 18+ ("adult") — but not by day or county, so each run adds one row per category, recording that category's total as `cumulative_hospitalizations` and working out `new_hospitalizations` by diffing it against that category's most recent prior day's cumulative total on record
6. Finally, it updates `summary_daily.tsv`: statewide totals only — `new_cases`/`cumulative_cases` rolled up across all counties, plus that day's `new_hospitalizations`/`cumulative_hospitalizations` from the "total" category above — so you can see where things stand at a glance without wading through the per-county or per-category files. A row is only added on a day PDOH actually reported a change in cases or hospitalizations; a day with neither isn't a real data point, just PDOH not having published an update yet. `cumulative_cases` is recomputed from scratch each run as the sum of every `new_cases` ever recorded in `cases_by_county.tsv`, so it can't drift out of sync

You can also run it manually: **Actions → Scrape → Run workflow**

## Dashboard

`dashboard/` is a SvelteKit app that browses `data/cases_by_county.tsv`: a statewide map (hover a county for its total, click through to that county's page) and, per county, a cumulative-cases line chart, a weekly-reports bar chart, and the underlying daily data. It's a static site — county pages are prerendered at build time from whatever's in `data/` — so it needs rebuilding (and redeploying) to pick up new scrapes. See `dashboard/README.md` for how to run it.

## Repo structure

```
measles-tracker/
├── scraper/
│   └── measles_scraper.R     
├── data/
│   ├── cases_by_county.tsv
│   ├── cases_by_age_group.tsv
│   ├── hospitalization_by_age_group.tsv
│   ├── summary_daily.tsv
│   └── summary_weekly.tsv
├── dashboard/
│   └── ...                   # SvelteKit app, see dashboard/README.md
└── .github/
    └── workflows/
        └── scrape.yml
```

## Known limitations

PDOH changed how it displayed new cases on its website in early July 2026, which broke the scraper from July 8–24, 2026. That gap is filled in `cases_by_county.tsv` as one row per county, all dated July 24, 2026 (the day the scraper caught up) rather than broken out day by day. In all, 38 cases were confirmed during this 16-day gap.  

Left alone, all cases  would land in the week of July 20, 2026 in `summary_weekly.tsv`, creating an artificial spike in cases. PDOH separately reported that 29 new cases were confirmed in the 7 days before July 24, so we used that number to split the 38 by hand: 29 cases to the week of July 20, and the remaining 9 (38 minus 29) to the week of July 13. Those two weeks' `new_cases` values are manually adjusted and excluded from the scraper's usual auto-sync (see `ADJUSTED_WEEKS` in `measles_scraper.R`) so they don't get overwritten on the next run.

Hospitalizations were originally tracked weekly (as a `hospitalizations` column on `summary_weekly.tsv`) before `hospitalization_by_age_group.tsv` started tracking them daily, by category, on August 28, 2026. That earlier weekly history wasn't carried over; `hospitalization_by_age_group.tsv` instead starts from a baseline of three rows (August 28, 2026: total 83, children 24, adult 59) and tracks each category day by day from there.

Age-group tracking started August 26, 2026. Each age group's first row in `cases_by_age_group.tsv` (dated August 26, 2026) leaves `new_cases` blank rather than recording PDOH's full cumulative total as if all of it were new that day — it was just where each group's count already stood when tracking began. `cumulative_cases` on that row still carries the correct starting total.

`summary_daily.tsv` was backfilled for its full history (starting January 30, 2026, matching `cases_by_county.tsv`'s earliest row) rather than starting from whenever this file was added. Its hospitalization columns are blank for any date before hospitalization tracking began (August 28, 2026), since there's no data to report yet — as opposed to a `0`, which would wrongly imply zero hospitalizations.

## Local development

```bash
Rscript scraper/measles_scraper.R
```

Requires the R packages listed at the top of `measles_scraper.R` (install once via
`install.packages(c("httr2", "rvest", "dplyr", "readr", "stringr", "jsonlite"))`).
