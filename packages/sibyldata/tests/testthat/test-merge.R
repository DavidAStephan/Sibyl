# Tests for merge_with_fallback().

ts_q <- function(values, start_year, start_quarter = 1L) {
  bimets::TIMESERIES(values, START = c(start_year, start_quarter), FREQ = 4)
}

test_that("missing-in-primary variables are taken from fallback", {
  primary  <- list(A = ts_q(1:4, 2010))
  fallback <- list(A = ts_q(1:4, 2010), B = ts_q(10:13, 2010))
  out <- merge_with_fallback(primary, fallback)
  expect_setequal(names(out), c("A", "B"))
  expect_equal(as.numeric(out$B), 10:13)
})

test_that("missing-in-fallback variables are taken from primary", {
  primary  <- list(NEW = ts_q(5:8, 2010))
  fallback <- list(OLD = ts_q(1:4, 2010))
  out <- merge_with_fallback(primary, fallback)
  expect_setequal(names(out), c("OLD", "NEW"))
  expect_equal(as.numeric(out$NEW), 5:8)
})

test_that("primary wins when it covers fallback range and extends past", {
  # Both start 2010Q1; primary runs further at the end. Primary covers
  # fallback fully and adds quarters past fallback's end.
  primary  <- list(X = ts_q(seq_len(10), 2010))
  fallback <- list(X = ts_q(seq_len(8), 2010))
  out <- merge_with_fallback(primary, fallback)
  expect_equal(as.numeric(out$X), seq_len(10))
})

test_that("fallback wins when primary starts later (less historical depth)", {
  # Primary starts 2018, fallback starts 2010 — fallback covers more history.
  primary  <- list(X = ts_q(seq_len(4), 2018))
  fallback <- list(X = ts_q(seq_len(40), 2010))
  out <- merge_with_fallback(primary, fallback)
  expect_equal(length(as.numeric(out$X)), 40L)
})

test_that("fallback wins when primary ends earlier (less terminal coverage)", {
  # Both start 2010Q1 but primary stops at 2012, fallback continues to 2020.
  # MARTIN's TSRANGEs need the full data to estimate; fallback should win.
  primary  <- list(X = ts_q(seq_len(8), 2010))
  fallback <- list(X = ts_q(seq_len(40), 2010))
  out <- merge_with_fallback(primary, fallback)
  expect_equal(length(as.numeric(out$X)), 40L)
})

test_that("merge with empty primary returns the fallback unchanged", {
  fallback <- list(A = ts_q(1:4, 2010), B = ts_q(5:8, 2010))
  out <- merge_with_fallback(list(), fallback)
  expect_identical(out, fallback)
})

test_that("merge with empty fallback returns the primary", {
  primary <- list(A = ts_q(1:4, 2010))
  out <- merge_with_fallback(primary, list())
  expect_setequal(names(out), "A")
  expect_equal(as.numeric(out$A), 1:4)
})

test_that("primary wins over NA-padded fallback when its first non-NA is earlier", {
  # Fallback starts 2005 with all NA until 2012Q3, then 10 obs.
  # Primary starts 2010 with 20 obs — first non-NA at 2010Q1 vs
  # fallback's 2012Q3, so primary covers more historical depth.
  primary  <- list(X = ts_q(seq_len(20), 2010))
  fallback <- list(X = ts_q(c(rep(NA, 30), seq_len(10)), 2005))
  out <- merge_with_fallback(primary, fallback)
  expect_equal(as.numeric(out$X), seq_len(20))
})
