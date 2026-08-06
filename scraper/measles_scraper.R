#!/usr/bin/env Rscript
# =============================================================================
# PA DOH Measles Case Scraper
# Scrapes: https://www.pa.gov/agencies/health/diseases-conditions/
#          infectious-disease/measles
#
# Run via GitHub Actions daily at 5:00 PM ET.
#
# Usage:
#   Rscript measles_scraper.R
#   Rscript measles_scraper.R --tsv /path/to/data.tsv
#
# Requirements (install once):
#   install.packages(c("httr2", "rvest", "dplyr", "readr", "stringr", "jsonlite"))
# =============================================================================

suppressPackageStartupMessages({
  library(httr2)
  library(rvest)
  library(dplyr)
  library(readr)
  library(stringr)
  library(jsonlite)
})

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SOURCE_URL          <- "https://www.pa.gov/agencies/health/diseases-conditions/infectious-disease/measles"
DEFAULT_TSV         <- "data/measles_daily.tsv"
WEEKLY_TSV          <- "data/measles_weekly.tsv"
TSV_COLS            <- c("date", "new_cases", "county", "source", "outbreak")
BAR_EMBED_HTML      <- "visualizations/cases-by-year-embed.html"
MAP_EMBED_HTML      <- "visualizations/map-by-outbreak-embed.html"
MAP_TOTAL_EMBED_HTML <- "visualizations/map-combined-embed.html"
WEEKLY_EMBED_HTML   <- "visualizations/weekly-trend-embed.html"

UA_STRING <- paste0(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) ",
  "AppleWebKit/537.36 (KHTML, like Gecko) ",
  "Chrome/124.0.0.0 Safari/537.36"
)

# ---------------------------------------------------------------------------
# Parse CLI arguments
# ---------------------------------------------------------------------------

args     <- commandArgs(trailingOnly = TRUE)
tsv_path <- {
  idx <- which(args == "--tsv")
  if (length(idx) > 0 && length(args) >= idx + 1) args[idx + 1] else DEFAULT_TSV
}

# ---------------------------------------------------------------------------
# Fetch page HTML
# ---------------------------------------------------------------------------

fetch_html <- function(url) {
  message("Fetching: ", url)

  resp <- tryCatch(
    request(url) |>
      req_headers(
        `User-Agent` = UA_STRING,
        `Accept` = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        `Accept-Language` = "en-US,en;q=0.9"
      ) |>
      req_timeout(30) |>
      req_perform(),
    error = function(e) {
      stop("HTTP request failed: ", conditionMessage(e))
    }
  )

  status <- resp_status(resp)
  if (status != 200) stop("HTTP ", status, " from ", url)

  html <- resp_body_string(resp)
  message("Fetched successfully (", nchar(html), " chars)")
  html
}

# ---------------------------------------------------------------------------
# Parse case counts from the embedded Power BI dashboard
#
# The DOH page no longer publishes county totals as HTML text — it embeds a
# Power BI "publish to web" report (app.powerbigov.us). We pull county-level
# numbers straight from the report's public query API instead of the DOM:
#   1. Find the iframe's embed URL and decode its `r` param (resourceKey +
#      tenantId are base64-encoded JSON).
#   2. Load the embed's HTML shell, which front-loads a `resolvedClusterUri`
#      JS variable — that's the query cluster for this report.
#   3. Hit `<cluster>/public/reports/<resourceKey>/modelsAndExploration` to
#      get the report layout (sections, visuals, and their DAX-ish queries).
#   4. Locate the "county x case count" table visuals — identified by a
#      `Where` filter on a `map` field — and run their queries against
#      `<cluster>/public/reports/querydata`.
#   5. Figure out which `map` value is which outbreak by checking which
#      table is made visible by the report's "January" / "April" bookmarks,
#      since the underlying field codes (e.g. "ob1"/"ob2") aren't
#      self-describing and aren't guaranteed to stay assigned the same way.
# ---------------------------------------------------------------------------

PBI_HEADING_MAP <- list(
  "april"   = 2L,
  "january" = 1L
)

extract_pbi_embed_url <- function(html) {
  page   <- read_html(html)
  iframe <- page |> html_element("iframe[src*='powerbigov.us'], iframe[src*='powerbi.com']")

  if (inherits(iframe, "xml_missing") || is.na(iframe)) {
    stop(
      "No embedded Power BI dashboard found on the DOH page. ",
      "The page structure may have changed — check the URL or update parse_cases()."
    )
  }

  src <- html_attr(iframe, "src")
  message("Found Power BI embed: ", src)
  src
}

decode_pbi_resource <- function(embed_url) {
  m <- str_match(embed_url, "[?&]r=([^&]+)")
  if (is.na(m[1, 2])) stop("Power BI embed URL is missing its 'r' parameter")

  decoded <- fromJSON(rawToChar(base64_dec(m[1, 2])))
  list(resource_key = decoded$k, tenant_id = decoded$t)
}

get_pbi_cluster_base <- function(embed_url) {
  html <- fetch_html(embed_url)
  m <- str_match(html, "resolvedClusterUri\\s*=\\s*'([^']+)'")
  if (is.na(m[1, 2])) stop("Could not find Power BI's resolvedClusterUri in the embed page")

  parsed <- url_parse(m[1, 2])
  host_parts <- str_split(parsed$hostname, fixed("."))[[1]]
  host_parts[1] <- host_parts[1] |> str_remove("-redirect$") |> str_remove("^global-")
  host_parts[1] <- paste0(host_parts[1], "-api")

  paste0(parsed$scheme, "://", paste(host_parts, collapse = "."))
}

# The API doesn't always send a proper "application/json" Content-Type
# (sometimes "text/plain"), so parse the body directly rather than relying
# on resp_body_json()'s content-type check.
pbi_perform <- function(req, url) {
  resp <- tryCatch(
    req |> req_timeout(30) |> req_perform(),
    error = function(e) stop("Power BI request failed (", url, "): ", conditionMessage(e))
  )
  if (resp_status(resp) != 200) stop("Power BI returned HTTP ", resp_status(resp), " for ", url)
  fromJSON(resp_body_string(resp), simplifyVector = FALSE)
}

pbi_get <- function(url, resource_key) {
  request(url) |>
    req_headers(
      `User-Agent` = UA_STRING,
      `Accept` = "application/json",
      `X-PowerBI-ResourceKey` = resource_key
    ) |>
    pbi_perform(url)
}

pbi_post <- function(url, resource_key, body) {
  request(url) |>
    req_headers(
      `User-Agent` = UA_STRING,
      `Accept` = "application/json",
      `X-PowerBI-ResourceKey` = resource_key
    ) |>
    req_body_json(body, auto_unbox = TRUE) |>
    pbi_perform(url)
}

# A visual's `map` filter value normally shows up in its own `query`'s Where
# clause, but Power BI sometimes ships a visual with an empty `query` (its
# filter state lives only in `filters` in that case) — check both.
extract_map_value <- function(vc) {
  query_json <- tryCatch(fromJSON(vc$query, simplifyVector = FALSE), error = function(e) NULL)
  where <- query_json$Commands[[1]]$SemanticQueryDataShapeCommand$Query$Where
  for (w in where) {
    cond <- w$Condition$In
    if (is.null(cond)) next
    if (!identical(cond$Expressions[[1]]$Column$Property, "map")) next
    return(str_remove_all(cond$Values[[1]][[1]]$Literal$Value, "'"))
  }

  filters <- tryCatch(fromJSON(vc$filters, simplifyVector = FALSE), error = function(e) NULL)
  for (f in filters) {
    if (!identical(tryCatch(f$expression$Column$Property, error = function(e) NULL), "map")) next
    cond <- tryCatch(f$filter$Where[[1]]$Condition$In, error = function(e) NULL)
    if (is.null(cond)) next
    return(str_remove_all(cond$Values[[1]][[1]]$Literal$Value, "'"))
  }

  NULL
}

# Clone a working visual's query, swapping its `map` Where-filter literal for
# a different map value — used to query visuals whose own `query` is empty
# (see extract_map_value()) since they share the same Select/entity shape.
build_query_for_map_value <- function(template_query, map_value) {
  q <- fromJSON(template_query, simplifyVector = FALSE)
  where <- q$Commands[[1]]$SemanticQueryDataShapeCommand$Query$Where
  for (i in seq_along(where)) {
    cond <- where[[i]]$Condition$In
    if (is.null(cond)) next
    if (!identical(cond$Expressions[[1]]$Column$Property, "map")) next
    q$Commands[[1]]$SemanticQueryDataShapeCommand$Query$Where[[i]]$
      Condition$In$Values[[1]][[1]]$Literal$Value <- paste0("'", map_value, "'")
  }
  toJSON(q, auto_unbox = TRUE)
}

# Find every tableEx visual, anywhere in the report, that is filtered on a
# `map` field — these are the county/case-count tables backing each map.
find_county_map_visuals <- function(exploration) {
  vc_map <- list()

  for (section in exploration$sections) {
    for (vc in section$visualContainers) {
      cfg <- tryCatch(fromJSON(vc$config, simplifyVector = FALSE), error = function(e) NULL)
      sv  <- cfg$singleVisual
      if (is.null(sv) || !identical(sv$visualType, "tableEx")) next

      map_value <- extract_map_value(vc)
      if (is.null(map_value)) next

      # `vc$id` (numeric) is what the querydata API wants as VisualId, but
      # bookmarks reference visuals by `cfg$name` (a hash-like string) —
      # keep both.
      vc_map[[map_value]] <- list(id = vc$id, name = cfg$name, query = vc$query)
    }
  }

  if (length(vc_map) == 0) {
    stop(
      "No county case-count table visuals found in the Power BI report. ",
      "The dashboard layout may have changed — check the embed or update parse_cases()."
    )
  }

  # Some visuals' `query` may be empty (see extract_map_value()) — fill those
  # in from any sibling visual that does have one, since they share the same
  # Select/entity shape and only differ in their `map` filter value.
  template_query <- NULL
  for (v in vc_map) {
    if (!is.null(v$query) && nchar(v$query) > 0) {
      template_query <- v$query
      break
    }
  }
  if (!is.null(template_query)) {
    for (map_value in names(vc_map)) {
      if (is.null(vc_map[[map_value]]$query) || nchar(vc_map[[map_value]]$query) == 0) {
        vc_map[[map_value]]$query <- build_query_for_map_value(template_query, map_value)
      }
    }
  }

  vc_map
}

# The `map` field's values (e.g. "ob1"/"ob2") aren't self-describing, so match
# each one to an outbreak number via the report's own "January.../April..."
# bookmarks, which reveal which table each bookmark makes visible.
map_bookmarks_to_outbreaks <- function(exploration, vc_map) {
  cfg <- fromJSON(exploration$config, simplifyVector = FALSE)
  outbreak_for_map_value <- list()

  for (bm in cfg$bookmarks) {
    name_lower <- str_to_lower(bm$displayName)
    ob_num <- NA_integer_
    for (fragment in names(PBI_HEADING_MAP)) {
      if (str_detect(name_lower, fixed(fragment))) {
        ob_num <- PBI_HEADING_MAP[[fragment]]
        break
      }
    }
    if (is.na(ob_num)) next

    for (sec_state in bm$explorationState$sections) {
      for (vc_id in names(sec_state$visualContainers)) {
        sv <- sec_state$visualContainers[[vc_id]]$singleVisual
        if (is.null(sv) || !identical(sv$visualType, "tableEx")) next
        if (identical(sv$display$mode, "hidden")) next

        for (map_value in names(vc_map)) {
          if (identical(vc_map[[map_value]]$name, vc_id)) {
            outbreak_for_map_value[[map_value]] <- ob_num
          }
        }
      }
    }
  }

  if (length(outbreak_for_map_value) == 0) {
    stop(
      "Could not match any Power BI 'map' field value to an outbreak via ",
      "bookmarks — the report's bookmarks may have changed."
    )
  }

  outbreak_for_map_value
}

# Decode a Power BI DSR row set, expanding the "R" repeat-from-previous-row
# bitmask compression PBI uses when adjacent rows share a column value.
decode_dsr_rows <- function(dm1) {
  n_cols <- length(dm1[[1]]$S)
  prev   <- vector("list", n_cols)
  county <- character(0)
  cases  <- integer(0)

  for (item in dm1) {
    c_vals <- item$C
    r_mask <- item$R
    ci <- 1
    row_vals <- vector("list", n_cols)
    for (col in seq_len(n_cols)) {
      repeated <- !is.null(r_mask) && bitwAnd(as.integer(r_mask), bitwShiftL(1L, col - 1)) != 0
      if (repeated) {
        row_vals[[col]] <- prev[[col]]
      } else {
        row_vals[[col]] <- c_vals[[ci]]
        ci <- ci + 1
      }
    }
    prev <- row_vals
    county <- c(county, as.character(row_vals[[1]]))
    cases  <- c(cases, as.integer(row_vals[[2]]))
  }

  tibble(county = county, new_cases = cases)
}

# Build once per scrape: everything needed to run further queries against
# this report (cluster host, resource key, dataset/model ids, full layout).
build_pbi_context <- function(html) {
  embed_url    <- extract_pbi_embed_url(html)
  resource     <- decode_pbi_resource(embed_url)
  cluster_base <- get_pbi_cluster_base(embed_url)

  exploration_resp <- pbi_get(
    paste0(cluster_base, "/public/reports/", resource$resource_key, "/modelsAndExploration?preferReadOnlySession=true"),
    resource$resource_key
  )

  list(
    cluster_base = cluster_base,
    resource_key = resource$resource_key,
    model_id     = exploration_resp$models[[1]]$id,
    dataset_id   = exploration_resp$models[[1]]$dbName,
    report_id    = exploration_resp$exploration$reportId,
    exploration  = exploration_resp$exploration
  )
}

# Run a visual's own query (as captured in the report layout) against the
# querydata endpoint and return the raw DSR result set.
query_pbi_visual <- function(ctx, vc) {
  body <- list(
    version = "1.0.0",
    queries = list(list(
      Query = fromJSON(vc$query, simplifyVector = FALSE),
      QueryId = "",
      ApplicationContext = list(
        DatasetId = ctx$dataset_id,
        Sources = list(list(ReportId = as.character(ctx$report_id), VisualId = vc$id))
      )
    )),
    cancelQueries = list(),
    modelId = ctx$model_id
  )

  result <- pbi_post(paste0(ctx$cluster_base, "/public/reports/querydata?synchronous=true"), ctx$resource_key, body)
  result$results[[1]]$result$data$dsr
}

query_pbi_county_table <- function(ctx, vc) {
  dsr <- query_pbi_visual(ctx, vc)
  dm1 <- NULL
  for (ph in dsr$DS[[1]]$PH) {
    if (!is.null(ph$DM1)) { dm1 <- ph$DM1; break }
  }
  if (is.null(dm1)) stop("Power BI query returned no county rows (DM1 missing)")

  decode_dsr_rows(dm1)
}

parse_cases <- function(ctx) {
  today <- as.character(Sys.Date())

  vc_map               <- find_county_map_visuals(ctx$exploration)
  outbreak_for_map_val <- map_bookmarks_to_outbreaks(ctx$exploration, vc_map)

  rows <- list()
  for (map_value in names(outbreak_for_map_val)) {
    ob_num <- outbreak_for_map_val[[map_value]]
    counts <- query_pbi_county_table(ctx, vc_map[[map_value]])
    message("Outbreak ", ob_num, " (map='", map_value, "'): ", sum(counts$new_cases), " total cases")

    rows[[length(rows) + 1]] <- counts |>
      mutate(date = today, source = SOURCE_URL, outbreak = ob_num) |>
      select(date, new_cases, county, source, outbreak)
  }

  if (length(rows) == 0) {
    stop(
      "No case data extracted from the Power BI dashboard. ",
      "The report structure may have changed — check the embed or update parse_cases()."
    )
  }

  result <- bind_rows(rows)
  message("Parsed ", nrow(result), " county totals from the Power BI dashboard")
  result
}

# ---------------------------------------------------------------------------
# Hospitalizations (statewide YTD cumulative — not broken out by county)
# ---------------------------------------------------------------------------

# Find a cardVisual anywhere in the report that displays Sum(<property>) —
# used to locate the "Hospitalized" card without hardcoding its visual id.
find_card_visual_by_property <- function(exploration, property_name) {
  for (section in exploration$sections) {
    for (vc in section$visualContainers) {
      cfg <- tryCatch(fromJSON(vc$config, simplifyVector = FALSE), error = function(e) NULL)
      sv  <- cfg$singleVisual
      if (is.null(sv) || !identical(sv$visualType, "cardVisual")) next

      query_json <- tryCatch(fromJSON(vc$query, simplifyVector = FALSE), error = function(e) NULL)
      select <- query_json$Commands[[1]]$SemanticQueryDataShapeCommand$Query$Select
      if (is.null(select)) next

      for (s in select) {
        prop <- s$Aggregation$Expression$Column$Property
        if (identical(prop, property_name)) return(list(id = vc$id, query = vc$query))
      }
    }
  }
  NULL
}

# Card-visual queries return a single aggregate value in DM0, keyed by
# whatever name the DSR assigned it (usually "M0") rather than a fixed key.
extract_dsr_scalar <- function(dsr) {
  for (ph in dsr$DS[[1]]$PH) {
    if (!is.null(ph$DM0)) {
      row <- ph$DM0[[1]]
      key <- row$S[[1]]$N
      return(as.integer(row[[key]]))
    }
  }
  stop("Power BI query returned no scalar value (DM0 missing)")
}

# Statewide cumulative hospitalizations, year-to-date, straight from the
# dashboard's own "Hospitalized" card — not available broken out by county.
fetch_hospitalization_total <- function(ctx) {
  vc <- find_card_visual_by_property(ctx$exploration, "hosp")
  if (is.null(vc)) {
    stop(
      "No 'Hospitalized' card visual found in the Power BI report. ",
      "The dashboard layout may have changed — check the embed or update fetch_hospitalization_total()."
    )
  }
  extract_dsr_scalar(query_pbi_visual(ctx, vc))
}

# ---------------------------------------------------------------------------
# TSV helpers
# ---------------------------------------------------------------------------

load_tsv_data <- function(path) {
  if (!file.exists(path)) {
    message("TSV not found at '", path, "' — will create a new one on first write")
    return(
      tibble(
        date      = character(),
        new_cases = integer(),
        county    = character(),
        source    = character(),
        outbreak  = integer()
      )
    )
  }
  df <- read_tsv(path, col_types = cols(.default = "c"), show_col_types = FALSE)
  df$new_cases <- as.integer(df$new_cases)
  df$outbreak  <- as.integer(df$outbreak)
  message("Loaded ", nrow(df), " existing rows from '", path, "'")
  df
}

save_tsv_data <- function(df, path) {
  for (col in TSV_COLS) {
    if (!col %in% names(df)) df[[col]] <- NA
  }
  write_tsv(df[, TSV_COLS], path, na = "")
  message("Saved ", nrow(df), " rows to '", path, "'")
}

# measles_weekly.tsv is the full, authoritative weekly record — one row per
# week going back to the start of the outbreak, with two independently
# maintained columns:
#   - `new_cases`: synced from measles_daily.tsv's scrape-date rollup every
#     run, EXCEPT for weeks flagged `adjusted` (e.g. a lump-sum catch-up
#     delta after a scraper outage misattributes cases to the wrong week) —
#     those are hand-corrected and never auto-overwritten. See README.
#   - `hospitalizations`: statewide cumulative hospitalizations aren't
#     available broken out by day/county, only as a running YTD total on
#     the dashboard — so each scrape run derives *this week's* new
#     hospitalizations by diffing that total against the sum of all other
#     weeks already recorded here, and writes the result back. Blank for
#     any week before we started tracking it.
# Kept separate from measles_daily.tsv so that file stays an honest record
# of actual scrape dates. See README.
WEEKLY_TSV_COLS <- c("week_start", "new_cases", "adjusted", "hospitalizations", "note")

load_weekly_tsv <- function(path) {
  if (!file.exists(path)) {
    return(tibble(
      week_start       = character(),
      new_cases        = integer(),
      adjusted         = logical(),
      hospitalizations = integer(),
      note             = character()
    ))
  }

  df <- read_tsv(path, col_types = cols(.default = "c"), show_col_types = FALSE)
  df$new_cases        <- as.integer(df$new_cases)
  df$adjusted          <- !is.na(df$adjusted) & df$adjusted == "TRUE"
  df$hospitalizations <- as.integer(df$hospitalizations)
  message("Loaded ", nrow(df), " week(s) from '", path, "'")
  df
}

save_weekly_tsv <- function(df, path) {
  for (col in WEEKLY_TSV_COLS) {
    if (!col %in% names(df)) df[[col]] <- NA
  }
  df <- df[order(df$week_start), WEEKLY_TSV_COLS]
  df$adjusted <- ifelse(df$adjusted, "TRUE", NA)
  write_tsv(df, path, na = "")
  message("Saved ", nrow(df), " week(s) to '", path, "'")
}

# Refresh `new_cases` for every week from measles_daily.tsv's scrape-date
# rollup, except weeks marked `adjusted` (hand-corrected, left untouched).
# Adds a row for any new week that's shown up in measles_daily.tsv but isn't
# in the weekly file yet.
sync_weekly_case_counts <- function(weekly_df, daily_df) {
  computed <- daily_df |>
    filter(!is.na(date) & date != "") |>
    mutate(week_start = as.character(as.Date(cut(as.Date(date), "week")))) |>
    group_by(week_start) |>
    summarise(new_cases = sum(new_cases, na.rm = TRUE), .groups = "drop")

  for (i in seq_len(nrow(computed))) {
    wk  <- computed$week_start[i]
    val <- computed$new_cases[i]

    if (wk %in% weekly_df$week_start) {
      is_adjusted <- isTRUE(weekly_df$adjusted[weekly_df$week_start == wk])
      if (!is_adjusted) {
        weekly_df$new_cases[weekly_df$week_start == wk] <- val
      }
    } else {
      weekly_df <- bind_rows(weekly_df, tibble(
        week_start = wk, new_cases = val, adjusted = FALSE,
        hospitalizations = NA_integer_, note = NA_character_
      ))
    }
  }

  weekly_df |> arrange(week_start)
}

# This week's new hospitalizations = current YTD cumulative total minus
# whatever's already accounted for in every *other* week on record. Blank/NA
# weeks contribute nothing to that baseline, so the very first time this
# runs, the whole YTD total lands on the current week (there's no way to
# know how it was distributed across earlier, untracked weeks).
update_weekly_hospitalizations <- function(weekly_df, current_week_start, ytd_total) {
  known_prior <- weekly_df |>
    filter(week_start != current_week_start) |>
    pull(hospitalizations) |>
    sum(na.rm = TRUE)

  this_week <- as.integer(ytd_total - known_prior)
  message(sprintf(
    "Hospitalizations: %d cumulative YTD, %d new this week (week of %s)",
    ytd_total, this_week, current_week_start
  ))

  if (current_week_start %in% weekly_df$week_start) {
    weekly_df$hospitalizations[weekly_df$week_start == current_week_start] <- this_week
  } else {
    weekly_df <- bind_rows(weekly_df, tibble(
      week_start = current_week_start, new_cases = NA_integer_, adjusted = FALSE,
      hospitalizations = this_week, note = NA_character_
    ))
  }

  weekly_df
}

# ---------------------------------------------------------------------------
# Delta logic
# ---------------------------------------------------------------------------

county_totals_from_tsv <- function(existing, outbreak_num) {
  existing |>
    filter(outbreak == outbreak_num) |>
    group_by(county) |>
    summarise(known_total = sum(new_cases, na.rm = TRUE), .groups = "drop")
}

build_new_rows <- function(snapshot, existing) {
  today <- as.character(Sys.Date())
  new_rows <- list()

  for (i in seq_len(nrow(snapshot))) {
    ob     <- snapshot$outbreak[i]
    county <- snapshot$county[i]
    snap_n <- snapshot$new_cases[i]

    totals    <- county_totals_from_tsv(existing, ob)
    known_row <- totals |> filter(county == !!county)
    known_n   <- if (nrow(known_row) == 0) 0L else known_row$known_total

    delta <- snap_n - known_n

    if (delta > 0) {
      message(sprintf("NEW: +%d case(s) in %s County (outbreak %d)", delta, county, ob))
      new_rows[[length(new_rows) + 1]] <- tibble(
        date      = today,
        new_cases = delta,
        county    = county,
        source    = "Scrape of PDOH measles webpage",
        outbreak  = ob
      )
    } else if (delta < 0) {
      warning(sprintf(
        "ANOMALY: DOH total for %s County (outbreak %d) decreased from %d to %d — skipping",
        county, ob, known_n, snap_n
      ))
    } else {
      message(sprintf("No change: %s County (outbreak %d)", county, ob))
    }
  }

  if (length(new_rows) == 0) return(NULL)
  bind_rows(new_rows)
}

# ---------------------------------------------------------------------------
# Update the standalone embed HTML files (cases-by-year-embed.html,
# map-by-outbreak-embed.html, map-combined-embed.html, weekly-trend-embed.html)
# — each is a self-contained page meant to be hosted at a
# stable URL and iframed into the CMS. Rather than a dashboard reading a
# shared data.json at runtime, every embed keeps its data inlined as JS
# constants between a pair of marker comments, and this scraper rewrites
# just that block in place on every run — so each embed stays a single,
# fully self-contained file with nothing else to fetch or cache. See README.
# ---------------------------------------------------------------------------

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

# Per-county ob1/ob2/total, mirroring the map's caseData shape.
compute_case_data <- function(daily_df) {
  daily_df |>
    group_by(county, outbreak) |>
    summarise(total_cases = sum(new_cases, na.rm = TRUE), .groups = "drop") |>
    group_by(county) |>
    summarise(
      ob1   = sum(total_cases[outbreak == 1], na.rm = TRUE),
      ob2   = sum(total_cases[outbreak == 2], na.rm = TRUE),
      total = sum(total_cases, na.rm = TRUE),
      .groups = "drop"
    ) |>
    arrange(county)
}

update_bar_embed <- function(total_cases, path) {
  inject_embed_data(path, sprintf("  const totalCases = %d;", total_cases))
}

update_map_embed <- function(case_data, total_cases, current_ob, prior_ob, last_updated, path) {
  entries <- sprintf(
    '  "%s": { ob1: %d, ob2: %d }',
    case_data$county, case_data$ob1, case_data$ob2
  )
  entries[-length(entries)] <- paste0(entries[-length(entries)], ",")

  js_lines <- c(
    sprintf("  const totalCases = %d;", total_cases),
    sprintf("  const currentOb = %d;", current_ob),
    sprintf("  const priorOb = %d;", prior_ob),
    sprintf('  const lastUpdated = "%s";', last_updated),
    "  const caseData = {",
    entries,
    "  };"
  )
  inject_embed_data(path, js_lines)
}

update_total_map_embed <- function(case_data, total_cases, last_updated, path) {
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

message("\n=== Starting scrape job: ", format(Sys.time()), " ===")

tryCatch({
  html     <- fetch_html(SOURCE_URL)
  pbi_ctx  <- build_pbi_context(html)
  snapshot <- parse_cases(pbi_ctx)
  existing <- load_tsv_data(tsv_path)
  new_rows <- build_new_rows(snapshot, existing)

  if (!is.null(new_rows)) {
    updated <- bind_rows(existing, new_rows)
    save_tsv_data(updated, tsv_path)
    message("Added ", nrow(new_rows), " new row(s) to '", tsv_path, "'")
  } else {
    updated <- existing
    message("No new cases — TSV unchanged")
  }

  # Sync measles_weekly.tsv: refresh new_cases from the daily rollup (except
  # hand-adjusted weeks), then fold in this week's hospitalization figure.
  # Hospitalization fetch is non-fatal — if it fails, the case-count sync
  # still gets saved, just without a hospitalizations update this run.
  weekly_tsv <- load_weekly_tsv(WEEKLY_TSV) |>
    sync_weekly_case_counts(updated)

  tryCatch({
    hosp_total         <- fetch_hospitalization_total(pbi_ctx)
    current_week_start <- as.character(as.Date(cut(Sys.Date(), "week")))
    weekly_tsv <- update_weekly_hospitalizations(weekly_tsv, current_week_start, hosp_total)
  }, error = function(e) {
    message("WARNING: Hospitalization update failed — ", conditionMessage(e))
  })

  save_weekly_tsv(weekly_tsv, WEEKLY_TSV)

  # Skip updating any embed whose file isn't present, rather than failing
  # the run — keeps this resilient if an embed is ever removed or renamed.
  embed_paths <- c(BAR_EMBED_HTML, MAP_EMBED_HTML, MAP_TOTAL_EMBED_HTML, WEEKLY_EMBED_HTML)
  if (any(file.exists(embed_paths))) {
    case_data        <- compute_case_data(updated)
    total_cases      <- sum(case_data$total)
    current_outbreak <- sum(case_data$ob2)
    prior_outbreak   <- sum(case_data$ob1)
    last_updated     <- format(Sys.Date(), "%B %e, %Y") |> trimws()

    if (file.exists(BAR_EMBED_HTML)) {
      update_bar_embed(total_cases, BAR_EMBED_HTML)
    }
    if (file.exists(MAP_EMBED_HTML)) {
      update_map_embed(case_data, total_cases, current_outbreak, prior_outbreak, last_updated, MAP_EMBED_HTML)
    }
    if (file.exists(MAP_TOTAL_EMBED_HTML)) {
      update_total_map_embed(case_data, total_cases, last_updated, MAP_TOTAL_EMBED_HTML)
    }

    weekly_for_embed <- weekly_tsv |>
      arrange(week_start) |>
      mutate(cumulative_cases = cumsum(coalesce(new_cases, 0L)))
    if (file.exists(WEEKLY_EMBED_HTML)) {
      update_weekly_embed(weekly_for_embed, WEEKLY_EMBED_HTML)
    }

    message(sprintf(
      "Updated embeds — %d total cases across %d counties (as of %s)",
      total_cases, nrow(filter(case_data, total > 0)), last_updated
    ))
  }
},
error = function(e) {
  message("ERROR: Scrape job failed: ", conditionMessage(e))
})

message("=== Scrape job complete ===\n")
