#!/usr/bin/env Rscript
# =============================================================================
# Update the standalone embed HTML files from the data in data/
#
# Each embed is a self-contained page meant to be hosted at a stable URL and
# iframed into the CMS. Rather than reading a shared data file at runtime,
# every embed keeps its data inlined as JS constants between a pair of marker
# comments, and this script rewrites just that block in place — so each embed
# stays a single, fully self-contained file with nothing else to fetch or
# cache.
#
# Runs separately from the scraper (see .github/workflows/update-visualizations.yml),
# reading whatever the scraper last committed.
#
# Usage:
#   Rscript scraper/update_visualizations.R
#
# Requirements (install once):
#   install.packages(c("dplyr", "readr", "stringr"))
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})

COUNTY_TSV           <- "data/daily_cases_by_county.tsv"
WEEKLY_TSV           <- "data/summary_weekly.tsv"
MAP_EMBED_HTML       <- "visualizations/map-embed.html"
WEEKLY_EMBED_HTML    <- "visualizations/weekly-trend-embed.html"

# Replace the JS between the "/* SCRAPER-DATA-START */" and
# "/* SCRAPER-DATA-END */" markers in an embed file with freshly generated
# lines, leaving the surrounding markup/styling/chart code untouched.
inject_embed_data <- function(path, js_lines) {
  lines     <- readLines(path, warn = FALSE)
  start_idx <- which(str_detect(lines, fixed("SCRAPER-DATA-START")))
  end_idx   <- which(str_detect(lines, fixed("SCRAPER-DATA-END")))

  if (length(start_idx) != 1 || length(end_idx) != 1 || end_idx <= start_idx) {
    stop("Could not find a single SCRAPER-DATA marker pair in '", path, "'")
  }

  updated <- c(lines[seq_len(start_idx)], js_lines, lines[end_idx:length(lines)])
  writeLines(updated, path)
  message("Updated embed data in '", path, "'")
}

# Per-county year-to-date total, mirroring the map's caseData shape.
compute_case_data <- function(daily_df) {
  daily_df |>
    group_by(county) |>
    summarise(total = sum(new_cases, na.rm = TRUE), .groups = "drop") |>
    arrange(county)
}

update_map_embed <- function(case_data, total_cases, last_updated, path) {
  entries <- sprintf('  "%s": %d', case_data$county, case_data$total)
  entries[-length(entries)] <- paste0(entries[-length(entries)], ",")

  js_lines <- c(
    sprintf("  const totalCases = %d;", total_cases),
    sprintf('  const lastUpdated = "%s";', last_updated),
    "  const caseData = {",
    entries,
    "  };"
  )
  inject_embed_data(path, js_lines)
}

update_weekly_embed <- function(weekly, path) {
  entries <- sprintf(
    '    { week_start: "%s", new_cases: %d, cumulative_cases: %d },',
    weekly$week_start, coalesce(weekly$new_cases, 0L), weekly$cumulative_cases
  )
  entries[length(entries)] <- str_remove(entries[length(entries)], ",$")

  js_lines <- c("  const weeklyData = [", entries, "  ];")
  inject_embed_data(path, js_lines)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

daily <- read_tsv(COUNTY_TSV, col_types = cols(new_cases = "i", .default = "c"), show_col_types = FALSE)
weekly <- read_tsv(WEEKLY_TSV, col_types = cols(new_cases = "i", .default = "c"), show_col_types = FALSE) |>
  arrange(week_start) |>
  mutate(cumulative_cases = cumsum(coalesce(new_cases, 0L)))

case_data    <- compute_case_data(daily)
total_cases  <- sum(case_data$total)
last_updated <- format(Sys.Date(), "%b %e, %Y") |> trimws()

# Skip any embed whose file isn't present, rather than failing the run.
if (file.exists(MAP_EMBED_HTML)) {
  update_map_embed(case_data, total_cases, last_updated, MAP_EMBED_HTML)
}
if (file.exists(WEEKLY_EMBED_HTML)) {
  update_weekly_embed(weekly, WEEKLY_EMBED_HTML)
}

message(sprintf(
  "Updated embeds — %d total cases across %d counties (as of %s)",
  total_cases, nrow(filter(case_data, total > 0)), last_updated
))
