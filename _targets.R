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
      "Services inflation has been persistently sticky in our latest data.",
      "We think trimmed-mean inflation stays roughly 0.1 percentage points",
      "higher than baseline through 2018Q3, fading thereafter as labour-",
      "market slack opens up. No change to our view on the cash-rate path."
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

  # Synthesise a ragged edge so nowcast has work to do; matches what
  # production looks like the moment after data refresh.
  tar_target(ragged_database, chop_for_ragged_edge(raw_database, n_chop = 2L)),

  # ---------------------------------------------------------------------------
  # 3. Nowcast — bridge the missing quarters
  # ---------------------------------------------------------------------------
  tar_target(handover_forecasts,
    nowcast::nowcast_handover(ragged_database, h = 2L, method = "arima")
  ),

  tar_target(database_with_handover,
    nowcast::splice_handover(ragged_database, handover_forecasts)
  ),

  # ---------------------------------------------------------------------------
  # 4. MARTIN baseline solve — no add-factors
  # ---------------------------------------------------------------------------
  tar_target(baseline,
    martin::solve_martin(
      database    = database_with_handover,
      adjustments = NULL,
      horizon     = horizon,
      scenario    = "baseline"
    )
  ),

  # ---------------------------------------------------------------------------
  # 5. Judgement — narrative -> add-factor proposals
  # ANTHROPIC_API_KEY absent => empty adjustment list (degraded but
  # complete pipeline run).
  # ---------------------------------------------------------------------------
  tar_target(proposed_adjustments,
    if (nzchar(Sys.getenv("ANTHROPIC_API_KEY"))) {
      judgement::propose_adjustments(
        narrative = narrative,
        baseline  = baseline,
        round_id  = round_id,
        model     = "claude-haiku-4-5"
      )
    } else {
      message("[targets] ANTHROPIC_API_KEY not set; ",
              "proposing empty adjustment list.")
      judgement::adjustment_list()
    }
  ),

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
      database    = database_with_handover,
      adjustments = approved_adjustments,
      horizon     = horizon,
      scenario    = "with_adjustments"
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
        narrative  = narrative,
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
