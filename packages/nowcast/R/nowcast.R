#' Produce h-quarter-ahead estimates for MARTIN's handover variables
#'
#' For each variable in `variables`, takes the series from `database`, fits a
#' simple univariate model (per `method`), and produces forecasts for the
#' next `h` quarters past the last observed value. Returns a tidy tibble.
#'
#' Method options (delegated to `fable`):
#'
#' - `"arima"`  — `fable::ARIMA()` (default; auto-orders).
#' - `"ets"`    — `fable::ETS()`.
#' - `"naive"`  — random walk (`fable::NAIVE()`).
#' - `"bridge"` — linear regression on AR(1), AR(4), and a linear
#'   trend via `fable::TSLM()`. Cheaper than full ARIMA but captures
#'   the year-on-year seasonal and within-year persistence that
#'   most National-Accounts components show. A true monthly-
#'   indicator bridge (e.g. retail trade → quarterly consumption)
#'   needs exposing monthly data separately to nowcast (the current
#'   pipeline aggregates to quarterly upstream); this `"bridge"`
#'   method is the multivariate-linear chassis those future
#'   bridges would slot into.
#'
#' Ragged-edge handling: each variable is forecast from its own last
#' observed quarter, so series that lag (e.g. National Accounts) get more
#' forecast quarters than series that don't (e.g. exchange rates).
#'
#' @param database A named list of `bimets::TIMESERIES`, from
#'   [sibyldata::to_martin_database()] or [martin::read_fixture()].
#' @param h Integer. Number of quarters past each series' last observation
#'   to forecast. Default `2` (Q+0 + Q+1).
#' @param method One of `"arima"`, `"ets"`, `"naive"`.
#' @param variables Character vector of MARTIN variable codes to nowcast.
#'   Defaults to [handover_variables()] intersected with `names(database)`.
#' @param level Numeric. Forecast-interval coverage in percent. Default `80`.
#'
#' @return A tidy tibble with columns
#'   `(variable, quarter, central, lower, upper, method)`.
#' @export
nowcast_handover <- function(database,
                              h         = 2,
                              method    = c("arima", "ets", "naive",
                                            "bridge"),
                              variables = NULL,
                              level     = 80) {
  method <- match.arg(method)
  if (!is.list(database) || length(database) == 0L) {
    stop("`database` must be a non-empty named list of bimets time series.",
         call. = FALSE)
  }
  if (is.null(variables)) {
    variables <- intersect(handover_variables(), names(database))
  }
  missing_vars <- setdiff(variables, names(database))
  if (length(missing_vars)) {
    stop("Database is missing handover variables: ",
         paste(missing_vars, collapse = ", "), call. = FALSE)
  }

  out_rows <- purrr::map(variables, function(var) {
    ts <- database[[var]]
    forecast_one(ts, variable = var, h = h, method = method, level = level)
  })
  dplyr::bind_rows(out_rows)
}

# Forecast one variable. Returns a tidy tibble with `h` rows.
forecast_one <- function(ts, variable, h, method, level) {
  tsbl <- bimets_to_tsibble(ts, variable = variable)
  if (nrow(tsbl) < 8L) {
    stop("Variable `", variable, "` has fewer than 8 observations; ",
         "nowcast needs more history.", call. = FALSE)
  }

  spec <- switch(method,
    arima  = fable::ARIMA(value),
    ets    = fable::ETS(value),
    naive  = fable::NAIVE(value),
    # bridge: AR(1) + seasonal AR(1) ARIMA with auto-chosen
    # differencing. Captures within-year persistence and year-on-year
    # seasonality cheaply, without ARIMA's full auto-order search.
    # fable::TSLM with lag(value) would be the more natural "linear
    # bridge" framing, but TSLM doesn't propagate the lagged dependent
    # into the forecast horizon — fable wants AR structure inside an
    # ARIMA spec for the lag-of-LHS forecast to chain. Differencing
    # range pdq(1, 0:1, 0) lets the model handle non-stationary series
    # (RC, NC, etc.) without auto-selecting AR order.
    bridge = fable::ARIMA(value ~ pdq(1, 0:1, 0) + PDQ(1, 0:1, 0))
  )

  # fable's ARIMA/ETS auto-selection prints warnings for ill-conditioned
  # series (e.g. effectively-constant series, weird seasonality on short
  # samples). For nowcast — which runs across dozens of series, some of
  # which are smooth and some chaotic — these are informational and
  # uninteresting to a forecast-round user. Muffle them surgically.
  fit <- withCallingHandlers(
    fabletools::model(tsbl, model = spec),
    warning = function(w) invokeRestart("muffleWarning"),
    message = function(m) invokeRestart("muffleMessage")
  )

  fc <- fabletools::forecast(fit, h = h)
  hi_col <- paste0(level, "%")
  hi <- fabletools::hilo(fc, level)
  hi_vec <- hi[[hi_col]]   # a fabletools hilo vector

  tibble::tibble(
    variable = variable,
    quarter  = hi$quarter,
    central  = hi$.mean,
    lower    = hi_vec$lower,
    upper    = hi_vec$upper,
    method   = method
  )
}

#' Splice nowcast forecasts back into a MARTIN-shape database
#'
#' Overwrites the matching `[year, quarter]` cells of each handover variable
#' with the `central` forecast value. Uses bimets per-cell assignment, the
#' same pattern `martin::solve_martin()` uses to inject add-factors.
#'
#' If a cell already has a (non-NA) value, it's still overwritten — the
#' assumption is that nowcast was called *because* those cells lagged in
#' real time and the forecasts are more current than whatever was there.
#'
#' If a forecast quarter is past the end of the existing bimets ts, the ts
#' is extended via `bimets::TSEXTEND`. If the assignment would create a gap
#' (a quarter between the last observation and the forecast), that's an
#' error — the caller probably has a sequencing bug.
#'
#' @param database A named list of `bimets::TIMESERIES`.
#' @param handover A tibble from [nowcast_handover()].
#' @return The updated database.
#' @export
splice_handover <- function(database, handover) {
  required <- c("variable", "quarter", "central")
  missing <- setdiff(required, names(handover))
  if (length(missing)) {
    stop("`handover` is missing required columns: ",
         paste(missing, collapse = ", "), call. = FALSE)
  }

  for (var in unique(handover$variable)) {
    if (is.null(database[[var]])) {
      stop("Database has no series for `", var, "`. ",
           "Add it before splicing.", call. = FALSE)
    }
    sub <- handover[handover$variable == var, , drop = FALSE]
    sub <- sub[order(sub$quarter), , drop = FALSE]
    database[[var]] <- splice_one(database[[var]], sub, variable = var)
  }
  database
}

# Splice one variable's forecasts into one bimets ts. Extends the ts if the
# forecast quarters run past the current end.
splice_one <- function(ts, sub, variable) {
  out <- ts
  for (i in seq_len(nrow(sub))) {
    q       <- sub$quarter[i]
    year    <- as.integer(format(q, "%Y"))
    qnum    <- as.integer(substr(format(q), 7, 7))

    # Extend if needed
    tsp_now <- stats::tsp(out)
    end_dec <- tsp_now[2]
    target_dec <- year + (qnum - 1) / 4
    if (target_dec > end_dec + 1e-9) {
      # bimets::TSEXTEND with a constant 0 fill (replaced below by the
      # assignment); we just need the storage allocated to `target_dec`.
      out <- bimets::TSEXTEND(
        out,
        UPTO    = c(year, qnum),
        EXTMODE = "MYCONST",
        FACTOR  = sub$central[i]
      )
      next  # TSEXTEND with MYCONST = central already wrote the value
    }
    out[[year, qnum]] <- sub$central[i]
  }
  out
}
