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

test_that("primary wins when it has at least as much history as fallback", {
  primary  <- list(X = ts_q(seq_len(10), 2010))
  fallback <- list(X = ts_q(seq_len(8), 2010))
  out <- merge_with_fallback(primary, fallback)
  expect_equal(length(as.numeric(out$X)), 10L)
  expect_equal(as.numeric(out$X), seq_len(10))
})

test_that("fallback wins when primary is shorter", {
  primary  <- list(X = ts_q(seq_len(4), 2018))
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
