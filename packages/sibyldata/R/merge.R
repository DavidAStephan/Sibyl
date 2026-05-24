# Merge a live MARTIN database with a fallback (typically the bundled
# fixture). The live pipeline's behavioural equations need histories
# going back to the 1960s for some series — longer than live ABS / RBA
# data can reach. The fallback fills those gaps without overriding live
# data where it's at least as long.

#' Merge a primary MARTIN database with a fallback
#'
#' For each MARTIN variable, prefer `primary` when it's available **and**
#' has at least as much history as `fallback`; otherwise use `fallback`.
#' Variables present only in `primary` are added; variables present only
#' in `fallback` are kept. Variables present in both with `primary`
#' shorter than `fallback` lose to `fallback` (because MARTIN's behavioural
#' equations need their full TSRANGE).
#'
#' Mirrors the smoke-test hybrid pattern in
#' [scripts/live_integration_smoke.R].
#'
#' @param primary A named list of bimets TIMESERIES (typically a live
#'   sibyldata-produced database).
#' @param fallback A named list of bimets TIMESERIES (typically
#'   `martin::read_fixture()`).
#' @return A named list of bimets TIMESERIES covering the union, with the
#'   length-based preference rule applied per variable.
#' @export
merge_with_fallback <- function(primary, fallback) {
  out <- fallback
  for (v in names(primary)) {
    if (is.null(out[[v]])) {
      out[[v]] <- primary[[v]]
    } else if (length(as.numeric(primary[[v]])) >=
                 length(as.numeric(out[[v]]))) {
      out[[v]] <- primary[[v]]
    }
    # else keep fallback (longer history)
  }
  out
}
