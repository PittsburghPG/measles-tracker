## Overview

This project checks the Pennsylvania Department of Health's (PDOH) website every day for new measles cases in each county, and keeps a running daily and weekly count of the outbreak.

## How it works

A scheduled job runs every day at 5:05pm ET:

1. The scraper checks PDOH's measles page and compares the numbers it finds there to what's already saved in `measles_daily.tsv`
2. If a county's case count went up, it adds a new row to `measles_daily.tsv` for that increase
3. It then updates `measles_weekly.tsv`: for each week, it adds up that week's new cases from `measles_daily.tsv` (skipping any week we've corrected by hand), and works out that week's new hospitalizations by comparing PDOH's latest running total to what's already recorded for earlier weeks
4. It also updates `measles_daily_age_group.tsv`: PDOH's dashboard only exposes a statewide year-to-date cumulative case count broken out by age group (not by day), so each run compares each age group's cumulative total to what's already recorded and, for any group that went up, adds a row for the increase

You can also run it manually: **Actions → Scrape → Run workflow**

## Repo structure

```
measles-tracker/
├── scraper/
│   └── measles_scraper.R     
├── data/
│   ├── measles_daily.tsv      
│   ├── measles_weekly.tsv     
│   └── measles_daily_age_group.tsv
└── .github/
    └── workflows/
        └── scrape.yml
```

## Known limitations

PDOH changed how it displayed new cases on its website in early July 2026, which broke the scraper from July 8–24, 2026. That gap is filled in `measles_daily.tsv` as one row per county, all dated July 24, 2026 (the day the scraper caught up) rather than broken out day by day. In all, 38 cases were confirmed during this 16-day gap.  

Left alone, all cases  would land in the week of July 20, 2026 in `measles_weekly.tsv`, creating an artificial spike in cases. PDOH separately reported that 29 new cases were confirmed in the 7 days before July 24, so we used that number to split the 38 by hand: 29 cases to the week of July 20, and the remaining 9 (38 minus 29) to the week of July 13. Those two weeks' `new_cases` values are manually adjusted and excluded from the scraper's usual auto-sync (see `ADJUSTED_WEEKS` in `measles_scraper.R`) so they don't get overwritten on the next run.

## Local development

```bash
Rscript scraper/measles_scraper.R
```

Requires the R packages listed at the top of `measles_scraper.R` (install once via
`install.packages(c("httr2", "rvest", "dplyr", "readr", "stringr", "jsonlite"))`).
