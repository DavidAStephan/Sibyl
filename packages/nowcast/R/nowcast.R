#' Produce h-quarter-ahead estimates for MARTIN's handover variables
#'
#' For each variable in `variables`, takes the series from `database`, fits a
#' simple univariate model (per `method`), and produces forecasts for the
#' next `h` quarters past the last observed value. Returns a tidy tibble.
#'
#' Method options (delegated to `fable` except `"bridge_monthly"`):
#'
#' - `"arima"`  — `fable::ARIMA()` (default; auto-orders).
#' - `"ets"`    — `fable::ETS()`.
#' - `"naive"`  — random walk (`fable::NAIVE()`).
#' - `"bridge"` — `fable::ARIMA` constrained to AR(1) + seasonal
#'   AR(1) with auto-chosen differencing. Cheaper than full auto
#'   ARIMA but captures within-year persistence + seasonality.
#' - `"bridge_monthly"` — true monthly-indicator bridge: regress the
#'   quarterly target on a quarterly aggregate of a monthly indicator
#'   (e.g. HOURS → Y, RT → RC), then predict the forecast quarter
#'   using a **partial-quarter** average of whatever months of the
#'   indicator are already available. Requires the `bridge_indicators`
#'   argument mapping target codes to indicator codes, and the
#'   monthly indicators themselves in the `monthly_indicators`
#'   argument (typically from
#'   `sibyldata::nowcast_monthly_indicators()`).
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
                                            "bridge", "bridge_monthly"),
                              variables = NULL,
                              level     = 80,
                              bridge_indicators = NULL,
                              monthly_indicators = NULL) {
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
  if (method == "bridge_monthly") {
    if (is.null(bridge_indicators) || is.null(monthly_indicators)) {
      stop("method = 'bridge_monthly' requires both `bridge_indicators` ",
           "(a named list/character vector mapping target codes to ",
           "indicator names) and `monthly_indicators` (a named list of ",
           "monthly bimets ts, typically from ",
           "`sibyldata::nowcast_monthly_indicators()`).", call. = FALSE)
    }
  }

  out_rows <- purrr::map(variables, function(var) {
    ts <- database[[var]]
    if (method == "bridge_monthly") {
      indicator_name <- bridge_indicators[[var]]
      if (is.null(indicator_name) || is.null(monthly_indicators[[indicator_name]])) {
        # No indicator mapped or indicator missing → fall back to ARIMA.
        return(forecast_one(ts, variable = var, h = h,
                            method = "arima", level = level))
      }
      forecast_one_bridge_monthly(
        target_ts = ts, variable = var,
        indicator_ts = monthly_indicators[[indicator_name]],
        indicator_name = indicator_name,
        h = h, level = level
      )
    } else {
      forecast_one(ts, variable = var, h = h, method = method, level = level)
    }
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

# Monthly-indicator bridge forecast. Aggregates the indicator's full
# historical months to quarterly means, fits OLS target ~ indicator on
# overlapping quarters, then predicts the next `h` target quarters using
# whatever months of the indicator are available (1, 2, or 3 months per
# quarter — partial quarters get the partial mean as their indicator
# value). Falls back to a naive last-value forecast if the OLS fit is
# degenerate or no indicator data covers the forecast horizon.
forecast_one_bridge_monthly <- function(target_ts, variable,
                                        indicator_ts, indicator_name,
                                        h, level) {
  if (is.null(indicator_ts) || length(as.numeric(indicator_ts)) == 0L) {
    return(forecast_one(target_ts, variable, h, "arima", level))
  }

  # ---- Aggregate the monthly indicator into per-quarter buckets ----
  ind_v <- as.numeric(indicator_ts)
  ind_tsp <- stats::tsp(indicator_ts)
  start_y <- floor(ind_tsp[1] + 1e-9)
  start_m <- round((ind_tsp[1] - start_y) * 12 + 1)
  # Build (year, quarter) labels for each monthly observation.
  n_ind <- length(ind_v)
  ind_year <- start_y + (seq_len(n_ind) - 1L + (start_m - 1L)) %/% 12L
  ind_month <- ((start_m - 1L + seq_len(n_ind) - 1L) %% 12L) + 1L
  ind_quarter <- (ind_month - 1L) %/% 3L + 1L
  ind_key <- ind_year * 10L + ind_quarter   # e.g. 20211 = 2021Q1

  # Mean per (year, quarter), tracking the number of months observed so
  # we can mark partial quarters distinctly from full ones.
  ind_buckets <- vapply(unique(ind_key), function(k) {
    sel <- ind_key == k & !is.na(ind_v)
    if (!any(sel)) return(c(NA_real_, 0))
    c(mean(ind_v[sel]), sum(sel))
  }, numeric(2))
  ind_means  <- ind_buckets[1, ]
  ind_nmonth <- ind_buckets[2, ]
  ind_q_keys <- unique(ind_key)

  # ---- Pair with the target's quarterly history ----
  tgt_v <- as.numeric(target_ts)
  tgt_tsp <- stats::tsp(target_ts)
  tgt_start_y <- floor(tgt_tsp[1] + 1e-9)
  tgt_start_q <- round((tgt_tsp[1] - tgt_start_y) * 4 + 1)
  n_tgt <- length(tgt_v)
  tgt_year <- tgt_start_y +
              (seq_len(n_tgt) - 1L + (tgt_start_q - 1L)) %/% 4L
  tgt_q <- ((tgt_start_q - 1L + seq_len(n_tgt) - 1L) %% 4L) + 1L
  tgt_key <- tgt_year * 10L + tgt_q

  # OLS sample: full-month quarters (3 obs) AND both target + indicator
  # non-NA.
  match_pos <- match(tgt_key, ind_q_keys)
  has_ind   <- !is.na(match_pos)
  ind_aligned <- rep(NA_real_, n_tgt)
  ind_nmonth_aligned <- rep(0L, n_tgt)
  ind_aligned[has_ind]        <- ind_means[match_pos[has_ind]]
  ind_nmonth_aligned[has_ind] <- as.integer(ind_nmonth[match_pos[has_ind]])

  full_sample <- !is.na(tgt_v) & !is.na(ind_aligned) & ind_nmonth_aligned == 3L
  if (sum(full_sample) < 8L) {
    # Not enough overlap to fit a bridge regression — degrade gracefully.
    return(forecast_one(target_ts, variable, h, "arima", level))
  }

  df_fit <- data.frame(
    y = tgt_v[full_sample],
    x = ind_aligned[full_sample]
  )
  fit <- tryCatch(stats::lm(y ~ x, data = df_fit),
                  error = function(e) NULL)
  if (is.null(fit)) {
    return(forecast_one(target_ts, variable, h, "arima", level))
  }
  sigma <- summary(fit)$sigma
  z_crit <- stats::qnorm(0.5 + level / 200)  # two-sided level%

  # ---- Forecast the next `h` quarters using indicator's recent months
  last_tgt_key <- max(tgt_key[!is.na(tgt_v)])
  fc_keys <- last_tgt_key + cumsum(rep(c(1L, 7L), length.out = h)) -
             rep(c(0L, 6L), length.out = h)
  # simpler: build by hand
  fc_keys <- integer(h)
  ly <- last_tgt_key %/% 10L
  lq <- last_tgt_key %% 10L
  for (i in seq_len(h)) {
    lq <- lq + 1L
    if (lq > 4L) { lq <- 1L; ly <- ly + 1L }
    fc_keys[i] <- ly * 10L + lq
  }

  rows <- vector("list", h)
  for (i in seq_len(h)) {
    k <- fc_keys[i]
    pos <- match(k, ind_q_keys)
    if (is.na(pos)) {
      # No indicator coverage for this quarter — use last available
      # indicator-quarter value (carry-forward).
      pos <- length(ind_q_keys)
    }
    x_val <- ind_means[pos]
    central <- stats::predict(fit, newdata = data.frame(x = x_val))
    se <- sigma  # rough constant interval; ignores OLS leverage
    yr <- k %/% 10L; qn <- k %% 10L
    # Match forecast_one()'s `quarter` column type — tsibble yearquarter.
    rows[[i]] <- tibble::tibble(
      variable = variable,
      quarter  = tsibble::yearquarter(sprintf("%d Q%d", yr, qn)),
      central  = unname(central),
      lower    = unname(central - z_crit * se),
      upper    = unname(central + z_crit * se),
      method   = sprintf("bridge_monthly[%s]", indicator_name)
    )
  }
  dplyr::bind_rows(rows)
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
