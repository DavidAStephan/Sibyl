# Fetchers for sources other than FRED. Stubs for now — interfaces are
# fixed so [update_data()] can route to each, but the bodies throw informative
# errors. Implementing them follows the same shape as fetch_fred():
#
#   1. Look up the catalogue rows for the source.
#   2. Hit the live API (readabs / readrba / OECD::get_dataset / xlsx /
#      ftp).
#   3. Normalise the result to (series_id, source, date, value, vintage).
#   4. For monthly sources, aggregate to quarterly here OR leave it to
#      to_martin_database() — TBD; for now we leave it raw so the cached
#      panel preserves max resolution and the pivot decides.
#   5. Return the tidy tibble.

# fetch_abs() lives in fetch_abs.R

# fetch_rba() lives in fetch_rba.R

#' Stub fetcher for OECD series
#'
#' MARTIN's world variables presently use US FRED proxies (per the README of
#' references/MARTIN-master). When we shift to major-trading-partner-weighted
#' aggregates, OECD will be the source.
#'
#' @keywords internal
fetch_oecd <- function(series_ids, vintage) {
  stop("fetch_oecd() is not yet implemented. ",
       "v0 uses FRED US-proxy series instead; see DESIGN.md.",
       call. = FALSE)
}

# fetch_worldbank() lives in fetch_worldbank.R

# fetch_bom() lives in fetch_bom.R
