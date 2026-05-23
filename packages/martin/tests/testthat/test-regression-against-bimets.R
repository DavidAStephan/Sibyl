# Regression test: martin::solve_martin() must produce the same projection
# as the canonical bimets pipeline from
# references/bimets-main/BIMETS_MARTIN_LOAD.R, given the bundled MARTINDATA
# fixture and no user adjustments.
#
# The reference is computed inline rather than loaded from a committed RDS:
# the bundled fixture is deterministic, so both pipelines should produce
# identical numbers in the same R session. The cost (one extra SIMULATE per
# test run) is modest and the alternative — committing a binary blob that
# can silently drift out of sync — is worse.

# Headline variables checked first. If these match, the bulk of the model
# is working; if not, the failure messages are immediately interpretable.
HEADLINE <- c("Y", "RC", "GNE", "LUR", "PTM", "NCR")

# Demo range from BIMETS_MARTIN_LOAD.R lines 124-127.
HORIZON  <- c("2010Q1", "2019Q3")

bimets_reference <- function(data, tsrange) {
  model <- load_martin(data, variant = "af", estimate = TRUE)
  ca <- lapply(model$behaviorals, function(b) b$residuals)
  ca <- ca[!vapply(ca, is.null, logical(1))]
  model <- bimets::SIMULATE(
    model,
    TSRANGE            = tsrange,
    ConstantAdjustment = ca,
    simConvergence     = 1e-6,
    simIterLimit       = 100
  )
  simulation_to_tibble(model, scenario = "bimets_reference")
}

test_that("solve_martin() with no adjustments matches the bimets reference", {
  skip_if_not_installed("bimets")
  skip_if_not(file.exists(martin_data_fixture()), "MARTINDATA fixture missing")

  data <- read_fixture()

  reference <- bimets_reference(data, c(2010, 1, 2019, 3))
  sibyl     <- solve_martin(
    database    = data,
    adjustments = NULL,
    horizon     = HORIZON,
    scenario    = "sibyl"
  )

  # Same variables present
  expect_setequal(unique(reference$variable), unique(sibyl$variable))

  # Per-variable numerical agreement on the headline aggregates
  for (var in HEADLINE) {
    ref_v <- dplyr::filter(reference, variable == var)
    sib_v <- dplyr::filter(sibyl,     variable == var)
    expect_equal(nrow(ref_v), nrow(sib_v),
                 info = paste("row count for", var))
    expect_equal(
      sib_v$value, ref_v$value,
      tolerance = 1e-8,
      info = paste("value column for", var)
    )
    # Quarters must line up too
    expect_equal(sib_v$quarter, ref_v$quarter,
                 info = paste("quarter alignment for", var))
  }
})

test_that("a single add-factor on NCR moves the solve away from baseline", {
  skip_if_not_installed("bimets")
  skip_if_not(file.exists(martin_data_fixture()), "MARTINDATA fixture missing")

  data <- read_fixture()

  baseline <- solve_martin(
    database = data, adjustments = NULL,
    horizon = HORIZON, scenario = "baseline"
  )

  # Replicate the demo from BIMETS_MARTIN_LOAD.R lines 133-149: bump NCR by
  # 1pp in 2010Q1 (and three small additional bumps to keep the path
  # smoothly higher). Wrap as a SIBYL adjustment.
  bump <- judgement::adjustment(
    equation       = "NCR",
    horizon        = c("2010Q1", "2010Q2", "2010Q3", "2010Q4"),
    value          = c(1.0, 0.341413, 0.427, 0.5137297),
    rationale      = "Replicate the BIMETS_MARTIN_LOAD.R demo NCR shock.",
    tail           = "zero",
    confidence     = "high",
    source         = "human",
    round_id       = "regression-test"
  )
  shocked <- solve_martin(
    database    = data,
    adjustments = judgement::adjustment_list(bump),
    horizon     = HORIZON,
    scenario    = "shocked"
  )

  base_ncr   <- dplyr::filter(baseline, variable == "NCR")$value
  shock_ncr  <- dplyr::filter(shocked,  variable == "NCR")$value
  expect_true(any(shock_ncr - base_ncr > 0.5),
              info = "NCR should be visibly higher in the shocked scenario")

  # GDP should be lower under the rate hike, at least somewhere in the path
  base_y  <- dplyr::filter(baseline, variable == "Y")$value
  shock_y <- dplyr::filter(shocked,  variable == "Y")$value
  expect_true(any(shock_y < base_y),
              info = "Y should be lower under a positive NCR shock")
})
