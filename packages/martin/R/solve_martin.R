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
#' @param coefficients Which coefficient set to use. For v0 only `"frozen"`
#'   is supported.
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
                         scenario        = "baseline",
                         sim_convergence = 1e-6,
                         sim_iter_limit  = 100) {
  coefficients <- match.arg(coefficients)
  if (coefficients == "reestimated") {
    stop("Re-estimation is not supported in v0. Use 'frozen'.", call. = FALSE)
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

  model <- load_martin(database, variant = "af", estimate = TRUE)

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

  .suppress_bimets_version_warning({
    model <- bimets::SIMULATE(
      model,
      TSRANGE            = tsrange,
      ConstantAdjustment = afs,
      simConvergence     = sim_convergence,
      simIterLimit       = sim_iter_limit
    )
  })

  out <- simulation_to_tibble(model, scenario = scenario)
  attr(out, "horizon")     <- horizon
  attr(out, "adjustments") <- adjustments
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

