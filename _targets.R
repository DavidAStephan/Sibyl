# SIBYL end-to-end pipeline.
#
# Stages: data -> nowcast -> martin (baseline) -> judgement (propose AFs)
#         -> human review -> martin (with AFs) -> judgement (describe + audit)
#         -> Quarto report
#
# The pipeline is runnable end-to-end without API keys:
#   - Default `data_source = "fixture"` reads the bundled MARTINDATA xlsx,
#     synthesises a ragged edge by truncating handover variables, and
#     reconstructs them via nowcast — so the data path is exercised even
#     without live ABS / RBA / FRED access.
#   - `propose_adjustments()` is bypassed (returns an empty adjustment
#     list) when ANTHROPIC_API_KEY is unset; the round shows the
#     no-adjustment baseline + a notice.
#
# Run with: `targets::tar_make()` or `just pipeline`.
# Visualise: `targets::tar_visnetwork()`.

library(targets)
library(tarchetypes)

tar_option_set(
  packages = c(
    "tibble", "dplyr", "tidyr", "purrr",
    "sibyldata", "nowcast", "martin", "judgement"
  ),
  format   = "rds",
  error    = "stop"
)

# Make the local packages importable; pkgload::load_all picks up edits.
for (pkg in c("packages/judgement", "packages/martin",
              "packages/nowcast",   "packages/sibyldata")) {
  if (dir.exists(pkg)) try(pkgload::load_all(pkg, quiet = TRUE), silent = TRUE)
}

# Helper: synthesise a ragged-edge database from a "complete" fixture so
# nowcast has something to do. Drops the last `n_chop` quarters from each
# handover variable; leaves non-handover series intact.
chop_for_ragged_edge <- function(db, n_chop = 2L) {
  hv <- intersect(nowcast::handover_variables(), names(db))
  for (v in hv) {
    full <- as.numeric(db[[v]])
    n <- length(full)
    if (n < (n_chop + 8L)) next  # skip short series
    tsp <- stats::tsp(db[[v]])
    yr <- floor(tsp[1] + 1e-9)
    q  <- round((tsp[1] - yr) * 4 + 1)
    db[[v]] <- bimets::TIMESERIES(
      full[1:(n - n_chop)],
      START = c(yr, q), FREQ = 4
    )
  }
  db
}

list(

  # ---------------------------------------------------------------------------
  # 1. Round configuration
  # ---------------------------------------------------------------------------
  tar_target(round_id,
    paste0(format(Sys.Date(), "%Y"), "Q",
           ((as.integer(format(Sys.Date(), "%m")) - 1) %/% 3) + 1,
           "_round1")
  ),

  # "fixture" reads packages/martin/inst/extdata/martin_data_fixture.xlsx
  # directly. "live" fetches from every implemented public source, pivots
  # via sibyldata::to_martin_database() (which now includes the
  # deterministic dummy/scalar handlers), and merges the result against
  # the fixture so MARTIN's behavioural-equation TSRANGEs still have
  # full histories for series the live data can't reach back to.
  tar_target(data_source, "live"),

  # The narrative the round is built on. Plain string; edit in this file
  # or read from `narrative.txt` if you prefer.
  tar_target(narrative,
    paste(
      "Employment growth has been persistently stronger than the model",
      "predicts since the post-COVID reopening - possibly reflecting",
      "structural changes in labour-force attachment (long-COVID exits,",
      "care-economy growth, immigration composition). We expect this to",
      "persist, lowering the unemployment rate by roughly 1.5 percentage",
      "points below baseline through 2025Q4. No change to our view on",
      "the cash-rate path or inflation."
    )
  ),

  # Solve horizon. Extended to cover the latest National Accounts
  # release (2025Q4) now that the merge correctly coalesces live data
  # past the fixture's 2019Q3 cutoff. MARTIN's behavioural-equation
  # estimation samples still end 2019Q3 (frozen-coefficient design),
  # but the solve itself produces in-sample backcasts through the
  # available data and projects forward from there. Future-horizon
  # support (DESIGN.md item 7) is needed to extend past the data end.
  tar_target(horizon, c("2010Q1", "2025Q4")),

  # Re-estimation sample end. Behaviorals re-fit on data through this
  # quarter (overriding the model file's 2019Q3 default). Set to NULL to
  # use the frozen 2019Q3 coefficients. 2025Q2 picks up post-COVID
  # inflation / wages dynamics without including the 2025Q3-Q4 tail that
  # has thinner data coverage for some derived inputs.
  tar_target(estimation_end, "2025Q2"),

  # ---------------------------------------------------------------------------
  # 2. Data — sibyldata (or fixture in v0)
  # ---------------------------------------------------------------------------
  tar_target(raw_database,
    {
      base_db <- if (data_source == "fixture") {
        martin::read_fixture()
      } else {
        # Pull every implemented source. Transient failures (e.g. ABS
        # download glitches) emit warnings via update_data()'s
        # tolerate_failures path; the merge step below backfills any
        # series that didn't materialise from live data.
        panel <- sibyldata::update_data(sources = "all")
        live  <- sibyldata::to_martin_database(panel)
        sibyldata::merge_with_fallback(live, martin::read_fixture())
      }
      # Extend exogenous variables to the solve horizon end. Required
      # because some fixture-only series (RAIN, NHFA-style dummies)
      # stop at the fixture's 2019Q3 end and need to be carried forward
      # so SIMULATE has values across the full horizon. Carry-forward is
      # safe for the cases this hits (dummies at 0, anchored constants);
      # variables MARTIN solves endogenously aren't affected.
      sibyldata::extend_exogenous(base_db, end_quarter = horizon[2])
    }
  ),

  # The raw panel (tidy (series_id, source, date, value, vintage)) is
  # held separately from the bimets database so the monthly-indicator
  # bridge in step 3 can use un-aggregated monthly observations.
  # Re-runs update_data() (cached by sibyldata's parquet store), so
  # cold cost is ~10 min but only the first time per vintage.
  tar_target(raw_panel,
    if (data_source == "fixture") {
      NULL
    } else {
      sibyldata::update_data(sources = "all")
    }
  ),

  # Synthesise a ragged edge so nowcast has work to do; matches what
  # production looks like the moment after data refresh.
  tar_target(ragged_database, chop_for_ragged_edge(raw_database, n_chop = 2L)),

  # ---------------------------------------------------------------------------
  # 3. Nowcast — bridge the missing quarters using monthly indicators
  #    (`bridge_monthly`) where available, falling back to ARIMA otherwise.
  #    Bridge regressions:
  #      RC <- RT      (retail trade  -> household consumption)
  #      Y  <- HOURS   (hours worked  -> real GDP)
  #      LE <- LE_M    (LFS monthly LE -> quarterly LE; trivial bridge)
  # ---------------------------------------------------------------------------
  tar_target(monthly_indicators,
    if (is.null(raw_panel)) {
      list()  # fixture mode: no monthly indicators available
    } else {
      sibyldata::nowcast_monthly_indicators(
        raw  = raw_panel,
        vars = c("RT", "HOURS", "LE")
      )
    }
  ),

  tar_target(handover_forecasts,
    if (length(monthly_indicators) == 0L) {
      # Fixture mode or no monthly data: fall back to ARIMA.
      nowcast::nowcast_handover(ragged_database, h = 2L, method = "arima")
    } else {
      nowcast::nowcast_handover(
        ragged_database, h = 2L,
        method             = "bridge_monthly",
        bridge_indicators  = list(RC = "RT", Y = "HOURS", LE = "LE"),
        monthly_indicators = monthly_indicators
      )
    }
  ),

  tar_target(database_with_handover,
    nowcast::splice_handover(ragged_database, handover_forecasts)
  ),

  # ---------------------------------------------------------------------------
  # 4. MARTIN baseline solve — no add-factors
  # ---------------------------------------------------------------------------
  tar_target(baseline,
    martin::solve_martin(
      database       = database_with_handover,
      adjustments    = NULL,
      horizon        = horizon,
      coefficients   = if (is.null(estimation_end)) "frozen" else "reestimated",
      estimation_end = estimation_end,
      scenario       = "baseline"
    )
  ),

  # ---------------------------------------------------------------------------
  # 4b. Sensitivity matrix — pre-compute the realised propagation of a
  #     standardized unit shock on each adjustable equation, so the LLM
  #     can reason about magnitudes from observed numbers rather than
  #     guesses. Cached as a long tibble; only re-builds when database /
  #     horizon / estimation_end change. ~30s build on 56 equations.
  # ---------------------------------------------------------------------------
  tar_target(sensitivity_matrix,
    martin::sensitivity_matrix(
      database        = database_with_handover,
      baseline        = baseline,
      horizon         = horizon,
      estimation_end  = estimation_end,
      shock_quarters  = 4L,
      measure_offsets = c(1L, 4L, 8L, 16L),
      progress        = FALSE
    )
  ),

  # ---------------------------------------------------------------------------
  # 5. Judgement — narrative -> add-factor proposals, with iterative
  #    refinement against the round-trip audit. The orchestrator
  #    `propose_with_refinement()` runs:
  #      propose -> solve -> describe -> audit
  #      -> if audit disagrees, refine (re-prompt LLM with audit feedback)
  #      -> repeat up to max_iters times.
  #    The sensitivity_matrix is threaded into the propose + refine prompts
  #    so the LLM can pick AF magnitudes from observed propagation rather
  #    than guessing.
  #    ANTHROPIC_API_KEY absent => empty adjustment list (degraded but
  #    complete pipeline run).
  # ---------------------------------------------------------------------------
  tar_target(refined_round,
    if (nzchar(Sys.getenv("ANTHROPIC_API_KEY"))) {
      solve_fn <- function(adj) {
        martin::solve_martin(
          database       = database_with_handover,
          adjustments    = adj,
          horizon        = horizon,
          coefficients   = if (is.null(estimation_end)) "frozen"
                           else "reestimated",
          estimation_end = estimation_end,
          scenario       = "refinement-iter"
        )
      }
      judgement::propose_with_refinement(
        narrative          = narrative,
        baseline           = baseline,
        solve_fn           = solve_fn,
        max_iters          = 3L,
        round_id           = round_id,
        sensitivity_matrix = sensitivity_matrix,
        model              = "claude-haiku-4-5",
        # Sonnet 4.6 is more decisive on the token-heavy propose/refine
        # step (catalogue + sensitivity matrix in-context); describe and
        # audit stay on Haiku because they're cheap simple-text tasks.
        model_propose      = "claude-sonnet-4-6"
      )
    } else {
      message("[targets] ANTHROPIC_API_KEY not set; ",
              "skipping LLM refinement loop.")
      list(adjustments = judgement::adjustment_list(),
           projection = NULL, description = NULL,
           audit = NULL, history = list())
    }
  ),

  tar_target(proposed_adjustments, refined_round$adjustments),

  tar_target(refinement_history, refined_round$history),

  # ---------------------------------------------------------------------------
  # 6. Human-in-the-loop approval. Non-interactive by default for
  # unattended runs. Set `interactive = TRUE` in this target for a real
  # round to block on human review.
  # ---------------------------------------------------------------------------
  tar_target(approved_adjustments,
    judgement::review_and_approve(proposed_adjustments, interactive = FALSE)
  ),

  # ---------------------------------------------------------------------------
  # 7. MARTIN solve with approved adjustments
  # ---------------------------------------------------------------------------
  tar_target(projection,
    martin::solve_martin(
      database       = database_with_handover,
      adjustments    = approved_adjustments,
      horizon        = horizon,
      coefficients   = if (is.null(estimation_end)) "frozen" else "reestimated",
      estimation_end = estimation_end,
      scenario       = "with_adjustments"
    )
  ),

  # ---------------------------------------------------------------------------
  # 8. Judgement — describe the projection, round-trip check
  # ---------------------------------------------------------------------------
  tar_target(projection_description,
    if (nzchar(Sys.getenv("ANTHROPIC_API_KEY")) && length(approved_adjustments) > 0L) {
      judgement::describe_projection(
        projection = projection,
        baseline   = baseline,
        model      = "claude-haiku-4-5"
      )
    } else {
      paste(
        "(no description; either no adjustments were applied or",
        "ANTHROPIC_API_KEY is not set.)"
      )
    }
  ),

  tar_target(round_trip_check,
    if (nzchar(Sys.getenv("ANTHROPIC_API_KEY")) &&
        nzchar(projection_description) &&
        !startsWith(projection_description, "(no description")) {
      judgement::compare_narrative_to_description(
        narrative   = narrative,
        description = projection_description,
        model       = "claude-haiku-4-5"
      )
    } else {
      tibble::tibble(claim = character(),
                     status = character(),
                     note = character())
    }
  ),

  # ---------------------------------------------------------------------------
  # 9. Render the round report. Uses quarto::quarto_render() inside a
  # regular target so a missing Quarto CLI is a soft skip rather than a
  # pipeline failure (the rest of the targets are the substantive output;
  # the report is downstream presentation).
  # ---------------------------------------------------------------------------
  tar_target(round_report,
    {
      # Force re-build whenever any consumed target changes.
      force(list(round_id, narrative, baseline, projection,
                 projection_description, round_trip_check))
      qmd <- "reports/round.qmd"
      out <- "reports/round.html"
      qpath <- tryCatch(quarto::quarto_path(),
                        error = function(e) NULL)
      if (!requireNamespace("quarto", quietly = TRUE) ||
          is.null(qpath) || !nzchar(qpath)) {
        message("[targets] Quarto CLI not found; skipping report render. ",
                "Install via `brew install --cask quarto` and re-run.")
        return(list(path = out, rendered = FALSE))
      }
      quarto::quarto_render(qmd, quiet = TRUE)
      list(path = out, rendered = TRUE)
    }
  )
)
