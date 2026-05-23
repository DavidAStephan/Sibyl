# Conversion between bimets time series (the shape sibyldata produces and
# martin consumes) and tsibble (the shape fable consumes). Both directions
# preserve the quarterly index exactly.

#' Convert a bimets TIMESERIES to a tsibble
#'
#' @param ts A bimets time series (which inherits from base ts).
#' @param variable Character. The name to store in the `variable` column.
#' @return A tsibble keyed by `variable` and indexed by `quarter`
#'   (yearquarter).
#' @keywords internal
bimets_to_tsibble <- function(ts, variable) {
  t <- as.numeric(stats::time(ts))
  year    <- floor(t + 1e-9)
  quarter <- round((t - year) * 4 + 1)
  out <- tibble::tibble(
    variable = variable,
    quarter  = tsibble::make_yearquarter(year = year, quarter = quarter),
    value    = as.numeric(ts)
  )
  out <- out[!is.na(out$value), , drop = FALSE]
  tsibble::as_tsibble(out, key = "variable", index = "quarter")
}

#' Convert a tibble of quarterly values to a bimets TIMESERIES
#'
#' Expects the input to be sorted by quarter ascending; the resulting ts
#' starts at the first quarter and ends at the last.
#'
#' @param df A tibble with at least `quarter` (yearquarter) and `value`
#'   columns.
#' @return A bimets TIMESERIES.
#' @keywords internal
quarterly_tibble_to_bimets <- function(df) {
  df <- df[order(df$quarter), , drop = FALSE]
  first_q <- df$quarter[1]
  year    <- as.integer(format(first_q, "%Y"))
  qnum    <- as.integer(substr(format(first_q), 7, 7))
  bimets::TIMESERIES(
    df$value,
    START = c(year, qnum),
    FREQ  = 4
  )
}

#' Get the last observed quarter of a bimets time series
#'
#' Skips trailing NA cells.
#'
#' @param ts A bimets TIMESERIES.
#' @return A tsibble yearquarter.
#' @keywords internal
last_observed_quarter <- function(ts) {
  vals <- as.numeric(ts)
  last_idx <- max(which(!is.na(vals)))
  t <- as.numeric(stats::time(ts))[last_idx]
  year <- floor(t + 1e-9)
  quarter <- round((t - year) * 4 + 1)
  tsibble::make_yearquarter(year = year, quarter = quarter)
}
