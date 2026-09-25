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
DEFAULT_TSV         <- "data/daily_cases_by_county.tsv"
WEEKLY_TSV          <- "data/summary_weekly.tsv"
AGE_GROUP_TSV       <- "data/daily_cases_by_age_group.tsv"
DAILY_HOSP_TSV      <- "data/daily_hospitalization_by_age_group.tsv"
SUMMARY_TSV         <- "data/summary_daily.tsv"
TSV_COLS            <- c("date", "county", "new_cases", "cumulative_cases", "source")

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
#      `Where` filter on a `map` field — and run the year-to-date one
#      (`map` = "ytd") against `<cluster>/public/reports/querydata`.
# ---------------------------------------------------------------------------

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
#
# Power BI's publish-to-web session cache can intermittently return a
# 200 with an empty body — the same underlying flakiness noted elsewhere
# in this file for the county tables (see find_county_map_visuals()), but
# here it surfaces as fromJSON() choking on an empty string ("Argument
# 'txt' must be a JSON string, URL or file") rather than a missing
# `query`. Observed 2026-08-2x on the age-group chart specifically,
# breaking that fetch for several days straight since it had no retry.
# A short retry loop clears it almost every time, so retry before giving
# up rather than failing the (possibly non-fatal) caller outright.
pbi_perform <- function(req, url, max_attempts = 3) {
  for (attempt in seq_len(max_attempts)) {
    resp <- tryCatch(
      req |> req_timeout(30) |> req_perform(),
      error = function(e) stop("Power BI request failed (", url, "): ", conditionMessage(e))
    )
    if (resp_status(resp) != 200) stop("Power BI returned HTTP ", resp_status(resp), " for ", url)

    body   <- resp_body_string(resp)
    parsed <- if (nchar(trimws(body)) > 0) tryCatch(fromJSON(body, simplifyVector = FALSE), error = function(e) NULL) else NULL
    if (!is.null(parsed)) return(parsed)

    if (attempt < max_attempts) {
      message("Power BI returned an empty/invalid response for ", url, " — retrying (attempt ", attempt, "/", max_attempts, ")")
      Sys.sleep(2)
    }
  }
  stop("Power BI returned an empty or invalid response after ", max_attempts, " attempts (", url, ")")
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
# filter state lives only in `filters` in that case) — check both. When found
# via `filters`, also return that filter's own Where clause: combined with
# the visual's prototypeQuery (see find_county_map_visuals()), that's enough
# to build a full query for this visual without needing a sibling's query to
# clone (see build_query_from_prototype()) — needed because Power BI's
# publish-to-web reports cache each visual's `query` as part of report
# session state, and that cache can go empty for every table simultaneously
# after the underlying dataset refreshes, until some live viewer re-renders
# them (observed 2026-08-08: all three county tables empty at once).
extract_map_value <- function(vc) {
  query_json <- tryCatch(fromJSON(vc$query, simplifyVector = FALSE), error = function(e) NULL)
  where <- query_json$Commands[[1]]$SemanticQueryDataShapeCommand$Query$Where
  for (w in where) {
    cond <- w$Condition$In
    if (is.null(cond)) next
    if (!identical(cond$Expressions[[1]]$Column$Property, "map")) next
    return(list(value = str_remove_all(cond$Values[[1]][[1]]$Literal$Value, "'"), where = NULL))
  }

  filters <- tryCatch(fromJSON(vc$filters, simplifyVector = FALSE), error = function(e) NULL)
  for (f in filters) {
    if (!identical(tryCatch(f$expression$Column$Property, error = function(e) NULL), "map")) next
    cond <- tryCatch(f$filter$Where[[1]]$Condition$In, error = function(e) NULL)
    if (is.null(cond)) next
    return(list(
      value = str_remove_all(cond$Values[[1]][[1]]$Literal$Value, "'"),
      where = f$filter$Where
    ))
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

# Build a query from a visual's own prototypeQuery (Select/From, always
# present in its config) plus its map filter's own Where clause (from
# extract_map_value()) — used when NO visual in the report has a populated
# `query` to clone via build_query_for_map_value(). Unlike a cloned query,
# this always uses a single flat Binding grouping, which Power BI returns
# under the DSR's DM0 key rather than DM1 — see query_pbi_county_table().
build_query_from_prototype <- function(prototype_query, where) {
  if (is.null(prototype_query) || is.null(where)) {
    stop(
      "Cannot build a query for a table visual with neither its own `query`, ",
      "nor a sibling's to clone, nor a prototypeQuery/map filter to build one from."
    )
  }
  q <- list(Commands = list(list(SemanticQueryDataShapeCommand = list(
    Query = list(
      Version = prototype_query$Version,
      From    = prototype_query$From,
      Select  = prototype_query$Select,
      Where   = where
    ),
    Binding = list(
      Primary        = list(Groupings = list(list(Projections = as.list(seq_along(prototype_query$Select) - 1L)))),
      DataReduction  = list(DataVolume = 4, Primary = list(Window = list(Count = 1000))),
      Version        = 1
    ),
    ExecutionMetricsKind = 1
  ))))
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

      map_info <- extract_map_value(vc)
      if (is.null(map_info)) next

      # `vc$id` (numeric) is what the querydata API wants as VisualId, but
      # bookmarks reference visuals by `cfg$name` (a hash-like string) —
      # keep both.
      vc_map[[map_info$value]] <- list(
        id = vc$id, name = cfg$name, query = vc$query,
        prototype_query = sv$prototypeQuery, where = map_info$where
      )
    }
  }

  if (length(vc_map) == 0) {
    stop(
      "No county case-count table visuals found in the Power BI report. ",
      "The dashboard layout may have changed — check the embed or update parse_cases()."
    )
  }

  # Some visuals' `query` may be empty (see extract_map_value()) — prefer
  # filling those in from any sibling visual that does have one, since it's
  # cheap and known to match Power BI's usual DSR shape (DM1). If no sibling
  # has one either, fall back to building the query from the visual's own
  # prototypeQuery + map Where clause (see build_query_from_prototype()).
  template_query <- NULL
  for (v in vc_map) {
    if (!is.null(v$query) && nchar(v$query) > 0) {
      template_query <- v$query
      break
    }
  }
  for (map_value in names(vc_map)) {
    if (!is.null(vc_map[[map_value]]$query) && nchar(vc_map[[map_value]]$query) > 0) next
    vc_map[[map_value]]$query <- if (!is.null(template_query)) {
      build_query_for_map_value(template_query, map_value)
    } else {
      build_query_from_prototype(vc_map[[map_value]]$prototype_query, vc_map[[map_value]]$where)
    }
  }

  vc_map
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

# Rewrite every SourceRef in a PBIR expression tree to point at a query-level
# `From` alias. PBIR projections reference tables as {Entity: "..."}, while
# filters reference their own local aliases ({Source: "p"}) declared in that
# filter's own From — `local_aliases` maps those local names to entities.
pbir_rewrite_source_refs <- function(node, entity_alias, local_aliases = list()) {
  if (!is.list(node)) return(node)
  if (!is.null(names(node)) && "SourceRef" %in% names(node)) {
    ref <- node$SourceRef
    entity <- if (!is.null(ref$Entity)) ref$Entity else local_aliases[[ref$Source]]
    node$SourceRef <- list(Source = entity_alias[[entity]])
  }
  for (i in seq_along(node)) {
    if (is.list(node[[i]])) node[[i]] <- pbir_rewrite_source_refs(node[[i]], entity_alias, local_aliases)
  }
  node
}

# Build a legacy SemanticQuery (the shape the querydata API expects, and what
# the legacy layout shipped pre-built in each visual's `query`) from a PBIR
# visual's queryState projections plus its filterConfig's filter clauses.
# Uses a single flat grouping, so results come back under DM0 (see
# query_pbi_county_table()).
pbir_build_query <- function(visual, filters) {
  entity_alias <- list()
  add_entity <- function(entity) {
    if (is.null(entity_alias[[entity]])) {
      entity_alias[[entity]] <<- paste0("t", length(entity_alias))
    }
  }
  collect_entities <- function(node) {
    if (!is.list(node)) return(invisible())
    if (!is.null(node$SourceRef$Entity)) add_entity(node$SourceRef$Entity)
    for (child in node) collect_entities(child)
  }

  projections   <- list()
  show_no_data  <- integer(0)
  for (role in visual$query$queryState) {
    for (p in role$projections) {
      collect_entities(p$field)
      projections[[length(projections) + 1]] <- p
      if (isTRUE(role$showAll)) show_no_data <- c(show_no_data, length(projections) - 1L)
    }
  }
  if (length(projections) == 0) return(NULL)

  where <- list()
  for (f in filters) {
    if (is.null(f$filter$Where)) next
    # Subquery sources (e.g. a TopN filter on the Community Transmission
    # tab's date card) have no Entity — none of the visuals this scraper
    # queries use one, so drop those filters instead of translating them.
    has_subquery <- any(vapply(f$filter$From, function(src) is.null(src$Entity), logical(1)))
    if (has_subquery) next
    local_aliases <- list()
    for (src in f$filter$From) {
      local_aliases[[src$Name]] <- src$Entity
      add_entity(src$Entity)
    }
    for (w in f$filter$Where) {
      where[[length(where) + 1]] <- pbir_rewrite_source_refs(w, entity_alias, local_aliases)
    }
  }

  select <- lapply(projections, function(p) {
    s <- pbir_rewrite_source_refs(p$field, entity_alias)
    s$Name <- p$queryRef
    s
  })
  from <- lapply(names(entity_alias), function(e) list(Name = entity_alias[[e]], Entity = e, Type = 0L))

  grouping <- list(Projections = as.list(seq_along(select) - 1L))
  if (length(show_no_data) > 0) grouping$ShowItemsWithNoData <- as.list(show_no_data)

  query <- list(Version = 2L, From = from, Select = select)
  if (length(where) > 0) query$Where <- where

  list(
    prototype_query = query,
    query = list(Commands = list(list(SemanticQueryDataShapeCommand = list(
      Query   = query,
      Binding = list(
        Primary       = list(Groupings = list(grouping)),
        DataReduction = list(DataVolume = 4, Primary = list(Window = list(Count = 1000))),
        Version       = 1
      ),
      ExecutionMetricsKind = 1
    ))))
  )
}

# As of 2026-09-23 the DOH report is published in Power BI's PBIR format:
# `sections[].visualContainers[]` only carry id/position/objectName, and the
# real definitions (visual type, fields, filters, bookmarks) live in
# `explorationContent$explorationDocument`, a JSON string with a different
# schema. Rather than teach every finder both formats, rebuild the legacy
# fields they read — each container's `config`/`query`/`filters` and the
# exploration's `config$bookmarks` — from the PBIR document. A no-op on a
# legacy-format report.
normalize_pbir_exploration <- function(exploration) {
  doc_json <- exploration$explorationContent$explorationDocument
  if (is.null(doc_json)) return(exploration)
  doc <- fromJSON(doc_json, simplifyVector = FALSE)

  # Each page also has a "Select a Time Period" slicer (TimeFrame, defaulting
  # to 'Year to date') that cross-filters the other visuals on that page.
  # PAmeasles2026_Public holds a row set per time frame, so without the
  # slicer's selection every statewide total comes back summed across all of
  # them (observed 2026-09-23: 1,670 cases instead of 835). The legacy
  # layout's pre-built `query` baked this in; PBIR doesn't, so apply each
  # page's slicer selections to its other visuals ourselves.
  pbir_visuals  <- list()
  page_slicers  <- list()
  page_no_filter <- list()
  for (page in doc$pages$pages) {
    page_name <- page$content$name
    page_slicers[[page_name]] <- list()
    for (vc in page$visualContainers) {
      pbir_visuals[[vc$content$name]] <- vc$content
      v <- vc$content$visual
      if (is.null(v$visualType) || !str_detect(str_to_lower(v$visualType), "slicer")) next
      for (g in v$objects$general) {
        sel <- g$properties$filter$filter
        if (is.null(sel)) next
        page_slicers[[page_name]][[length(page_slicers[[page_name]]) + 1]] <- list(
          slicer = vc$content$name, filter = list(filter = sel)
        )
      }
    }
    page_no_filter[[page_name]] <- Filter(
      function(i) identical(i$type, "NoFilter"), page$content$visualInteractions
    )
  }

  for (si in seq_along(exploration$sections)) {
    page_name  <- exploration$sections[[si]]$objectName
    containers <- exploration$sections[[si]]$visualContainers
    for (vi in seq_along(containers)) {
      vc <- containers[[vi]]
      if (!is.null(vc$config)) next
      pv <- pbir_visuals[[vc$objectName]]
      if (is.null(pv$visual)) next

      filters <- pv$filterConfig$filters
      slicer_filters <- list()
      for (s in page_slicers[[page_name]]) {
        if (identical(s$slicer, pv$name)) next
        blocked <- any(vapply(page_no_filter[[page_name]], function(i) {
          identical(i$source, s$slicer) && identical(i$target, pv$name)
        }, logical(1)))
        if (!blocked) slicer_filters[[length(slicer_filters) + 1]] <- s$filter
      }
      built <- pbir_build_query(pv$visual, c(filters, slicer_filters))

      vc$config <- toJSON(list(
        name = pv$name,
        singleVisual = list(visualType = pv$visual$visualType, prototypeQuery = built$prototype_query)
      ), auto_unbox = TRUE, digits = NA)
      vc$query <- if (is.null(built)) "" else toJSON(built$query, auto_unbox = TRUE, digits = NA)
      vc$filters <- toJSON(lapply(filters, function(f) {
        list(name = f$name, expression = f$field, filter = f$filter)
      }), auto_unbox = TRUE, digits = NA)
      containers[[vi]] <- vc
    }
    exploration$sections[[si]]$visualContainers <- containers
  }

  if (is.null(exploration$config)) {
    bookmarks <- lapply(doc$bookmarks$bookmarks, function(b) b$content)
    exploration$config <- toJSON(list(bookmarks = bookmarks), auto_unbox = TRUE, digits = NA)
  }

  exploration
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
    exploration  = normalize_pbir_exploration(exploration_resp$exploration)
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
  ph_list <- dsr$DS[[1]]$PH

  # DM1 is what a cloned/original two-level-binding query returns; DM0 is
  # what build_query_from_prototype()'s single flat grouping level produces
  # instead — both use the same row-set encoding. Power BI can also emit a
  # separate PH entry holding an unrelated scalar aggregate under DM0 (e.g.
  # a row-count summary) alongside the real DM1 rows, so scan every PH entry
  # for DM1 first and only fall back to DM0 if none of them have one —
  # otherwise the aggregate's single-value DM0 gets mistaken for row data
  # (observed 2026-08-10: a report add of that summary PH broke this).
  dm1 <- NULL
  for (ph in ph_list) {
    if (!is.null(ph$DM1)) { dm1 <- ph$DM1; break }
  }
  if (is.null(dm1)) {
    for (ph in ph_list) {
      if (!is.null(ph$DM0)) { dm1 <- ph$DM0; break }
    }
  }
  if (is.null(dm1)) stop("Power BI query returned no county rows (DM1/DM0 missing)")

  decode_dsr_rows(dm1)
}

# The report's "ytd" county table holds each county's year-to-date case
# total (PDOH's own column is named `new_cases`, but it's cumulative), so it
# comes back as `cumulative_cases` here.
PBI_YTD_MAP_VALUE <- "ytd"

parse_cases <- function(ctx) {
  vc_map <- find_county_map_visuals(ctx$exploration)
  vc     <- vc_map[[PBI_YTD_MAP_VALUE]]
  if (is.null(vc)) {
    stop(
      "No year-to-date county table (map='", PBI_YTD_MAP_VALUE, "') found in the Power BI dashboard. ",
      "The report structure may have changed — check the embed or update parse_cases()."
    )
  }

  result <- query_pbi_county_table(ctx, vc) |>
    select(county, cumulative_cases = new_cases)
  message("Parsed ", nrow(result), " county totals (", sum(result$cumulative_cases), " cases) from the Power BI dashboard")
  result
}

# ---------------------------------------------------------------------------
# Hospitalizations (statewide YTD cumulative — not broken out by county) —
# the dashboard's "Hospitalization" tab breaks its cumulative hospitalization
# count into three cards: total, under-18, and 18+.
# ---------------------------------------------------------------------------

# Find a cardVisual anywhere in the report that displays Sum(<property>) —
# used to locate a specific stat card without hardcoding its visual id.
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
# The hospitalization cards render their measure as text (e.g. "83 of  460",
# i.e. "<hospitalized> of <total cases>") rather than a bare number, so pull
# out the leading integer instead of coercing the whole string.
extract_dsr_scalar <- function(dsr) {
  for (ph in dsr$DS[[1]]$PH) {
    if (!is.null(ph$DM0)) {
      row <- ph$DM0[[1]]
      key <- row$S[[1]]$N
      raw <- as.character(row[[key]])
      m   <- str_match(raw, "-?\\d+")
      if (is.na(m[1, 1])) stop("Could not parse a numeric value from Power BI scalar: '", raw, "'")
      return(as.integer(m[1, 1]))
    }
  }
  stop("Power BI query returned no scalar value (DM0 missing)")
}

# Maps each hospitalization category to the `property` name of its card
# visual on the dashboard's Hospitalization tab.
HOSP_CATEGORY_PROPERTIES <- c(total = "hosptotal", children = "hospunder18", adult = "hosp18plus")

# Statewide cumulative hospitalizations, year-to-date, for each of the three
# categories the dashboard tracks (total / under-18 / 18+) — not available
# broken out by county.
fetch_hospitalization_snapshot <- function(ctx) {
  rows <- list()
  for (category in names(HOSP_CATEGORY_PROPERTIES)) {
    property <- HOSP_CATEGORY_PROPERTIES[[category]]
    vc <- find_card_visual_by_property(ctx$exploration, property)
    if (is.null(vc)) {
      stop(
        "No hospitalization card visual found for '", property, "' (category '", category, "'). ",
        "The dashboard layout may have changed — check the embed or update fetch_hospitalization_snapshot()."
      )
    }
    count <- extract_dsr_scalar(query_pbi_visual(ctx, vc))
    rows[[length(rows) + 1]] <- tibble(category = category, count = count)
  }
  bind_rows(rows)
}

# ---------------------------------------------------------------------------
# Cases by age group — statewide YTD cumulative, broken out by age group, not
# by day. We derive day-to-day new/cumulative counts per age group by
# diffing each group's cumulative snapshot against what's already recorded,
# the same way the hospitalization snapshot is diffed below.
# ---------------------------------------------------------------------------

# Find the "Cases by Age Group" columnChart — identified by having "agegrp"
# as a Select column in its prototypeQuery, same matching strategy as
# find_card_visual_by_property() but keyed on a grouping column rather than
# an aggregated one.
find_age_group_visual <- function(exploration) {
  for (section in exploration$sections) {
    for (vc in section$visualContainers) {
      cfg <- tryCatch(fromJSON(vc$config, simplifyVector = FALSE), error = function(e) NULL)
      sv  <- cfg$singleVisual
      if (is.null(sv) || !identical(sv$visualType, "columnChart")) next

      select <- sv$prototypeQuery$Select
      if (is.null(select)) next

      is_age_visual <- any(vapply(select, function(s) {
        identical(tryCatch(s$Column$Property, error = function(e) NULL), "agegrp")
      }, logical(1)))
      if (is_age_visual) return(vc)
    }
  }
  NULL
}

# Decode a DSR's DM0 row set into (category, count) pairs, resolving the
# dictionary-encoded category column against ValueDicts. Unlike
# decode_dsr_rows() (used for the county tables), this also handles the "Ø"
# bitmask Power BI uses to mark a column's value as null on a given row
# (rather than merely repeated from the row above, which is what "R" means)
# — the age-group chart requests every bucket via ShowItemsWithNoData, so a
# bucket with zero matching cases comes back with a null count instead of an
# explicit 0.
decode_dsr_categorical <- function(dsr) {
  ds <- dsr$DS[[1]]
  dm0 <- NULL
  for (ph in ds$PH) {
    if (!is.null(ph$DM0)) { dm0 <- ph$DM0; break }
  }
  if (is.null(dm0)) stop("Power BI query returned no rows (DM0 missing)")

  col_meta <- dm0[[1]]$S
  n_cols   <- length(col_meta)
  prev     <- vector("list", n_cols)
  rows     <- vector("list", length(dm0))

  for (i in seq_along(dm0)) {
    item      <- dm0[[i]]
    c_vals    <- item$C
    r_mask    <- item$R
    null_mask <- item[["Ø"]]
    ci <- 1
    row_vals <- vector("list", n_cols)
    for (col in seq_len(n_cols)) {
      bit <- bitwShiftL(1L, col - 1)
      if (!is.null(r_mask) && bitwAnd(as.integer(r_mask), bit) != 0) {
        row_vals[[col]] <- prev[[col]]
      } else if (!is.null(null_mask) && bitwAnd(as.integer(null_mask), bit) != 0) {
        row_vals[[col]] <- NA
      } else {
        row_vals[[col]] <- c_vals[[ci]]
        ci <- ci + 1
      }
    }
    prev <- row_vals
    rows[[i]] <- row_vals
  }

  dict_col    <- which(!vapply(col_meta, function(s) is.null(s$DN), logical(1)))[1]
  dict_values <- ds$ValueDicts[[col_meta[[dict_col]]$DN]]
  value_col   <- setdiff(seq_len(n_cols), dict_col)[1]

  tibble(
    category = vapply(rows, function(r) dict_values[[as.integer(r[[dict_col]]) + 1]], character(1)),
    count    = vapply(rows, function(r) if (is.na(r[[value_col]])) 0L else as.integer(r[[value_col]]), integer(1))
  )
}

# Statewide YTD cumulative case count for every age-group bucket the
# dashboard breaks cases into (e.g. "0-4", "5-9", ... "65+", "Unk").
fetch_age_group_snapshot <- function(ctx) {
  vc <- find_age_group_visual(ctx$exploration)
  if (is.null(vc)) {
    stop(
      "No 'Cases by Age Group' chart found in the Power BI report. ",
      "The dashboard layout may have changed — check the embed or update fetch_age_group_snapshot()."
    )
  }
  decode_dsr_categorical(query_pbi_visual(ctx, vc)) |> rename(age_group = category)
}

# ---------------------------------------------------------------------------
# TSV helpers
# ---------------------------------------------------------------------------

load_tsv_data <- function(path) {
  if (!file.exists(path)) {
    message("TSV not found at '", path, "' — will create a new one on first write")
    return(
      tibble(
        date             = character(),
        county           = character(),
        new_cases        = integer(),
        cumulative_cases = integer(),
        source           = character()
      )
    )
  }
  df <- read_tsv(path, col_types = cols(.default = "c"), show_col_types = FALSE)
  df$new_cases        <- as.integer(df$new_cases)
  df$cumulative_cases <- as.integer(df$cumulative_cases)
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

# summary_weekly.tsv is the full, authoritative weekly record — one row per
# week going back to the start of the outbreak, with `new_cases` synced from
# daily_cases_by_county.tsv's scrape-date rollup every run, EXCEPT for weeks listed
# in ADJUSTED_WEEKS (e.g. a lump-sum catch-up delta after a scraper outage
# misattributes cases to the wrong week) — those are hand-corrected and
# never auto-overwritten. `cumulative_cases` is fully derived (a running sum
# of `new_cases`), so it's recomputed from scratch on every save rather than
# tracked as independent state — see save_weekly_tsv(). See README.
# Kept separate from daily_cases_by_county.tsv so that file stays an honest record
# of actual scrape dates. See README.
WEEKLY_TSV_COLS <- c("week_start", "new_cases", "cumulative_cases")

# Weeks whose `new_cases` was corrected by hand and must never be
# auto-overwritten by sync_weekly_case_counts() — see README's "Known
# limitations" for why (2026-07-08 to 2026-07-24 scraper outage).
ADJUSTED_WEEKS <- c("2026-07-13", "2026-07-20")

load_weekly_tsv <- function(path) {
  if (!file.exists(path)) {
    return(tibble(
      week_start = character(),
      new_cases  = integer()
    ))
  }

  df <- read_tsv(path, col_types = cols(.default = "c"), show_col_types = FALSE)
  df$new_cases <- as.integer(df$new_cases)
  message("Loaded ", nrow(df), " week(s) from '", path, "'")
  df
}

save_weekly_tsv <- function(df, path) {
  for (col in WEEKLY_TSV_COLS) {
    if (!col %in% names(df)) df[[col]] <- NA
  }
  df <- df[order(df$week_start), ]
  df$cumulative_cases <- cumsum(coalesce(df$new_cases, 0L))
  df <- df[, WEEKLY_TSV_COLS]
  write_tsv(df, path, na = "")
  message("Saved ", nrow(df), " week(s) to '", path, "'")
}

# Refresh `new_cases` for every week from daily_cases_by_county.tsv's scrape-date
# rollup, except weeks in ADJUSTED_WEEKS (hand-corrected, left untouched).
# Adds a row for any new week that's shown up in daily_cases_by_county.tsv but isn't
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
      if (!(wk %in% ADJUSTED_WEEKS)) {
        weekly_df$new_cases[weekly_df$week_start == wk] <- val
      }
    } else {
      weekly_df <- bind_rows(weekly_df, tibble(
        week_start = wk, new_cases = val
      ))
    }
  }

  weekly_df |> arrange(week_start)
}

# daily_hospitalization_by_age_group.tsv: statewide hospitalizations per day, one
# row per category (total / children [under 18] / adult [18+]) — mirroring
# HOSP_CATEGORY_PROPERTIES above. PDOH's dashboard only exposes a running YTD
# cumulative total per category (not broken out by day or county), so each
# scrape run records that total as `cumulative_hospitalizations` and derives
# `new_hospitalizations` by diffing it against the category's most recent
# prior day's cumulative total already on record. Unlike daily_cases_by_county.tsv,
# this can't be broken out by county.
DAILY_HOSP_TSV_COLS  <- c("date", "category", "new_hospitalizations", "cumulative_hospitalizations")
HOSP_CATEGORY_ORDER  <- c("total", "children", "adult")

load_daily_hosp_tsv <- function(path) {
  if (!file.exists(path)) {
    message("TSV not found at '", path, "' — will create a new one on first write")
    return(tibble(
      date = character(), category = character(),
      new_hospitalizations = integer(), cumulative_hospitalizations = integer()
    ))
  }
  df <- read_tsv(path, col_types = cols(.default = "c"), show_col_types = FALSE)
  df$new_hospitalizations        <- as.integer(df$new_hospitalizations)
  df$cumulative_hospitalizations <- as.integer(df$cumulative_hospitalizations)
  message("Loaded ", nrow(df), " existing row(s) from '", path, "'")
  df
}

save_daily_hosp_tsv <- function(df, path) {
  for (col in DAILY_HOSP_TSV_COLS) {
    if (!col %in% names(df)) df[[col]] <- NA
  }
  df <- df[order(df$date, match(df$category, HOSP_CATEGORY_ORDER)), DAILY_HOSP_TSV_COLS]
  write_tsv(df, path, na = "")
  message("Saved ", nrow(df), " row(s) to '", path, "'")
}

# Today's new hospitalizations for a category = its current YTD cumulative
# total minus that category's most recent prior day's cumulative total
# already on record (0 if there is no prior day yet). Diffing against that
# single baseline, rather than summing every prior day's
# `new_hospitalizations`, means one day's figure can never drift from the
# cumulative history even if an earlier row was ever hand-corrected.
update_daily_hospitalizations <- function(hosp_df, today, snapshot) {
  new_rows <- list()

  for (i in seq_len(nrow(snapshot))) {
    category  <- snapshot$category[i]
    ytd_total <- snapshot$count[i]

    prior <- hosp_df |> filter(category == !!category, date != today, !is.na(cumulative_hospitalizations))
    prior_cumulative <- if (nrow(prior) == 0) 0L else {
      prior |> filter(date == max(date)) |> pull(cumulative_hospitalizations) |> first()
    }

    today_n <- as.integer(ytd_total - prior_cumulative)
    message(sprintf(
      "Hospitalizations (%s): %d cumulative YTD, %d new today (%s)",
      category, ytd_total, today_n, today
    ))

    new_rows[[length(new_rows) + 1]] <- tibble(
      date = today, category = category,
      new_hospitalizations = today_n, cumulative_hospitalizations = ytd_total
    )
  }

  hosp_df |>
    filter(!(date == today & category %in% snapshot$category)) |>
    bind_rows(bind_rows(new_rows))
}

# summary_daily.tsv: one row per day PDOH actually reported a change,
# statewide totals only — a quick-scan complement to daily_cases_by_county.tsv
# (per-county) and daily_hospitalization_by_age_group.tsv (per-category), which
# stay in their long, disaggregated form. A day where neither case count nor
# hospitalization count moved isn't a real data point — it just means PDOH
# hadn't published an update yet — so no row is written for it, mirroring
# daily_cases_by_county.tsv and daily_cases_by_age_group.tsv's "only write a row when
# something changed" convention. `cumulative_cases` is recomputed from
# scratch each run as the sum of every `new_cases` ever recorded in
# daily_cases_by_county.tsv (same "recompute rather than track" approach as
# summary_weekly.tsv's cumulative_cases), so it can't drift. Hospitalization
# columns stay blank until daily_hospitalization_by_age_group.tsv's
# "total" category starts recording (Aug 28, 2026); once it has, a row still
# written because cases changed (but whose hospitalization fetch failed that
# run) carries its cumulative forward with `new_hospitalizations` of 0, since
# no new report means no known change since the last one.
SUMMARY_TSV_COLS <- c("date", "new_cases", "cumulative_cases", "new_hospitalizations", "cumulative_hospitalizations")

load_summary_tsv <- function(path) {
  if (!file.exists(path)) {
    message("TSV not found at '", path, "' — will create a new one on first write")
    return(tibble(
      date = character(), new_cases = integer(), cumulative_cases = integer(),
      new_hospitalizations = integer(), cumulative_hospitalizations = integer()
    ))
  }
  df <- read_tsv(path, col_types = cols(.default = "c"), show_col_types = FALSE)
  df$new_cases                    <- as.integer(df$new_cases)
  df$cumulative_cases             <- as.integer(df$cumulative_cases)
  df$new_hospitalizations         <- as.integer(df$new_hospitalizations)
  df$cumulative_hospitalizations  <- as.integer(df$cumulative_hospitalizations)
  message("Loaded ", nrow(df), " existing row(s) from '", path, "'")
  df
}

save_summary_tsv <- function(df, path) {
  for (col in SUMMARY_TSV_COLS) {
    if (!col %in% names(df)) df[[col]] <- NA
  }
  df <- df[order(df$date), SUMMARY_TSV_COLS]
  write_tsv(df, path, na = "")
  message("Saved ", nrow(df), " row(s) to '", path, "'")
}

# Upsert today's row into summary_daily.tsv, or leave it unchanged if
# neither case count nor hospitalization count actually moved today.
# `case_daily_df` is daily_cases_by_county.tsv's full updated state; `today`'s new
# case total is summed directly from it (every county's rows dated today),
# not passed in as this run's own diff — the scraper can run more than once
# on the same calendar day (e.g. a manual run followed by the scheduled
# one), and a second run's diff is legitimately 0 even though cases_by_
# county.tsv already holds the day's real total from the earlier run.
# Deriving it fresh from the full file each time, like `cumulative_cases`
# below, makes this idempotent no matter how many times it runs today.
# `hosp_df` is daily_hospitalization_by_age_group.tsv's updated state, from which
# today's "total" category row (if any) supplies the hospitalization
# figures.
update_daily_summary <- function(summary_df, today, case_daily_df, hosp_df) {
  today_new_cases <- case_daily_df |> filter(date == today) |> pull(new_cases) |> sum(na.rm = TRUE)
  today_hosp    <- hosp_df |> filter(date == today, category == "total")
  new_hosp_today <- if (nrow(today_hosp) > 0) today_hosp$new_hospitalizations[1] else NA_integer_
  hosp_changed  <- !is.na(new_hosp_today) && new_hosp_today != 0

  if (today_new_cases == 0 && !hosp_changed) {
    message("No case or hospitalization change today — summary_daily.tsv unchanged")
    return(summary_df)
  }

  cumulative_cases <- sum(case_daily_df$new_cases, na.rm = TRUE)

  if (nrow(today_hosp) > 0) {
    new_hosp <- today_hosp$new_hospitalizations[1]
    cum_hosp <- today_hosp$cumulative_hospitalizations[1]
  } else {
    prior <- summary_df |> filter(date != today, !is.na(cumulative_hospitalizations))
    if (nrow(prior) > 0) {
      cum_hosp <- prior |> filter(date == max(date)) |> pull(cumulative_hospitalizations) |> first()
      new_hosp <- 0L
    } else {
      cum_hosp <- NA_integer_
      new_hosp <- NA_integer_
    }
  }

  today_row <- tibble(
    date = today, new_cases = today_new_cases, cumulative_cases = cumulative_cases,
    new_hospitalizations = new_hosp, cumulative_hospitalizations = cum_hosp
  )

  summary_df |> filter(date != today) |> bind_rows(today_row)
}

# daily_cases_by_age_group.tsv: one row per day a given age group's statewide
# cumulative case count went up, mirroring daily_cases_by_county.tsv's "only write a
# row when the count changes" convention. `cumulative_cases` is the group's
# statewide YTD total straight off the dashboard for that day; `new_cases` is
# blank on a group's very first tracked row (there's no prior baseline to
# diff against, so it isn't a real "new today" figure) and the delta from
# the group's previous recorded cumulative on every row after that.
AGE_GROUP_TSV_COLS <- c("date", "age_group", "new_cases", "cumulative_cases")

load_age_group_tsv <- function(path) {
  if (!file.exists(path)) {
    message("TSV not found at '", path, "' — will create a new one on first write")
    return(tibble(date = character(), age_group = character(), new_cases = integer(), cumulative_cases = integer()))
  }
  df <- read_tsv(path, col_types = cols(.default = "c"), show_col_types = FALSE)
  df$new_cases        <- as.integer(df$new_cases)
  df$cumulative_cases <- as.integer(df$cumulative_cases)
  message("Loaded ", nrow(df), " existing row(s) from '", path, "'")
  df
}

# The dashboard's own bucket order (youngest to oldest, "Unk" last) — sorting
# alphabetically instead would scramble it (e.g. "10-17" before "5-9").
AGE_GROUP_ORDER <- c("0-4", "5-9", "10-17", "18-24", "25-49", "50-64", "65+", "Unk")

save_age_group_tsv <- function(df, path) {
  for (col in AGE_GROUP_TSV_COLS) {
    if (!col %in% names(df)) df[[col]] <- NA
  }
  df <- df[order(df$date, match(df$age_group, AGE_GROUP_ORDER)), AGE_GROUP_TSV_COLS]
  write_tsv(df, path, na = "")
  message("Saved ", nrow(df), " row(s) to '", path, "'")
}

# ---------------------------------------------------------------------------
# Delta logic
# ---------------------------------------------------------------------------

# `snapshot` is PDOH's year-to-date case total per county (see
# parse_cases()). A county gets a new row whenever that total is higher than
# the sum of its `new_cases` already on record.
build_new_rows <- function(snapshot, existing) {
  today <- as.character(Sys.Date())

  known <- existing |>
    group_by(county) |>
    summarise(known_total = sum(new_cases, na.rm = TRUE), .groups = "drop")

  rows <- snapshot |>
    left_join(known, by = "county") |>
    mutate(
      known_total = coalesce(known_total, 0L),
      delta       = cumulative_cases - known_total
    )

  for (i in which(rows$delta < 0)) {
    warning(sprintf(
      "ANOMALY: DOH total for %s County decreased from %d to %d — skipping",
      rows$county[i], rows$known_total[i], rows$cumulative_cases[i]
    ))
  }

  new_rows <- rows |>
    filter(delta > 0) |>
    transmute(
      date             = today,
      county,
      new_cases        = delta,
      cumulative_cases,
      source           = "Scrape of PDOH measles webpage"
    )
  for (i in seq_len(nrow(new_rows))) {
    message(sprintf("NEW: +%d case(s) in %s County", new_rows$new_cases[i], new_rows$county[i]))
  }

  if (nrow(new_rows) == 0) return(NULL)
  new_rows
}

# Each group's known total is its most recently recorded `cumulative_cases`
# (not a sum of `new_cases`) — that column now comes straight off the
# dashboard, so diffing against it directly can't drift even though the
# group's very first row leaves `new_cases` blank.
age_group_totals_from_tsv <- function(existing) {
  existing |>
    filter(!is.na(cumulative_cases)) |>
    group_by(age_group) |>
    filter(date == max(date)) |>
    ungroup() |>
    transmute(age_group, known_total = cumulative_cases)
}

build_new_age_group_rows <- function(snapshot, existing) {
  today    <- as.character(Sys.Date())
  totals   <- age_group_totals_from_tsv(existing)
  new_rows <- list()

  for (i in seq_len(nrow(snapshot))) {
    grp        <- snapshot$age_group[i]
    cum_n      <- snapshot$count[i]
    known_row  <- totals |> filter(age_group == !!grp)
    first_seen <- nrow(known_row) == 0
    known_n    <- if (first_seen) 0L else known_row$known_total

    delta <- cum_n - known_n

    if (delta > 0) {
      if (first_seen) {
        message(sprintf("NEW GROUP: %s starts at %d case(s)", grp, cum_n))
      } else {
        message(sprintf("NEW: +%d case(s) in age group %s", delta, grp))
      }
      new_rows[[length(new_rows) + 1]] <- tibble(
        date             = today,
        age_group        = grp,
        new_cases        = if (first_seen) NA_integer_ else delta,
        cumulative_cases = cum_n
      )
    } else if (delta < 0) {
      warning(sprintf(
        "ANOMALY: cumulative case count for age group %s decreased from %d to %d — skipping",
        grp, known_n, cum_n
      ))
    } else {
      message(sprintf("No change: age group %s", grp))
    }
  }

  if (length(new_rows) == 0) return(NULL)
  bind_rows(new_rows)
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

  today <- as.character(Sys.Date())

  if (!is.null(new_rows)) {
    updated <- bind_rows(existing, new_rows)
    save_tsv_data(updated, tsv_path)
    message("Added ", nrow(new_rows), " new row(s) to '", tsv_path, "'")
  } else {
    updated <- existing
    message("No new cases — TSV unchanged")
  }

  # Sync summary_weekly.tsv: refresh new_cases from the daily rollup, except
  # hand-adjusted weeks.
  weekly_tsv <- load_weekly_tsv(WEEKLY_TSV) |>
    sync_weekly_case_counts(updated)
  save_weekly_tsv(weekly_tsv, WEEKLY_TSV)

  # daily_hospitalization_by_age_group.tsv update is non-fatal — if
  # it fails, the case-count sync above still gets saved, just without a
  # hospitalization update this run.
  hosp_tsv <- load_daily_hosp_tsv(DAILY_HOSP_TSV)
  tryCatch({
    hosp_snapshot <- fetch_hospitalization_snapshot(pbi_ctx)
    hosp_tsv      <- update_daily_hospitalizations(hosp_tsv, today, hosp_snapshot)
    save_daily_hosp_tsv(hosp_tsv, DAILY_HOSP_TSV)
  }, error = function(e) {
    message("WARNING: Hospitalization update failed — ", conditionMessage(e))
  })

  # summary_daily.tsv: statewide quick-scan totals, kept in sync with
  # whatever just got saved to daily_cases_by_county.tsv and
  # daily_hospitalization_by_age_group.tsv above (including a failed
  # hospitalization update — hosp_tsv still holds its last-saved state then).
  summary_tsv <- load_summary_tsv(SUMMARY_TSV) |>
    update_daily_summary(today, updated, hosp_tsv)
  save_summary_tsv(summary_tsv, SUMMARY_TSV)

  # Age-group case counts are likewise non-fatal to fetch/update — a failure
  # here shouldn't roll back the county/weekly/hospitalization updates above.
  tryCatch({
    age_snapshot   <- fetch_age_group_snapshot(pbi_ctx)
    existing_age   <- load_age_group_tsv(AGE_GROUP_TSV)
    new_age_rows   <- build_new_age_group_rows(age_snapshot, existing_age)

    if (!is.null(new_age_rows)) {
      updated_age <- bind_rows(existing_age, new_age_rows)
      save_age_group_tsv(updated_age, AGE_GROUP_TSV)
      message("Added ", nrow(new_age_rows), " new age-group row(s) to '", AGE_GROUP_TSV, "'")
    } else {
      message("No change in age-group case counts — '", AGE_GROUP_TSV, "' unchanged")
    }
  }, error = function(e) {
    message("WARNING: Age-group case update failed — ", conditionMessage(e))
  })
},
error = function(e) {
  message("ERROR: Scrape job failed: ", conditionMessage(e))
  message("=== Scrape job complete ===\n")
  quit(status = 1)
})

message("=== Scrape job complete ===\n")
