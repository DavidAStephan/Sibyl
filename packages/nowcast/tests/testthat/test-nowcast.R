# nowcast_handover() + splice_handover() against the bundled MARTIN fixture.
#
# Strategy: chop the last 2 quarters off each handover variable, nowcast 2
# quarters ahead, splice back, and compare against the held-out actuals.
#
# The bar isn't "forecast accuracy" (impossible to guarantee with auto-ARIMA
# on whatever data lands in the test) but "did the pipeline run, produce
# the expected shape, and recover values in the right order of magnitude".

# Build a small synthetic database (3 variables, 80 quarters) so the tests
# don't depend on martin being installed. Real fixture coverage comes from
# the regression test in martin/, which solves the model end-to-end.
synth_database <- function(n = 80, start = c(2000, 1)) {
  set.seed(42)
  trend <- seq_len(n)
  walk  <- cumsum(stats::rnorm(n, sd = 0.5))
  list(
    Y     = bimets::TIMESERIES(100 + 0.5 * trend + walk,
                               START = start, FREQ = 4),
    LUR   = bimets::TIMESERIES(5 + 0.3 * sin(trend / 4) +
                                 cumsum(stats::rnorm(n, sd = 0.1)),
                               START = start, FREQ = 4),
    PTM   = bimets::TIMESERIES(0.6 + 0.02 * stats::rnorm(n),
                               START = start, FREQ = 4)
  )
}

test_that("nowcast_handover() returns the canonical shape", {
  db <- synth_database()
  out <- nowcast_handover(db, h = 2, method = "naive",
                          variables = c("Y", "LUR"))
  expect_s3_class(out, "tbl_df")
  expect_setequal(
    names(out),
    c("variable", "quarter", "central", "lower", "upper", "method")
  )
  expect_equal(nrow(out), 4L)  # 2 vars × 2 quarters
  expect_setequal(unique(out$variable), c("Y", "LUR"))
  expect_true(all(out$method == "naive"))
  expect_true(all(out$lower <= out$central))
  expect_true(all(out$central <= out$upper))
})

test_that("nowcast_handover() defaults to handover_variables() ∩ database", {
  # Only Y is in both the synth db and handover_variables() (LUR + PTM too)
  db <- synth_database()
  out <- nowcast_handover(db, h = 1, method = "naive")
  expect_setequal(unique(out$variable), c("Y", "LUR", "PTM"))
})

test_that("nowcast_handover() rejects too-short series", {
  short <- list(Y = bimets::TIMESERIES(1:5, START = c(2020, 1), FREQ = 4))
  expect_error(
    nowcast_handover(short, h = 2, method = "naive", variables = "Y"),
    "fewer than 8 observations"
  )
})

test_that("nowcast_handover() rejects missing handover variables", {
  db <- synth_database()
  expect_error(
    nowcast_handover(db, variables = c("Y", "NOT_THERE")),
    "missing handover variables"
  )
})

test_that("naive nowcast recovers the last observed value", {
  db <- synth_database()
  last_y <- as.numeric(db$Y)[length(as.numeric(db$Y))]
  out <- nowcast_handover(db, h = 2, method = "naive", variables = "Y")
  # Naive forecast is constant at the last observation
  expect_equal(out$central, c(last_y, last_y))
})

test_that("ARIMA nowcast on synthetic Y is in the right ballpark", {
  db <- synth_database()
  out <- nowcast_handover(db, h = 2, method = "arima", variables = "Y")
  # Y is roughly 100 + 0.5 * t around quarter 80; central forecast should be
  # in the same neighbourhood, not three orders of magnitude off.
  expect_true(all(out$central > 100 & out$central < 200))
})

test_that("splice_handover() writes central values into the database", {
  db <- synth_database()
  out <- nowcast_handover(db, h = 2, method = "naive",
                          variables = c("Y", "LUR"))
  spliced <- splice_handover(db, out)

  # Database extended by 2 quarters
  expect_equal(length(as.numeric(spliced$Y)),
               length(as.numeric(db$Y)) + 2L)
  # New cells equal the central forecast
  tail_y <- tail(as.numeric(spliced$Y), 2)
  expected <- out$central[out$variable == "Y"]
  expect_equal(tail_y, expected)
})

test_that("splice_handover() rejects forecasts for unknown variables", {
  db <- synth_database()
  bad <- tibble::tibble(
    variable = "NONEXISTENT",
    quarter  = tsibble::make_yearquarter(2020, 1),
    central  = 1.0,
    lower    = 0.5,
    upper    = 1.5,
    method   = "naive"
  )
  expect_error(splice_handover(db, bad), "no series for")
})

test_that("splice_handover() rejects malformed handover", {
  db <- synth_database()
  expect_error(splice_handover(db, tibble::tibble(variable = "Y")),
               "missing required columns")
})

# Held-out evaluation against the bundled MARTIN fixture. This is the
# closest we get to "did the pipeline really work" in nowcast — chop, fit,
# forecast, compare.
test_that("nowcast recovers held-out actuals to within a wide tolerance", {
  skip_if_not_installed("martin")
  skip_if_not_installed("readxl")

  fixture <- martin::martin_data_fixture()
  skip_if_not(file.exists(fixture), "fixture missing")

  db <- martin::read_fixture()

  # Common handover vars that are present in the fixture
  vars <- intersect(handover_variables(), names(db))
  expect_true(length(vars) >= 10L, info = "fixture should cover most handover vars")

  # Chop the last 2 quarters off each handover variable and remember them
  held_out <- list()
  truncated_db <- db
  for (v in vars) {
    full <- as.numeric(db[[v]])
    n <- length(full)
    if (n < 12L) next
    held_out[[v]] <- full[(n - 1):n]
    # Truncate by reconstructing the ts
    start <- stats::tsp(db[[v]])[1]
    yr <- floor(start + 1e-9)
    q  <- round((start - yr) * 4 + 1)
    truncated_db[[v]] <- bimets::TIMESERIES(full[1:(n - 2)],
                                            START = c(yr, q), FREQ = 4)
  }

  vars <- names(held_out)
  expect_true(length(vars) >= 10L)

  out <- nowcast_handover(truncated_db, h = 2, method = "naive",
                          variables = vars)

  # Compare central forecasts vs held-out actuals. Naive forecast = last
  # observed value; for variables that drift, the error can be large in
  # absolute terms. Use percentage error with a *very* loose 30% threshold
  # and require at least 60% of variables to pass — this is a smoke test,
  # not a forecast-accuracy benchmark.
  hits <- vapply(vars, function(v) {
    actual <- held_out[[v]]
    forecast <- out$central[out$variable == v]
    rel_err <- abs(forecast - actual) / pmax(abs(actual), 1e-6)
    all(rel_err < 0.30)
  }, logical(1))
  pass_rate <- mean(hits)
  expect_gt(pass_rate, 0.60,
            label = sprintf("naive recovery pass rate (%.0f%%)",
                            pass_rate * 100))
})

test_that("bridge method returns the canonical shape for several variables", {
  skip_if_not_installed("martin")
  db <- martin::read_fixture()
  out <- nowcast_handover(db, h = 2, method = "bridge",
                          variables = c("RC", "NCR", "PTM"))
  expect_setequal(names(out),
                  c("variable", "quarter", "central", "lower", "upper",
                    "method"))
  expect_equal(nrow(out), 6L)  # 3 vars * 2 horizons
  expect_true(all(is.finite(out$central)))
  expect_true(all(out$method == "bridge"))
})

# --- bridge_monthly tests --------------------------------------------------

# Build a synthetic monthly indicator and a quarterly target with a known
# linear relationship: target = 2 * indicator_quarterly + noise.
make_synthetic_bridge <- function() {
  n_months <- 120L
  set.seed(42)
  ind_m <- 50 + cumsum(stats::rnorm(n_months, mean = 0.1, sd = 0.5))
  ind_ts <- bimets::TIMESERIES(ind_m, START = c(2010, 1), FREQ = 12)
  # Quarterly aggregation: mean of 3 monthly values
  ind_q <- sapply(seq.int(1L, n_months, by = 3L),
                  function(i) mean(ind_m[i:(i + 2)]))
  tgt_q <- 2 * ind_q + stats::rnorm(length(ind_q), 0, 0.3)
  tgt_ts <- bimets::TIMESERIES(tgt_q, START = c(2010, 1), FREQ = 4)
  list(target = tgt_ts, indicator = ind_ts)
}

test_that("bridge_monthly recovers a known linear relationship", {
  s <- make_synthetic_bridge()
  out <- nowcast_handover(
    database  = list(Y = s$target),
    h         = 2,
    method    = "bridge_monthly",
    variables = "Y",
    bridge_indicators  = list(Y = "HOURS"),
    monthly_indicators = list(HOURS = s$indicator)
  )
  expect_setequal(names(out),
                  c("variable", "quarter", "central", "lower", "upper",
                    "method"))
  expect_equal(nrow(out), 2L)
  # Predictions should be ~ 2 * (recent indicator mean)
  ind_recent <- mean(tail(as.numeric(s$indicator), 6))
  expect_lt(abs(out$central[1] - 2 * ind_recent), 1.0,
            label = "bridge_monthly prediction within 1.0 of 2*indicator")
  expect_true(all(out$method == "bridge_monthly[HOURS]"))
})

test_that("bridge_monthly falls back to ARIMA when indicator missing", {
  s <- make_synthetic_bridge()
  out <- nowcast_handover(
    database  = list(Y = s$target),
    h         = 2,
    method    = "bridge_monthly",
    variables = "Y",
    bridge_indicators  = list(Y = "NONEXISTENT"),
    monthly_indicators = list(HOURS = s$indicator)  # no NONEXISTENT key
  )
  expect_equal(nrow(out), 2L)
  expect_true(all(out$method == "arima"))
})

test_that("bridge_monthly errors when bridge_indicators or monthly_indicators missing", {
  s <- make_synthetic_bridge()
  expect_error(
    nowcast_handover(
      database = list(Y = s$target), h = 2,
      method = "bridge_monthly", variables = "Y"
    ),
    "bridge_indicators"
  )
})
