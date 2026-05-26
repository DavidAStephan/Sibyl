#' Solve MARTIN over a horizon, optionally with add-factors
#'
#' The public surface of `martin`. Takes a starting database, a list of
#' add-factors (from `judgement::adjustment_list()`), and a horizon; returns
#' a long tidy projection tibble.
#'
#' Pipeline:
#'
#' 1. [load_martin()] the chosen variant against `database`. ESTIMATE
#'    populates the per-equation residual slots used in step 2.
#' 2. **Replay history**: build a baseline `ConstantAdjustment` list from
#'    `model$behaviorals$<EQ>$residuals` so that with no user-provided
#'    adjustment, the simulated path reproduces history (this is the bimets
#'    equivalent of EViews `addinit(v=n)` from
#'    `references/MARTIN-master/Programs/solve_model.prg`).
#' 3. **Inject user adjustments**: expand `adjustments` to numeric vectors
#'    via [judgement::expand_adjustments()] and inject them into the replay
#'    AFs via bimets `[[year, quarter]]<-` per-cell assignment — the same
#'    pattern `references/bimets-main/BIMETS_MARTIN_LOAD.R` uses to deliver
#'    a shock. User values are added on top of the residual; equations not
#'    in `adjustments` keep their unmodified replay AF.
#' 4. Call `bimets::SIMULATE(model, TSRANGE = ..., ConstantAdjustment = ...)`.
#' 5. Pivot the named-list-of-ts result to a long tibble.
#'
#' Horizons that extend past the data end are supported: the replay AFs
#' (residuals) are decayed forward via the EViews `_a = _a(-1) * -0.5`
#' convention so they remain well-defined into the future. Note that
#' bimets still needs every variable's data to extend over `TSRANGE`;
#' caller must extend exogenous variables (PI_TARGET, dummies, etc.)
#' separately when solving past the historical data end.
#'
#' @param database A named list of `bimets::TIMESERIES`, eventually from
#'   [sibyldata::to_martin_database()]; in tests, from [read_fixture()].
#' @param adjustments A `judgement::adjustment_list` (possibly empty or NULL).
#' @param horizon A length-2 character vector of `c("yyyyQq", "yyyyQq")`
#'   identifying the inclusive simulation range.
#' @param coefficients Which coefficient set to use. `"frozen"` (default)
#'   uses the model file's TSRANGE end of 2019Q3 — equivalent to the
#'   originally-estimated coefficients. `"reestimated"` re-fits every
#'   behavioural equation over its embedded start through
#'   `estimation_end`; useful when live data extends past 2019Q3 and you
#'   want the model's parameters to reflect the post-COVID period.
#' @param estimation_end Optional `"yyyyQq"` string. Required when
#'   `coefficients = "reestimated"`. Ignored under `"frozen"`.
#' @param scenario A label written into the returned tibble.
#' @param sim_convergence Bimets simulation convergence tolerance.
#' @param sim_iter_limit  Bimets simulation iteration limit.
#'
#' @return A long tidy tibble of `(variable, quarter, value, scenario)`,
#'   with attributes `horizon`, `adjustments`, and `scenario`.
#' @export
solve_martin <- function(database,
                         adjustments     = NULL,
                         horizon,
                         coefficients    = c("frozen", "reestimated"),
                         estimation_end  = NULL,
                         scenario        = "baseline",
                         exogenize       = character(0),
                         baseline_for_exogenize = NULL,
                         exogenize_range = NULL,
                         sim_convergence = 1e-6,
                         sim_iter_limit  = 100) {
  coefficients <- match.arg(coefficients)
  if (coefficients == "reestimated" && is.null(estimation_end)) {
    stop("`coefficients = 'reestimated'` requires `estimation_end` ",
         "(e.g. '2025Q2').", call. = FALSE)
  }
  if (length(horizon) != 2L || !is.character(horizon)) {
    stop("`horizon` must be a length-2 character vector of `yyyyQq`.",
         call. = FALSE)
  }
  if (is.null(adjustments)) {
    adjustments <- judgement::adjustment_list()
  }
  if (!inherits(adjustments, "adjustment_list")) {
    stop("`adjustments` must be a judgement::adjustment_list or NULL.",
         call. = FALSE)
  }
  if (length(exogenize) > 0L) {
    if (is.null(baseline_for_exogenize)) {
      stop("`exogenize` requires `baseline_for_exogenize` ",
           "(a baseline projection tibble whose values will be used as ",
           "the exogenous path).", call. = FALSE)
    }
    if (!is.data.frame(baseline_for_exogenize) ||
        !all(c("variable", "quarter", "value") %in%
             names(baseline_for_exogenize))) {
      stop("`baseline_for_exogenize` must be a tibble with columns ",
           "(variable, quarter, value).", call. = FALSE)
    }
  }

  # Splice the baseline path into the database for any exogenised variable
  # over the exogenisation range. This is what bimets's Exogenize reads
  # back: it uses the database values for exogenised vars in lieu of
  # iterating their equations.
  if (length(exogenize) > 0L) {
    if (is.null(exogenize_range)) exogenize_range <- horizon
    ex_start <- judgement_parse_quarter(exogenize_range[1])
    ex_end   <- judgement_parse_quarter(exogenize_range[2])
    database <- splice_exogenize_baseline(
      database, baseline_for_exogenize, exogenize,
      ex_start, ex_end
    )
  }

  model <- load_martin(
    database, variant = "af", estimate = TRUE,
    estimation_end = if (coefficients == "reestimated") estimation_end else NULL
  )

  start <- judgement_parse_quarter(horizon[1])
  end   <- judgement_parse_quarter(horizon[2])
  tsrange <- c(start$year, start$quarter, end$year, end$quarter)

  replay_afs <- residual_constant_adjustment(model)
  # Extend each replay AF forward via the EViews `_a(-1) * -0.5` rule so
  # the simulator sees a defined value at every period in horizon — even
  # when horizon[2] is past the data end. Cells inside the historical
  # range are untouched.
  replay_afs <- lapply(replay_afs, function(ts) {
    extend_residual_with_decay(ts, end$year, end$quarter)
  })
  user_expanded <- judgement::expand_adjustments(adjustments, horizon)
  afs <- inject_user_adjustments(replay_afs, user_expanded)

  # Build bimets's Exogenize list: each entry is c(start_year, start_q,
  # end_year, end_q) for the period during which that variable is held
  # to the database's (now-baseline-spliced) values.
  exogenize_list <- NULL
  if (length(exogenize) > 0L) {
    if (is.null(exogenize_range)) exogenize_range <- horizon
    ex_start <- judgement_parse_quarter(exogenize_range[1])
    ex_end   <- judgement_parse_quarter(exogenize_range[2])
    exogenize_list <- stats::setNames(
      lapply(exogenize, function(v) c(ex_start$year, ex_start$quarter,
                                       ex_end$year, ex_end$quarter)),
      exogenize
    )
  }

  .suppress_bimets_version_warning({
    model <- bimets::SIMULATE(
      model,
      TSRANGE            = tsrange,
      ConstantAdjustment = afs,
      Exogenize          = exogenize_list,
      simConvergence     = sim_convergence,
      simIterLimit       = sim_iter_limit
    )
  })

  out <- simulation_to_tibble(model, scenario = scenario)
  attr(out, "horizon")     <- horizon
  attr(out, "adjustments") <- adjustments
  attr(out, "exogenize")   <- exogenize
  attr(out, "scenario")    <- scenario
  out
}

# Build a ConstantAdjustment list from a model's behavioural residuals.
# After ESTIMATE on MARTINMOD_AF.txt (every behavioural has `RESTRICT> c1=1`),
# each `$residuals` slot is the EViews-style historical AF that makes
# fitted + AF = actual. Using these as the baseline AF means SIMULATE with no
# user adjustments replays history exactly — the bimets equivalent of EViews
# `addinit(v=n)` from references/MARTIN-master/Programs/solve_model.prg.
residual_constant_adjustment <- function(model) {
  eqs <- names(model$behaviorals)
  out <- vector("list", length(eqs))
  names(out) <- eqs
  for (eq in eqs) {
    res <- model$behaviorals[[eq]]$residuals
    if (!is.null(res)) out[[eq]] <- res
  }
  out[!vapply(out, is.null, logical(1))]
}

# Inject expanded user adjustments into the replay AFs via bimets per-cell
# assignment. This is the pattern used in
# references/bimets-main/BIMETS_MARTIN_LOAD.R (`Shock$NCR[[2010,1]] <- ...`)
# and preserves the replay over the rest of the historical range.
#
# `replay`        is the list of full-history residual ts.
# `user_expanded` is the named list of numeric vectors from
#                 judgement::expand_adjustments(); it carries `quarters` as
#                 an attribute.
inject_user_adjustments <- function(replay, user_expanded) {
  if (length(user_expanded) == 0L) return(replay)
  qs <- attr(user_expanded, "quarters")
  if (is.null(qs)) {
    stop("`user_expanded` is missing its `quarters` attribute.", call. = FALSE)
  }

  out <- replay
  for (eq in names(user_expanded)) {
    vals <- user_expanded[[eq]]
    if (is.null(out[[eq]])) {
      # No replay AF for this equation (unusual for AF-form). Build a fresh
      # ts at the user's horizon and let bimets handle it.
      start <- judgement_parse_quarter(qs[1])
      out[[eq]] <- bimets::TIMESERIES(
        vals, START = c(start$year, start$quarter), FREQ = 4
      )
      next
    }
    target <- out[[eq]]
    for (i in seq_along(qs)) {
      q <- judgement_parse_quarter(qs[i])
      target[[q$year, q$quarter]] <- target[[q$year, q$quarter]] + vals[i]
    }
    out[[eq]] <- target
  }
  out
}

# Pivot a SIMULATEd model's $simulation slot to a long tidy tibble.
simulation_to_tibble <- function(model, scenario = "baseline") {
  sim <- model$simulation
  if (is.null(sim) || length(sim) == 0L) {
    stop("Model has no simulation results — did SIMULATE() run?",
         call. = FALSE)
  }
  # bimets stuffs metadata like `__SIM_PARAMETERS__` into $simulation as a
  # list; skip anything that isn't an actual time series.
  is_series <- vapply(sim, function(x) inherits(x, "ts"), logical(1))
  vars <- names(sim)[is_series]
  rows <- lapply(vars, function(var) {
    ts <- sim[[var]]
    if (is.null(ts)) return(NULL)
    # bimets TIMESERIES inherits from ts; stats::time() gives decimal years
    # (e.g. 2010.0, 2010.25). Convert to "yyyyQq".
    t <- as.numeric(stats::time(ts))
    year    <- floor(t + 1e-9)
    quarter <- round((t - year) * 4 + 1)
    tibble::tibble(
      variable = var,
      quarter  = sprintf("%04dQ%d", year, quarter),
      value    = as.numeric(ts),
      scenario = scenario
    )
  })
  dplyr::bind_rows(rows)
}

# Overwrite each exogenised variable's bimets ts with the corresponding
# baseline-projection values over [ex_start, ex_end]. Cells outside that
# range, and variables not in `exogenize`, are left untouched.
#
# Why this is needed: bimets' Exogenize argument doesn't take a path —
# it tells SIMULATE to use the database's existing values for those
# variables instead of iterating their equations. To "hold X at
# baseline" we have to put the baseline values *into* the database
# first.
splice_exogenize_baseline <- function(database, baseline, exogenize,
                                      ex_start, ex_end) {
  ex_lookup <- split(baseline, baseline$variable)
  for (v in exogenize) {
    ts <- database[[v]]
    if (is.null(ts)) {
      stop(sprintf("Cannot exogenise '%s': not in database.", v),
           call. = FALSE)
    }
    base_v <- ex_lookup[[v]]
    if (is.null(base_v) || nrow(base_v) == 0L) {
      stop(sprintf("Cannot exogenise '%s': no baseline values supplied.",
                   v), call. = FALSE)
    }
    base_v <- base_v[order(base_v$quarter), , drop = FALSE]
    ex_start_dec <- ex_start$year + (ex_start$quarter - 1) / 4
    ex_end_dec   <- ex_end$year   + (ex_end$quarter   - 1) / 4

    tsp <- stats::tsp(ts)
    ts_start_year <- floor(tsp[1] + 1e-9)
    ts_start_q    <- round((tsp[1] - ts_start_year) * 4 + 1)
    vals <- as.numeric(ts)
    # Extend ts forward if it ends before ex_end (carry-forward seed).
    cur_end_dec <- tsp[2]
    if (cur_end_dec < ex_end_dec - 1e-9) {
      n_pad <- round((ex_end_dec - cur_end_dec) * 4)
      last_v <- tail(vals[is.finite(vals)], 1)
      if (length(last_v) == 0L) last_v <- 0
      vals <- c(vals, rep(last_v, n_pad))
    }
    # Index each cell by yyyyQq.
    n <- length(vals)
    cell_labels <- vapply(seq_len(n), function(i) {
      abs_q <- ts_start_year * 4L + (ts_start_q - 1L) + (i - 1L)
      sprintf("%04dQ%d", abs_q %/% 4L, (abs_q %% 4L) + 1L)
    }, character(1))
    base_by_q <- stats::setNames(base_v$value, base_v$quarter)

    # Identify which cells fall inside the exogenisation window.
    in_window <- vapply(seq_len(n), function(i) {
      abs_q <- ts_start_year * 4L + (ts_start_q - 1L) + (i - 1L)
      dec <- abs_q %/% 4L + ((abs_q %% 4L)) / 4
      dec >= ex_start_dec - 1e-9 & dec <= ex_end_dec + 1e-9
    }, logical(1))

    for (i in which(in_window)) {
      bv <- base_by_q[[cell_labels[i]]]
      if (!is.null(bv) && is.finite(bv)) vals[i] <- bv
    }

    database[[v]] <- bimets::TIMESERIES(
      vals, START = c(ts_start_year, ts_start_q), FREQ = 4
    )
  }
  database
}

