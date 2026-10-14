## Overview

This project checks the Pennsylvania Department of Health's (PDOH) website every day for new measles cases in each county, and keeps a running daily and weekly count of the outbreak.

## How it works

A scheduled job runs every day at 5:05pm ET. Files starting with `reported_` or `summary_reported_` count cases by the date PDOH reported them; files starting with `onset_` count them by the date the patient's rash began.

1. The scraper checks PDOH's measles page and compares the numbers it finds there to what's already saved in `reported_daily_cases_by_county.tsv`
2. If a county's case count changed, it adds a new row to `reported_daily_cases_by_county.tsv` for that change, recording that county's running case total for the year (across both outbreaks) as `cumulative_cases` and its running total for that outbreak alone as `cumulative_outbreak_cases`
3. It then updates `summary_reported_weekly.tsv`: for each week, it adds up that week's new cases from `reported_daily_cases_by_county.tsv`, skipping any week we've corrected by hand, and recomputes `cumulative_cases` as a running total across all weeks
4. It also updates `reported_daily_cases_by_age_group.tsv`: PDOH's dashboard only exposes a statewide year-to-date cumulative case count broken out by age group (not by day), so each run compares each age group's cumulative total (`cumulative_cases`) to what's already recorded and, for any group that changed, adds a row for the change (`new_cases`)
5. It also updates `reported_hospitalization_by_age_group.tsv`: PDOH's Hospitalization tab exposes a statewide running total broken out into three cards — total, under 18 ("children"), and 18+ ("adult") — but not by day or county, so each run adds one row per category, recording that category's total as `cumulative_hospitalizations` and working out `new_hospitalizations` by diffing it against that category's most recent prior day's cumulative total on record
6. It also updates `summary_reported_daily.tsv`: statewide totals only — `new_cases`/`cumulative_cases` rolled up across all counties, plus that day's `new_hospitalizations`/`cumulative_hospitalizations` from the "total" category above — so you can see where things stand at a glance without wading through the per-county or per-category files. A row is only added on a day PDOH actually reported a change in cases or hospitalizations; a day with neither isn't a real data point, just PDOH not having published an update yet. `cumulative_cases` is recomputed from scratch each run as the sum of every `new_cases` ever recorded in `reported_daily_cases_by_county.tsv`, so it can't drift out of sync
7. It also replaces `onset_weekly.tsv` with the current numbers from the Epidemic Curve tab of PDOH's dashboard: statewide cases grouped by the week (starting Monday) the patient's rash began, not the day PDOH reported the case. `summary_reported_weekly.tsv` groups cases by report date instead, so the two show different curves. PDOH revises past weeks as it learns onset dates, so each run rewrites the whole file rather than adding rows; past versions are in the git history. The most recent weeks will usually rise as later-reported cases get assigned to them
8. It also updates `onset_daily.tsv`, which shows which onset weeks each day's newly reported cases fell into. Each run compares every onset week's count to the last one recorded and, for any week that changed, adds a row with that week (`week_start`), its current count (`cumulative_cases`) and the change (`new_cases`). Tracking started October 14, 2026; those first rows leave `new_cases` blank because they record where each week already stood, not new cases

You can also run it manually: **Actions → Scrape → Run workflow**

## Repo structure

```
measles-tracker/
├── scraper/
│   └── measles_scraper.R     
├── data/
│   ├── reported_daily_cases_by_county.tsv
│   ├── reported_daily_cases_by_age_group.tsv
│   ├── reported_hospitalization_by_age_group.tsv
│   ├── summary_reported_daily.tsv
│   ├── summary_reported_weekly.tsv
│   ├── onset_daily.tsv
│   └── onset_weekly.tsv
└── .github/
    └── workflows/
        └── scrape.yml
```

## Known limitations

PDOH changed how it displayed new cases on its website in early July 2026, which broke the scraper from July 8–24, 2026. That gap is filled in `reported_daily_cases_by_county.tsv` as one row per county, all dated July 24, 2026 (the day the scraper caught up) rather than broken out day by day. In all, 38 cases were confirmed during this 16-day gap.  

Left alone, all cases  would land in the week of July 20, 2026 in `summary_reported_weekly.tsv`, creating an artificial spike in cases. PDOH separately reported that 29 new cases were confirmed in the 7 days before July 24, so we used that number to split the 38 by hand: 29 cases to the week of July 20, and the remaining 9 (38 minus 29) to the week of July 13. Those two weeks' `new_cases` values are manually adjusted and excluded from the scraper's usual auto-sync (see `ADJUSTED_WEEKS` in `measles_scraper.R`) so they don't get overwritten on the next run.

Hospitalizations were originally tracked weekly (as a `hospitalizations` column on `summary_reported_weekly.tsv`) before `reported_hospitalization_by_age_group.tsv` started tracking them daily, by category, on August 28, 2026. That earlier weekly history wasn't carried over; `reported_hospitalization_by_age_group.tsv` instead starts from a baseline of three rows (August 28, 2026: total 83, children 24, adult 59) and tracks each category day by day from there.

Age-group tracking started August 26, 2026. Each age group's first row in `reported_daily_cases_by_age_group.tsv` (dated August 26, 2026) leaves `new_cases` blank rather than recording PDOH's full cumulative total as if all of it were new that day — it was just where each group's count already stood when tracking began. `cumulative_cases` on that row still carries the correct starting total.

PDOH sometimes lowers a county's or age group's total, for example when a case is reclassified to another county or state or ruled out. The scraper records the drop as a row with a negative `new_cases` (and logs a `DECREASE` warning), so our totals keep matching PDOH's. The drop is dated the day PDOH made the change, not the day the case was first reported, so a week's `new_cases` in `summary_reported_weekly.tsv` is a net figure and can occasionally be lower than the number of new cases actually confirmed that week. The first such drop was September 30, 2026: Snyder County went from 42 to 41.

`summary_reported_daily.tsv` was backfilled for its full history (starting January 30, 2026, matching `reported_daily_cases_by_county.tsv`'s earliest row) rather than starting from whenever this file was added. Its hospitalization columns are blank for any date before hospitalization tracking began (August 28, 2026), since there's no data to report yet — as opposed to a `0`, which would wrongly imply zero hospitalizations.

## Local development

```bash
Rscript scraper/measles_scraper.R
```

Requires the R packages listed at the top of `measles_scraper.R` (install once via
`install.packages(c("httr2", "rvest", "dplyr", "readr", "stringr", "jsonlite"))`).
