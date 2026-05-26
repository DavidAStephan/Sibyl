#' Pre-compute sensitivity of headline aggregates to per-equation unit shocks
#'
#' For each adjustable behavioural equation, applies a standardized add-factor
#' shock of size `1 x typical_af_sd` sustained over `shock_quarters` with a
#' `decay_50` tail, solves the model, and records the deviation from baseline
#' on each of `targets` at offsets `measure_offsets` quarters after the shock
#' start. The resulting matrix is intended for inclusion in the
#' `judgement::propose_adjustments()` system prompt so the LLM can reason
#' about realised propagation instead of guessing.
#'
#' The model is loaded and ESTIMATEd once and re-used across all shocks, so
#' the cost is approximately N_equations x simulate_time (a few seconds per
#' equation) rather than N x full_solve.
#'
#' @param database The same database passed to [solve_martin()].
#' @param baseline A baseline projection tibble (from [solve_martin()] with
#'   no adjustments) used as the comparison point. Must cover the offsets
#'   measured.
#' @param horizon  Length-2 `c("yyyyQq", "yyyyQq")`.
#' @param estimation_end Optional `"yyyyQq"`. When non-NULL, behaviorals are
#'   re-estimated through this quarter before the shocks (same convention as
#'   [solve_martin()]). NULL = frozen model coefficients.
#' @param shock_start  `"yyyyQq"` for the first quarter of the sustained
#'   shock. Defaults to `horizon[1]`. Choose a quarter where the projection
#'   has meaningful forward propagation (e.g. just after `estimation_end`).
#' @param shock_quarters Integer length of the sustained shock. Default 4.
#' @param measure_offsets Integer vector of quarter offsets from `shock_start`
#'   at which to record deviations. Default `c(1, 4, 8, 16)`.
#' @param targets Character vector of MARTIN variables whose deviations are
#'   recorded. Default = headline aggregates.
#' @param equations Optional character vector restricting the shocks to a
#'   subset of equations. Default NULL = all adjustable equations from
#'   [equation_catalogue()].
#' @param progress Logical; if TRUE prints a one-line progress update per
#'   equation. Default `interactive()`.
#'
#' @return A tibble with one row per (equation, target, offset). Columns:
#'   `equation`, `units`, `typical_af_sd`, `shock_value`, `shock_quarters`,
#'   `target`, `offset_q`, `deviation`, `deviation_pct`.
#'   Attributes: `shock_start`, `measure_offsets`, `baseline_scenario`.
#' @export
sensitivity_matrix <- function(database,
                               baseline,
                               horizon,
                               estimation_end  = NULL,
                               shock_start     = horizon[1],
                               shock_quarters  = 4L,
                               measure_offsets = c(1L, 4L, 8L, 16L),
                               targets         = c("Y", "RC", "GNE", "LUR",
                                                   "PTM", "P", "NCR"),
                               equations       = NULL,
                               progress        = interactive()) {
  stopifnot(
    is.data.frame(baseline),
    length(horizon) == 2L, is.character(horizon),
    is.numeric(shock_quarters), shock_quarters >= 1L,
    is.numeric(measure_offsets), all(measure_offsets >= 1L),
    is.character(targets), length(targets) >= 1L
  )
  shock_quarters <- as.integer(shock_quarters)
  measure_offsets <- as.integer(measure_offsets)

  cat <- equation_catalogue()
  adj <- cat[isTRUE_vec(cat$adjustable), , drop = FALSE]
  if (!is.null(equations)) {
    adj <- adj[adj$code %in% equations, , drop = FALSE]
    if (nrow(adj) == 0L) {
      stop("None of the requested `equations` are in the adjustable catalogue.",
           call. = FALSE)
    }
  }

  # Load + ESTIMATE the model ONCE; re-used across all shocks.
  model <- load_martin(
    database, variant = "af", estimate = TRUE,
    estimation_end = estimation_end
  )

  start <- judgement_parse_quarter(horizon[1])
  end   <- judgement_parse_quarter(horizon[2])
  tsrange <- c(start$year, start$quarter, end$year, end$quarter)

  # Build the replay AFs once; we'll inject one user shock per equation.
  replay_afs <- residual_constant_adjustment(model)
  replay_afs <- lapply(replay_afs, function(ts) {
    extend_residual_with_decay(ts, end$year, end$quarter)
  })

  # Shock horizon (sustained over shock_quarters from shock_start).
  shock_qs <- quarter_offsets(shock_start, n_after = shock_quarters - 1L)

  # Convert baseline tibble to a fast-lookup: variable -> named vector keyed
  # by quarter.
  baseline_lookup <- lapply(split(baseline, baseline$variable), function(d) {
    setNames(d$value, d$quarter)
  })

  # Pre-compute the quarters we'll measure at, indexed by offset.
  measure_qs <- vapply(measure_offsets, function(o) {
    quarter_offsets(shock_start, n_after = o)[o + 1L]
  }, character(1))

  rows <- list()
  n_eq <- nrow(adj)
  for (i in seq_len(n_eq)) {
    eq        <- adj$code[i]
    units     <- adj$units[i]
    af_sd     <- adj$typical_af_sd[i]
    # Use a small per-unit-type calibration shock. typical_af_sd is set
    # too high for log_diff equations (0.1 on log_diff = +10pp/quarter,
    # which blows the simulator). The LLM can scale these results
    # linearly to estimate the impact of larger shocks.
    shock_val <- sensitivity_shock_for_units(units)

    if (progress) message(sprintf(
      "[sensitivity_matrix] %3d/%d  shocking %-6s (value=%g over %d quarters, units=%s)",
      i, n_eq, eq, shock_val, shock_quarters, units
    ))

    # Construct the shock as a real adjustment_list with decay_50 tail, then
    # expand it through the full horizon. This matches how user-supplied AFs
    # are handled in solve_martin() (decay applies past the explicit
    # horizon, so propagation at h+8/h+16 reflects real SIBYL conventions).
    shock <- judgement::adjustment_list(
      judgement::adjustment(
        equation        = eq,
        horizon         = shock_qs,
        value           = rep(shock_val, shock_quarters),
        rationale       = "sensitivity probe",
        channel         = NA_character_,
        expected_effect = NA_character_,
        confidence      = "medium",
        tail            = "decay_50",
        owner           = "sensitivity_matrix",
        round_id        = NA_character_,
        source          = "human"
      )
    )
    user_expanded <- judgement::expand_adjustments(shock, horizon)
    afs <- inject_user_adjustments(replay_afs, user_expanded)

    sim_model <- .suppress_bimets_version_warning({
      suppressWarnings(suppressMessages(bimets::SIMULATE(
        model,
        TSRANGE            = tsrange,
        ConstantAdjustment = afs,
        simConvergence     = 1e-6,
        simIterLimit       = 100,
        quietly            = TRUE
      )))
    })

    sim <- sim_model$simulation
    for (tgt in targets) {
      tgt_ts <- sim[[tgt]]
      if (is.null(tgt_ts)) next
      tgt_t      <- as.numeric(stats::time(tgt_ts))
      tgt_year   <- floor(tgt_t + 1e-9)
      tgt_q      <- round((tgt_t - tgt_year) * 4 + 1)
      tgt_labels <- sprintf("%04dQ%d", tgt_year, tgt_q)
      tgt_vec    <- setNames(as.numeric(tgt_ts), tgt_labels)
      base_vec   <- baseline_lookup[[tgt]]
      if (is.null(base_vec)) next

      for (j in seq_along(measure_offsets)) {
        q <- measure_qs[j]
        if (is.na(q) || is.null(tgt_vec[q]) || is.null(base_vec[q])) next
        if (!q %in% names(tgt_vec) || !q %in% names(base_vec)) next
        dev <- unname(tgt_vec[q]) - unname(base_vec[q])
        base_at_q <- unname(base_vec[q])
        dev_pct <- if (abs(base_at_q) > 1e-9) 100 * dev / abs(base_at_q) else NA_real_
        rows[[length(rows) + 1L]] <- tibble::tibble(
          equation       = eq,
          units          = units,
          typical_af_sd  = af_sd,
          shock_value    = shock_val,
          shock_quarters = shock_quarters,
          target         = tgt,
          offset_q       = measure_offsets[j],
          deviation      = dev,
          deviation_pct  = dev_pct
        )
      }
    }
  }

  out <- dplyr::bind_rows(rows)
  attr(out, "shock_start")       <- shock_start
  attr(out, "measure_offsets")   <- measure_offsets
  attr(out, "baseline_scenario") <- unique(baseline$scenario)[1]
  out
}

# Per-unit-type calibration shock. Chosen to be (a) economically meaningful,
# (b) small enough not to blow up MARTIN, (c) easy for the LLM to scale.
sensitivity_shock_for_units <- function(units) {
  switch(
    units,
    log_diff = 0.001,   # +0.1pp/quarter on the inflation/growth rate
    level    = 0.05,    # +0.05 on the LHS's level (LUR: +0.05pp/quarter on diff)
    percent  = 0.10,    # +10bp on the rate
    0.01                # fallback
  )
}

# Like vapply(x, isTRUE, logical(1)) but treats NA as FALSE.
isTRUE_vec <- function(x) !is.na(x) & as.logical(x)

# Generate `c(start, start+1, ..., start+n_after)` in "yyyyQq" form.
quarter_offsets <- function(start, n_after) {
  s <- judgement_parse_quarter(start)
  abs_q <- s$year * 4L + (s$quarter - 1L) + seq.int(0L, n_after)
  year    <- abs_q %/% 4L
  quarter <- (abs_q %% 4L) + 1L
  sprintf("%04dQ%d", year, quarter)
}
