# Port of references/MARTIN-master/Programs/supply_side.prg state-space
# models to KFAS. Produces the three trend variables MARTIN needs as
# behavioural inputs:
#
#   TDLLA    — trend dlog labour productivity (local-linear-trend on log(LA))
#   TDLLPOP  — trend dlog population        (local-linear-trend on log(LPOP))
#   TDLLHPP  — trend dlog hours per person  (random-walk + drift on log(LHPP))
#
# These were previously supplied only by `martin::read_fixture()` (i.e.
# spliced from `references/MARTIN-master/Data/martin_public.wf1`). Porting
# them removes the fixture dependency for the supply-side trends.
#
# The two model families:
#
#   * Random-walk + drift (TDLLHPP):
#       y_t   = TLLHPP_t + ε_t,                 ε_t ~ N(0, σ²)
#       state[t] = (TLLHPP_t, c_t)
#       TLLHPP_t = TLLHPP_{t-1} + c_{t-1} + η_t, η_t ~ N(0, σ²/param_lhpp)
#       c_t      = c_{t-1}                       (deterministic, diffuse prior)
#
#     The drift c is the single ML estimate of d/dt log(LHPP); EViews
#     stores it via `series tdllhpp = ss_lhpp.@coefs(1)` — a constant
#     across all t. We surface the same constant.
#
#   * Local-linear-trend with shared slope innovation (TDLLA / TDLLPOP):
#       y_t       = TLEVEL_t + ε_t,             ε_t ~ N(0, σ²)
#       state[t]  = (TLEVEL_t, TDRIFT_t)
#       TLEVEL_t  = TLEVEL_{t-1} + TDRIFT_{t-1} + η_LEVEL + η_DRIFT
#       TDRIFT_t  = TDRIFT_{t-1} + η_DRIFT
#       η_LEVEL ~ N(0, σ²/param_trend)
#       η_DRIFT ~ N(0, σ²/param_drift)
#
#     The "shared slope innovation" structure (η_DRIFT enters the level
#     equation too) is faithful to supply_side.prg lines 33-39. It's
#     implemented in KFAS as R = T = [[1,1],[0,1]] with diagonal Q.
#
# Each fit estimates a single parameter (σ², the observation variance)
# via fitSSM; the ratios σ²/param_* hold the state variances. The
# trend (drift) state is initialised with a diffuse prior, so its
# smoothed value is data-driven (no informative starting value needed).

# Variance ratio scalars from supply_side.prg:9-15.
SUPPLY_PARAM <- list(
  trend    = 100,    # ratio σ²_obs / σ²_TLLA-innovation
  drift    = 10000,  # ratio σ²_obs / σ²_TDLLA-innovation
  poptrend = 100,
  popdrift = 10000,
  lhpp     = 50
)

# Sample-start defaults from supply_side.prg.
SUPPLY_SAMPLE_START <- list(
  LA   = "1966Q1",
  LPOP = "1978Q3",
  LHPP = "1966Q1"
)

# m-priors from supply_side.prg, in (level_init, drift_init) form.
SUPPLY_MPRIOR <- list(
  LA   = c(3.687622086817885, 0.0070),
  LPOP = c(9.265860822608552, 0.0070),
  LHPP = c(6.20000, 0)  # only the level is informative; drift is diffuse
)

# v-priors from supply_side.prg `vprior.fill` calls. Diagonal entries
# only (off-diagonals are 0 in the EViews source). Tight on the drift
# state — the local-linear-trend fit is unstable without an informative
# prior on the trend slope; EViews enforces this via vprior_la.fill
# 0.0001, 0, 1e-06 (level var 1e-4, drift var 1e-6).
SUPPLY_VPRIOR <- list(
  LA   = c(0.0001, 1e-6),
  LPOP = c(0.0001, 1e-6),
  LHPP = c(1e-6,   1e-6)  # vprior_hpp.fill 1e-06
)

#' Apply the supply-side state-space trend handlers
#'
#' For each variable in [SUPPLY_PARAM] whose input is available in the
#' database, runs the corresponding KFAS state-space estimator and
#' inserts the smoothed trend(s) back into the database. Idempotent:
#' rows already in the database are left alone.
#'
#' Currently materialises `TDLLA`, `TDLLPOP`, `TDLLHPP` from `LA`, `LPOP`,
#' `LHPP`. Also produces the smoothed log-level trends (`TLLA`, `TLLPOP`,
#' `TLLHPP`) as a side effect. Skips a row if the required input is
#' missing.
#'
#' @param database Named list of bimets TIMESERIES.
#' @param catalogue [series_catalogue()] (unused in v0).
#' @return The database with trend series added.
#' @keywords internal
apply_state_space_trends <- function(database, catalogue = series_catalogue()) {
  # TDLLA + TLLA from log(LA)
  if (is.null(database$TDLLA) && !is.null(database$LA)) {
    fit <- tryCatch(
      fit_local_linear_trend(
        y_ts        = log(database$LA),
        sample_start = SUPPLY_SAMPLE_START$LA,
        mprior      = SUPPLY_MPRIOR$LA,
        vprior      = SUPPLY_VPRIOR$LA,
        param_trend = SUPPLY_PARAM$trend,
        param_drift = SUPPLY_PARAM$drift,
        param_name  = "LA"
      ),
      error = function(e) {
        warning("apply_state_space_trends: LA fit failed (",
                conditionMessage(e), "); skipping TDLLA/TLLA.",
                call. = FALSE)
        NULL
      }
    )
    if (!is.null(fit)) {
      database$TDLLA <- fit$TDRIFT
      if (is.null(database$TLLA)) database$TLLA <- fit$TLEVEL
    }
  }

  # TDLLPOP + TLLPOP from log(LPOP)
  if (is.null(database$TDLLPOP) && !is.null(database$LPOP)) {
    fit <- tryCatch(
      fit_local_linear_trend(
        y_ts        = log(database$LPOP),
        sample_start = SUPPLY_SAMPLE_START$LPOP,
        mprior      = SUPPLY_MPRIOR$LPOP,
        vprior      = SUPPLY_VPRIOR$LPOP,
        param_trend = SUPPLY_PARAM$poptrend,
        param_drift = SUPPLY_PARAM$popdrift,
        param_name  = "LPOP"
      ),
      error = function(e) {
        warning("apply_state_space_trends: LPOP fit failed (",
                conditionMessage(e), "); skipping TDLLPOP/TLLPOP.",
                call. = FALSE)
        NULL
      }
    )
    if (!is.null(fit)) {
      database$TDLLPOP <- fit$TDRIFT
      if (is.null(database$TLLPOP)) database$TLLPOP <- fit$TLEVEL
    }
  }

  # TDLLHPP + TLLHPP from log(LHPP)
  if (is.null(database$TDLLHPP) && !is.null(database$LHPP)) {
    fit <- tryCatch(
      fit_random_walk_drift(
        y_ts        = log(database$LHPP),
        sample_start = SUPPLY_SAMPLE_START$LHPP,
        mprior_level = SUPPLY_MPRIOR$LHPP[1],
        vprior_level = SUPPLY_VPRIOR$LHPP[1],
        param_lhpp  = SUPPLY_PARAM$lhpp,
        param_name  = "LHPP"
      ),
      error = function(e) {
        warning("apply_state_space_trends: LHPP fit failed (",
                conditionMessage(e), "); skipping TDLLHPP/TLLHPP.",
                call. = FALSE)
        NULL
      }
    )
    if (!is.null(fit)) {
      database$TDLLHPP <- fit$TDRIFT
      if (is.null(database$TLLHPP)) database$TLLHPP <- fit$TLEVEL
    }
  }

  database
}

#' Fit the local-linear-trend model (TDLLA / TDLLPOP)
#'
#' KFAS port of supply_side.prg lines 17-44 (TDLLA) and 46-73 (TDLLPOP).
#' Returns smoothed `TLEVEL` (log-trend level) and `TDRIFT` (log-trend
#' growth) as bimets TIMESERIES over the full input span — the drift
#' state is carried forward past the EViews estimation sample end via
#' the random-walk dynamics, matching the legacy "extend to last
#' observation" behaviour.
#'
#' @param y_ts A bimets ts of `log(LA)` (or `log(LPOP)`).
#' @param sample_start `"YYYYQq"` string; the first quarter in EViews's
#'   estimation `smpl`.
#' @param mprior 2-vector of initial (level, drift) prior means. Only
#'   the level is treated as informative; the drift uses a diffuse
#'   prior so its smoothed value is data-driven.
#' @param param_trend,param_drift Variance ratios from supply_side.prg.
#' @param param_name For error messages only.
#' @return List of `(TLEVEL = bimets_ts, TDRIFT = bimets_ts)`.
#' @keywords internal
fit_local_linear_trend <- function(y_ts, sample_start, mprior, vprior,
                                   param_trend, param_drift,
                                   param_name = "input") {
  # KFAS's formula DSL evaluates SSMcustom() in the calling frame, which
  # rejects `KFAS::` namespace prefixes. Aliasing SSMcustom as a local
  # makes it visible to model.frame without polluting the global env.
  SSMcustom <- KFAS::SSMcustom

  ts_meta <- ts_to_meta(y_ts)
  y_vec   <- as.numeric(y_ts)
  start_idx <- ts_meta$quarter_index(sample_start)
  if (is.na(start_idx) || start_idx > length(y_vec)) {
    stop(sprintf("Sample start %s is out of range for %s", sample_start,
                 param_name), call. = FALSE)
  }
  # Mask everything before sample_start as NA so the Kalman filter
  # ignores it (EViews's smpl restriction).
  y_obs <- y_vec
  if (start_idx > 1L) y_obs[seq_len(start_idx - 1L)] <- NA_real_

  # Build the SSMcustom state-space: (TLEVEL, TDRIFT) with shared slope
  # innovation. T = R = [[1,1],[0,1]]; Z = [1, 0]; diagonal Q.
  model <- KFAS::SSModel(
    y_obs ~ -1 + SSMcustom(
      Z = matrix(c(1, 0), nrow = 1),
      T = matrix(c(1, 0, 1, 1), nrow = 2),
      R = matrix(c(1, 0, 1, 1), nrow = 2),
      Q = diag(c(1e-6, 1e-8), 2, 2),
      a1 = matrix(c(mprior[1], mprior[2]), nrow = 2),
      P1 = diag(c(vprior[1], vprior[2]), 2, 2),
      P1inf = matrix(0, 2, 2),
      state_names = c("TLEVEL", "TDRIFT")
    ),
    H = matrix(1e-6)
  )

  # One free parameter: log σ². σ²_trend = σ²/param_trend, σ²_drift =
  # σ²/param_drift, σ²_obs = σ².
  update_fn <- function(pars, model) {
    s2 <- exp(pars[1])
    model$H[, , 1]    <- s2
    model$Q[1, 1, 1]  <- s2 / param_trend
    model$Q[2, 2, 1]  <- s2 / param_drift
    model
  }
  fit <- KFAS::fitSSM(model, inits = c(log(0.001)),
                      updatefn = update_fn, method = "BFGS")
  if (fit$optim.out$convergence != 0L) {
    warning(sprintf(
      "fit_local_linear_trend: optim did not converge for %s (code %d)",
      param_name, fit$optim.out$convergence), call. = FALSE)
  }
  ks <- KFAS::KFS(fit$model, smoothing = "state")
  tlevel_vec <- as.numeric(ks$alphahat[, "TLEVEL"])
  tdrift_vec <- as.numeric(ks$alphahat[, "TDRIFT"])

  # Mask pre-sample-start positions back to NA (EViews returns NA there
  # because the smpl restriction means no smoothed state exists yet).
  if (start_idx > 1L) {
    tlevel_vec[seq_len(start_idx - 1L)] <- NA_real_
    tdrift_vec[seq_len(start_idx - 1L)] <- NA_real_
  }

  list(
    TLEVEL = ts_meta$as_bimets(tlevel_vec),
    TDRIFT = ts_meta$as_bimets(tdrift_vec)
  )
}

#' Fit the random-walk + drift model (TDLLHPP)
#'
#' KFAS port of supply_side.prg lines 78-108. The drift `c` is a single
#' parameter (EViews `C(1)`); the legacy code surfaces it as a constant
#' series via `tdllhpp = ss_lhpp.@coefs(1)`. We reproduce that — `TDRIFT`
#' is constant across all quarters, equal to the data-driven smoothed
#' drift estimate. Within EViews's estimation smpl `TLLHPP` is the
#' smoothed level; beyond it, the EViews script carries the last value
#' forward, which we also do.
#'
#' @inheritParams fit_local_linear_trend
#' @param mprior_level Scalar prior mean for the initial level.
#' @param param_lhpp Variance ratio σ²_obs / σ²_state.
#' @return List of `(TLEVEL = bimets_ts, TDRIFT = bimets_ts)`.
#' @keywords internal
fit_random_walk_drift <- function(y_ts, sample_start, mprior_level,
                                  vprior_level, param_lhpp,
                                  param_name = "input") {
  # See fit_local_linear_trend(): KFAS's formula DSL rejects `KFAS::`
  # prefixes, so we alias SSMcustom locally.
  SSMcustom <- KFAS::SSMcustom

  ts_meta <- ts_to_meta(y_ts)
  y_vec   <- as.numeric(y_ts)
  start_idx <- ts_meta$quarter_index(sample_start)
  if (is.na(start_idx) || start_idx > length(y_vec)) {
    stop(sprintf("Sample start %s is out of range for %s", sample_start,
                 param_name), call. = FALSE)
  }
  y_obs <- y_vec
  if (start_idx > 1L) y_obs[seq_len(start_idx - 1L)] <- NA_real_

  # State = (TLLHPP, drift). Drift is constant across t (T[drift,drift] = 1,
  # no innovation), so once smoother locks in a single value it stays.
  model <- KFAS::SSModel(
    y_obs ~ -1 + SSMcustom(
      Z = matrix(c(1, 0), nrow = 1),
      T = matrix(c(1, 0, 1, 1), nrow = 2),
      R = matrix(c(1, 0), nrow = 2, ncol = 1),
      Q = matrix(1e-8),
      a1 = matrix(c(mprior_level, 0), nrow = 2),
      P1 = diag(c(vprior_level, 0), 2, 2),
      P1inf = diag(c(0, 1), 2, 2),  # drift is diffuse (LHPP has no drift prior)
      state_names = c("TLLHPP", "drift")
    ),
    H = matrix(1e-6)
  )

  update_fn <- function(pars, model) {
    s2 <- exp(pars[1])
    model$H[, , 1]   <- s2
    model$Q[1, 1, 1] <- s2 / param_lhpp
    model
  }
  fit <- KFAS::fitSSM(model, inits = c(log(0.0001)),
                      updatefn = update_fn, method = "BFGS")
  if (fit$optim.out$convergence != 0L) {
    warning(sprintf(
      "fit_random_walk_drift: optim did not converge for %s (code %d)",
      param_name, fit$optim.out$convergence), call. = FALSE)
  }
  ks <- KFAS::KFS(fit$model, smoothing = "state")
  tlevel_vec <- as.numeric(ks$alphahat[, "TLLHPP"])
  drift_const <- as.numeric(ks$alphahat[1, "drift"])

  if (start_idx > 1L) {
    tlevel_vec[seq_len(start_idx - 1L)] <- NA_real_
  }

  # TDLLHPP is the constant drift value broadcast across the whole span.
  tdrift_vec <- rep(drift_const, length(tlevel_vec))

  list(
    TLEVEL = ts_meta$as_bimets(tlevel_vec),
    TDRIFT = ts_meta$as_bimets(tdrift_vec)
  )
}

# Internal: extract the bimets ts metadata needed to round-trip a numeric
# vector through (parse a "YYYYQq" string, build new bimets ts at the
# same start).
ts_to_meta <- function(ts) {
  tsp <- stats::tsp(ts)
  start_dec <- tsp[1]
  start_year    <- floor(start_dec + 1e-9)
  start_quarter <- round((start_dec - start_year) * 4 + 1)
  list(
    start_year    = start_year,
    start_quarter = start_quarter,
    quarter_index = function(yq_str) {
      yq <- parse_yyyyQq(yq_str)
      (yq$year - start_year) * 4L + (yq$quarter - start_quarter) + 1L
    },
    as_bimets = function(vec) {
      bimets::TIMESERIES(vec, START = c(start_year, start_quarter), FREQ = 4)
    }
  )
}
