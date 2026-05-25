# Merge a live MARTIN database with a fallback (typically the bundled
# fixture). The live pipeline's behavioural equations need histories
# going back to the 1960s for some series — longer than live ABS / RBA
# data can reach. The fallback fills those gaps without overriding live
# data where it's at least as long.

#' Merge a primary MARTIN database with a fallback
#'
#' For each MARTIN variable, prefer `primary` when it **covers
#' fallback's observed range** — meaning its first non-NA observation
#' is at-or-before fallback's first non-NA, AND its last non-NA is
#' at-or-after fallback's last non-NA. Otherwise fallback wins because
#' MARTIN's behavioural equations need the full TSRANGE: if primary's
#' coverage stops short of where MARTIN expects data (either historically
#' or terminally), the estimation step blows up.
#'
#' This handles two real cases we hit on Australian data:
#' (1) live RBA series that start later than the fixture (e.g. N2R from
#' 1995 vs MARTIN's 1993Q1 TSRANGE), and (2) live RBA series that the
#' agency stopped updating before the fixture's end (e.g. D02 credit
#' aggregates ending 2019Q2 vs fixture's 2019Q3).
#'
#' Variables present only in `primary` are added; variables present only
#' in `fallback` are kept.
#'
#' @param primary A named list of bimets TIMESERIES (typically a live
#'   sibyldata-produced database).
#' @param fallback A named list of bimets TIMESERIES (typically
#'   `martin::read_fixture()`).
#' @return A named list of bimets TIMESERIES covering the union, with
#'   the coverage-based preference rule applied per variable.
#' @export
merge_with_fallback <- function(primary, fallback) {
  out <- fallback
  for (v in names(primary)) {
    if (is.null(out[[v]])) {
      out[[v]] <- primary[[v]]
      next
    }
    p_range <- nonna_range(primary[[v]])
    f_range <- nonna_range(out[[v]])
    if (any(is.na(p_range))) {
      # Primary all-NA — keep fallback.
      next
    }
    if (any(is.na(f_range))) {
      # Fallback all-NA but primary has data — use primary.
      out[[v]] <- primary[[v]]
      next
    }
    if (p_range[1] <= f_range[1] && p_range[2] >= f_range[2]) {
      out[[v]] <- primary[[v]]
    }
    # else keep fallback (primary doesn't cover full fallback range)
  }
  out
}

# Return c(first_nonna_quarter, last_nonna_quarter) as decimal years
# (e.g. 1959.5 = 1959Q3). c(NA, NA) if the series is all-NA.
nonna_range <- function(ts) {
  vals <- as.numeric(ts)
  nonna_pos <- which(!is.na(vals))
  if (length(nonna_pos) == 0L) return(c(NA_real_, NA_real_))
  tsp <- stats::tsp(ts)
  c(tsp[1] + (nonna_pos[1] - 1L) / 4,
    tsp[1] + (tail(nonna_pos, 1L) - 1L) / 4)
}
