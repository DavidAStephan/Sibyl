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
  if (is.null(database[["TDLLA"]]) && !is.null(database[["LA"]])) {
    fit <- tryCatch(
      fit_local_linear_trend(
        y_ts        = log(database[["LA"]]),
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
      database[["TDLLA"]] <- fit$TDRIFT
      if (is.null(database[["TLLA"]])) database[["TLLA"]] <- fit$TLEVEL
    }
  }

  # TDLLPOP + TLLPOP from log(LPOP)
  if (is.null(database[["TDLLPOP"]]) && !is.null(database[["LPOP"]])) {
    fit <- tryCatch(
      fit_local_linear_trend(
        y_ts        = log(database[["LPOP"]]),
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
      database[["TDLLPOP"]] <- fit$TDRIFT
      if (is.null(database[["TLLPOP"]])) database[["TLLPOP"]] <- fit$TLEVEL
    }
  }

  # PI_E from 7-signal local-level KFAS port of pistar.prg.
  # R's `$` partial-matches `database[["PI_E"]]` to `database[["PI_E_BOND"]]` —
  # use `[[` everywhere for exact matching on these closely-named series.
  if (is.null(database[["PI_E"]]) &&
      !is.null(database[["PTM"]]) &&
      !is.null(database[["PI_E_BOND"]])) {
    fit <- tryCatch(
      fit_pie_kfas(database, sample_start = "1985Q4"),
      error = function(e) {
        warning("apply_state_space_trends: PI_E fit failed (",
                conditionMessage(e), "); skipping PI_E.",
                call. = FALSE)
        NULL
      }
    )
    if (!is.null(fit)) database[["PI_E"]] <- fit$PI_E
  }

  # TLUR (NAIRU) — Phillips-curve state-space, 2-signal (dlptm, dlulc)
  if (is.null(database[["TLUR"]]) &&
      !is.null(database[["LUR"]]) &&
      !is.null(database[["PTM"]]) &&
      !is.null(database[["Y"]]) &&
      !is.null(database[["NHCOE"]])) {
    fit <- tryCatch(
      fit_nairu_kfas(database, sample_start = "1986Q3"),
      error = function(e) {
        warning("apply_state_space_trends: TLUR fit failed (",
                conditionMessage(e), "); skipping TLUR.",
                call. = FALSE)
        NULL
      }
    )
    if (!is.null(fit)) database[["TLUR"]] <- fit$TLUR
  }

  # RSTAR — neutral rate as smoothed real cash rate (v0 simplification of
  # rstar.prg's 11-state model; see fit_rstar_kfas docstring).
  if (is.null(database[["RSTAR"]]) &&
      !is.null(database[["NCR"]]) &&
      !is.null(database[["PTM"]])) {
    fit <- tryCatch(
      fit_rstar_kfas(database, sample_start = "1986Q3"),
      error = function(e) {
        warning("apply_state_space_trends: RSTAR fit failed (",
                conditionMessage(e), "); skipping RSTAR.",
                call. = FALSE)
        NULL
      }
    )
    if (!is.null(fit)) database[["RSTAR"]] <- fit$RSTAR
  }

  # TDLLHPP + TLLHPP from log(LHPP)
  if (is.null(database[["TDLLHPP"]]) && !is.null(database[["LHPP"]])) {
    fit <- tryCatch(
      fit_random_walk_drift(
        y_ts        = log(database[["LHPP"]]),
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
      database[["TDLLHPP"]] <- fit$TDRIFT
      if (is.null(database[["TLLHPP"]])) database[["TLLHPP"]] <- fit$TLEVEL
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

# ===========================================================================
# Inflation expectations (PI_E) — port of pistar.prg
# ===========================================================================

#' Fit the 7-signal local-level model for PI_E
#'
#' Simplified KFAS port of `pistar.prg`. The full EViews model has an AR(1)
#' correction on the DL4PTM signal and GST dummies on each survey
#' equation; v0 drops both and treats the seven inflation indicators
#' (year-on-year trimmed-mean CPI plus six survey/market-based
#' expectation series) as direct noisy observations of a common trend
#' inflation state `cpistar`:
#'
#'   y_t = (1, 1, 1, 1, 1, 1, 1)^T · cpistar_t + eps_t   eps ~ N(0, H)
#'   cpistar_t = cpistar_{t-1} + eta_t                    eta ~ N(0, sigma_state^2)
#'
#' Free parameters: 7 observation sigmas + 1 state sigma, estimated by
#' fitSSM. The state is initialised with a diffuse prior, so its
#' smoothed value at t=1 is data-driven.
#'
#' Inputs from `database` (must all be present):
#'   PTM        → DL4PTM = 100 * log(PTM_t / PTM_{t-4})
#'   GBUSEXP, GUNIEXPY, GUNIEXPYY, GMAREXPY, GMAREXPYY  (RBA G3 survey series)
#'   PI_E_BOND  → used as the GBONYLD signal (the raw bond-implied
#'                inflation series in our catalogue)
#'
#' The estimation sample starts when at least one signal first has data;
#' `sample_start` is the EViews `%firstdate` default (typically 1985Q4
#' when PI_E_BOND first reports).
#'
#' @param database Named list of bimets TIMESERIES.
#' @param sample_start `"YYYYQq"` string; first quarter to include.
#' @return List with a single element `PI_E`: a bimets ts of the smoothed
#'   trend inflation expectation, broadcast over the full database span.
#' @keywords internal
fit_pie_kfas <- function(database, sample_start = "1985Q4") {
  SSMcustom <- KFAS::SSMcustom

  signal_vars <- c("GBUSEXP", "GUNIEXPY", "GUNIEXPYY",
                   "GMAREXPY", "GMAREXPYY", "PI_E_BOND")
  for (v in signal_vars) {
    if (is.null(database[[v]])) {
      stop("fit_pie_kfas: missing input series ", v, call. = FALSE)
    }
  }
  ts_meta <- ts_to_meta(database[["PTM"]])

  # DL4PTM = 100 * log(PTM_t / PTM_{t-4}). NA for the first 4 quarters.
  ptm_vec <- as.numeric(database[["PTM"]])
  n_total <- length(ptm_vec)
  dl4ptm  <- rep(NA_real_, n_total)
  for (i in seq.int(5L, n_total)) {
    if (!is.na(ptm_vec[i]) && !is.na(ptm_vec[i - 4L]) && ptm_vec[i - 4L] > 0) {
      dl4ptm[i] <- 100 * (log(ptm_vec[i]) - log(ptm_vec[i - 4L]))
    }
  }

  # Align each signal to the PTM time grid (the longest input).
  align_to_ptm <- function(other_ts) {
    other_tsp <- stats::tsp(other_ts)
    other_v   <- as.numeric(other_ts)
    other_y   <- floor(other_tsp[1] + 1e-9)
    other_q   <- round((other_tsp[1] - other_y) * 4 + 1)
    offset    <- (other_y - ts_meta$start_year) * 4L +
                 (other_q - ts_meta$start_quarter)
    out <- rep(NA_real_, n_total)
    lo <- max(1L, 1L + offset)
    hi <- min(n_total, length(other_v) + offset)
    if (lo <= hi) {
      out[lo:hi] <- other_v[(lo - offset):(hi - offset)]
    }
    out
  }

  Y <- cbind(
    DL4PTM    = dl4ptm,
    GBUSEXP   = align_to_ptm(database[["GBUSEXP"]]),
    GUNIEXPY  = align_to_ptm(database[["GUNIEXPY"]]),
    GUNIEXPYY = align_to_ptm(database[["GUNIEXPYY"]]),
    GMAREXPY  = align_to_ptm(database[["GMAREXPY"]]),
    GMAREXPYY = align_to_ptm(database[["GMAREXPYY"]]),
    PI_E_BOND = align_to_ptm(database[["PI_E_BOND"]])
  )
  # KFAS rejects Inf/NaN in observations but accepts NA. PTM zeros from
  # level_from_pct's pre-base quarters propagate to DL4PTM as Inf; mask
  # them out (and any other non-finite cells defensively).
  Y[!is.finite(Y)] <- NA_real_
  n_sig <- ncol(Y)

  # Mask quarters before sample_start.
  start_idx <- ts_meta$quarter_index(sample_start)
  if (start_idx > 1L) Y[seq_len(start_idx - 1L), ] <- NA_real_

  # Seven-signal local-level: state is scalar cpistar.
  # Initial mean = mean of available signals at first valid quarter (or 2.5).
  first_obs <- Y[start_idx, ]
  init_mean <- if (any(!is.na(first_obs))) mean(first_obs, na.rm = TRUE) else 2.5

  model <- KFAS::SSModel(
    Y ~ -1 + SSMcustom(
      Z = matrix(rep(1, n_sig), nrow = n_sig, ncol = 1),
      T = matrix(1),
      R = matrix(1),
      Q = matrix(0.1),
      a1 = matrix(init_mean),
      P1 = matrix(0.5),   # vprior_pie diagonal (0.5)
      P1inf = matrix(0),
      state_names = "cpistar"
    ),
    H = diag(rep(0.1, n_sig))
  )

  # 8 free parameters: 7 obs sigmas + 1 state sigma. All on log scale.
  update_fn <- function(pars, model) {
    obs_vars <- exp(pars[1:7])
    state_var <- exp(pars[8])
    model$H[, , 1] <- diag(obs_vars)
    model$Q[, , 1] <- state_var
    model
  }
  fit <- KFAS::fitSSM(model,
                      inits = c(rep(log(1), 7), log(0.05)),
                      updatefn = update_fn, method = "BFGS")
  if (fit$optim.out$convergence != 0L) {
    warning(sprintf("fit_pie_kfas: optim convergence code %d",
                    fit$optim.out$convergence), call. = FALSE)
  }
  ks <- KFAS::KFS(fit$model, smoothing = "state")
  pie_vec <- as.numeric(ks$alphahat[, "cpistar"])
  if (start_idx > 1L) pie_vec[seq_len(start_idx - 1L)] <- NA_real_
  list(PI_E = ts_meta$as_bimets(pie_vec))
}

# ===========================================================================
# NAIRU (TLUR) — port of nairu.prg
# ===========================================================================

#' Fit the NAIRU state-space (TLUR)
#'
#' KFAS port of `nairu.prg`. The full EViews model is a 2-signal Phillips
#' curve + unit-labour-cost system with NAIRU as the state. Many lagged
#' regressors are pre-estimated via OLS in the EViews script; we mirror
#' that two-step structure:
#'
#'   1. Use HP-smoothed LUR as an initial NAIRU guess.
#'   2. Pre-estimate the Phillips-curve slope coefficients (gamma_1,
#'      gamma_2) via OLS using the HP-smoothed NAIRU.
#'   3. Run KFAS with those gammas fixed to extract a smoothed NAIRU
#'      state.
#'
#' Simplified signal equations (no Okun-law unemployment-change term,
#' no import-price pass-through, no lagged inflation autoregression —
#' v0 keeps the core Phillips-curve relationship between unemployment
#' gap and inflation):
#'
#'   dlptm_t = pi_eq_t + gamma_1 * (LUR_t - NAIRU_t) + e1
#'   dlulc_t = pi_eq_t + gamma_2 * (LUR_t - NAIRU_t) + e2
#'   NAIRU_t = NAIRU_{t-1} + e3
#'
#' Where pi_eq_t = ((1 + PI_E_t/100)^(1/4) - 1) * 100 is the quarterly
#' inflation-expectation rate. The pre-subtracted observations are:
#'
#'   y1_t - gamma_1 * LUR_t = -gamma_1 * NAIRU_t + e1
#'
#' which is a linear state-space with constant Z = -gamma_1 once
#' gamma_1 is fixed.
#'
#' @param database Named list of bimets ts (needs PTM, NHCOE, Y, LUR;
#'   PI_E recommended).
#' @param sample_start `"YYYYQq"` string.
#' @return List with `TLUR` (smoothed NAIRU as bimets ts).
#' @keywords internal
fit_nairu_kfas <- function(database, sample_start = "1986Q3") {
  SSMcustom <- KFAS::SSMcustom

  ts_meta <- ts_to_meta(database[["LUR"]])
  n_total <- length(as.numeric(database[["LUR"]]))

  # Align all inputs to the LUR time grid.
  align <- function(x) {
    other_tsp <- stats::tsp(x)
    other_v   <- as.numeric(x)
    other_y   <- floor(other_tsp[1] + 1e-9)
    other_q   <- round((other_tsp[1] - other_y) * 4 + 1)
    offset    <- (other_y - ts_meta$start_year) * 4L +
                 (other_q - ts_meta$start_quarter)
    out <- rep(NA_real_, n_total)
    lo <- max(1L, 1L + offset)
    hi <- min(n_total, length(other_v) + offset)
    if (lo <= hi) out[lo:hi] <- other_v[(lo - offset):(hi - offset)]
    out
  }
  lur   <- as.numeric(database[["LUR"]])
  ptm   <- align(database[["PTM"]])
  nhcoe <- align(database[["NHCOE"]])
  y_gdp <- align(database[["Y"]])
  pi_e  <- if (!is.null(database[["PI_E"]])) align(database[["PI_E"]]) else rep(2.5, n_total)

  # dlptm = 100 * dlog(PTM), dlulc = 100 * dlog(NHCOE/Y).
  dlptm <- c(NA, 100 * diff(log(ptm)))
  ulc   <- nhcoe / y_gdp
  dlulc <- c(NA, 100 * diff(log(ulc)))
  pi_eq <- ((1 + pi_e / 100) ^ (1 / 4) - 1) * 100

  start_idx <- ts_meta$quarter_index(sample_start)
  if (is.na(start_idx) || start_idx < 1L) start_idx <- 1L

  # Step 1: HP-smoothed LUR as initial NAIRU guess. KFAS makes this a
  # local-linear-trend with no observation noise; equivalent to HP filter
  # with lambda = 1 / (signal-to-noise ratio). For simplicity, we just
  # take a centred moving average over 20 quarters as the seed.
  win <- 20L
  lur_sm <- stats::filter(lur, rep(1 / win, win), sides = 2)
  lur_sm <- as.numeric(lur_sm)
  # Fill ends by carrying nearest non-NA forward / backward.
  nonna <- which(!is.na(lur_sm))
  if (length(nonna)) {
    lur_sm[seq_len(nonna[1] - 1L)] <- lur_sm[nonna[1]]
    lur_sm[(tail(nonna, 1) + 1L):n_total] <- lur_sm[tail(nonna, 1)]
  }

  # Step 2: OLS pre-estimate of gamma_1, gamma_2.
  mask <- seq.int(start_idx, n_total)
  lhs_ptm <- dlptm[mask] - pi_eq[mask]
  lhs_ulc <- dlulc[mask] - pi_eq[mask]
  ugap    <- lur[mask] - lur_sm[mask]

  # is.finite (not !is.na) — PTM = 0 at level_from_pct pre-base quarters
  # yields Inf in dlptm, which is_na ignores but lm() chokes on.
  ok_ptm <- is.finite(lhs_ptm) & is.finite(ugap)
  ok_ulc <- is.finite(lhs_ulc) & is.finite(ugap)
  gamma_1 <- if (sum(ok_ptm) > 5L) {
    coef(stats::lm(lhs_ptm[ok_ptm] ~ ugap[ok_ptm] - 1))[1]
  } else -0.1
  gamma_2 <- if (sum(ok_ulc) > 5L) {
    coef(stats::lm(lhs_ulc[ok_ulc] ~ ugap[ok_ulc] - 1))[1]
  } else -0.1

  # Step 3: KFAS smoother with gammas fixed.
  # Modified observations: y1_mod = (dlptm - pi_eq) - gamma_1 * LUR.
  # Signal equation:  y1_mod = -gamma_1 * NAIRU + e1.
  y1 <- (dlptm - pi_eq) - gamma_1 * lur
  y2 <- (dlulc - pi_eq) - gamma_2 * lur
  Y  <- cbind(y1 = y1, y2 = y2)
  # PTM = 0 at pre-base quarters of level_from_pct yields Inf in dlptm;
  # mask non-finite cells to NA (KFAS treats NA as missing observation).
  Y[!is.finite(Y)] <- NA_real_
  if (start_idx > 1L) Y[seq_len(start_idx - 1L), ] <- NA_real_

  # Initial NAIRU near 5.5 (literature value used by EViews mprior).
  init_nairu <- if (!is.na(lur_sm[start_idx])) lur_sm[start_idx] else 5.5

  model <- KFAS::SSModel(
    Y ~ -1 + SSMcustom(
      Z = matrix(c(-gamma_1, -gamma_2), nrow = 2, ncol = 1),
      T = matrix(1),
      R = matrix(1),
      Q = matrix(0.1),
      a1 = matrix(init_nairu),
      P1 = matrix(0.4),
      P1inf = matrix(0),
      state_names = "NAIRU"
    ),
    H = diag(c(0.1, 0.1))
  )

  update_fn <- function(pars, model) {
    model$H[1, 1, 1] <- exp(pars[1])
    model$H[2, 2, 1] <- exp(pars[2])
    model$Q[1, 1, 1] <- exp(pars[3])
    model
  }
  fit <- KFAS::fitSSM(model, inits = c(log(0.1), log(0.1), log(0.05)),
                      updatefn = update_fn, method = "BFGS")
  if (fit$optim.out$convergence != 0L) {
    warning(sprintf("fit_nairu_kfas: optim convergence code %d",
                    fit$optim.out$convergence), call. = FALSE)
  }
  ks <- KFAS::KFS(fit$model, smoothing = "state")
  tlur_vec <- as.numeric(ks$alphahat[, "NAIRU"])
  if (start_idx > 1L) tlur_vec[seq_len(start_idx - 1L)] <- NA_real_
  list(TLUR = ts_meta$as_bimets(tlur_vec))
}

# ===========================================================================
# Neutral rate (RSTAR) — simplified port of rstar.prg
# ===========================================================================

#' Fit the neutral interest rate (RSTAR) state-space
#'
#' v0 simplification of `rstar.prg`. The full EViews model is an 11-state
#' system (output gap with 3 lags, potential GDP, trend growth, NAIRU
#' with 1 lag, neutral rate with 1 lag, and an unexplained-rate state z)
#' tied together by Okun's-law and Phillips-curve signal equations.
#' That's a session unto itself.
#'
#' For v0 we model RSTAR as the smoothed trend of the real cash rate:
#'
#'   rcash_t = NCR_t - 4 * 100 * dlog(PTM)_t
#'   y_t      = TLEVEL_t + eps_t                     eps ~ N(0, sigma_obs)
#'   TLEVEL_t = TLEVEL_{t-1} + TDRIFT_{t-1} + eta1   eta1 ~ N(0, q1)
#'   TDRIFT_t = TDRIFT_{t-1} + eta2                  eta2 ~ N(0, q2)
#'
#' RSTAR = TLEVEL (the trend real cash rate). Justification: in the long
#' run the cash rate equals the neutral rate plus an output-gap response,
#' so smoothing rcash filters out the cyclical component. This loses
#' rstar.prg's z-state (additional unexplained rstar drift) but captures
#' the dominant slow movement.
#'
#' @param database Named list of bimets ts (needs NCR, PTM).
#' @param sample_start `"YYYYQq"` string.
#' @return List with `RSTAR` (smoothed neutral real cash rate, bimets ts).
#' @keywords internal
fit_rstar_kfas <- function(database, sample_start = "1986Q3") {
  ts_meta <- ts_to_meta(database[["NCR"]])
  n_total <- length(as.numeric(database[["NCR"]]))

  align <- function(x) {
    other_tsp <- stats::tsp(x)
    other_v   <- as.numeric(x)
    other_y   <- floor(other_tsp[1] + 1e-9)
    other_q   <- round((other_tsp[1] - other_y) * 4 + 1)
    offset    <- (other_y - ts_meta$start_year) * 4L +
                 (other_q - ts_meta$start_quarter)
    out <- rep(NA_real_, n_total)
    lo <- max(1L, 1L + offset)
    hi <- min(n_total, length(other_v) + offset)
    if (lo <= hi) out[lo:hi] <- other_v[(lo - offset):(hi - offset)]
    out
  }
  ncr <- as.numeric(database[["NCR"]])
  ptm <- align(database[["PTM"]])
  # Mask non-positive PTM (e.g. pre-base quarters of level_from_pct) before
  # taking log/diff, else dlptm gets -Inf and propagates to rcash.
  ptm[!is.na(ptm) & ptm <= 0] <- NA_real_
  dlptm <- c(NA, diff(log(ptm))) * 100
  rcash <- ncr - 4 * dlptm
  rcash[!is.finite(rcash)] <- NA_real_

  rcash_ts <- ts_meta$as_bimets(rcash)
  # param_trend = 1600 (HP-filter-like smoothing) — rcash is very noisy
  # quarter-to-quarter; with param_trend = 100 the smoother chases the
  # spikes and produces an unreasonably volatile TLEVEL.
  fit_llt <- fit_local_linear_trend(
    y_ts         = rcash_ts,
    sample_start = sample_start,
    mprior       = c(3.0, 0),    # ~3% neutral real cash rate (Aus historical avg)
    vprior       = c(0.5, 0.01),
    param_trend  = 1600,
    param_drift  = 16000,
    param_name   = "rcash"
  )
  list(RSTAR = fit_llt$TLEVEL)
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
