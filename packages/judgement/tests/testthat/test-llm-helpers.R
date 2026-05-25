# Tests for the prompt construction and parsing helpers. No LLM calls.

test_that("system_prompt_propose() embeds the adjustable catalogue", {
  skip_if_not_installed("martin")
  prompt <- judgement:::system_prompt_propose()
  expect_type(prompt, "character")
  expect_match(prompt, "SIBYL")
  # Spot-check that real equation codes show up
  for (code in c("PTM", "RC", "NCR", "IBN", "RTWI")) {
    expect_match(prompt, code, fixed = TRUE,
                 info = paste("missing", code))
  }
  # And that non-adjustable identities don't (Y, NY, GNE, X, M when identity)
  # Note: GNE is BEHAVIORAL in AF model but flagged not adjustable in
  # the catalogue (it's an identity-equivalent). Check Y which is a true
  # identity.
  expect_false(grepl("- Y \\(", prompt),
               info = "Y is an identity and shouldn't appear as adjustable")
})

test_that("catalogue_adjustable_text() formats each row consistently", {
  skip_if_not_installed("martin")
  text <- judgement:::catalogue_adjustable_text()
  lines <- strsplit(text, "\n", fixed = TRUE)[[1]]
  # Each adjustable equation produces 2 lines (header + indented metadata)
  starts <- grep("^- ", lines)
  expect_true(length(starts) > 30L,
              info = "expected at least 30 adjustable equations")
  # Every header line should have the (sector, equation_type) parenthetical
  for (i in starts[1:5]) {
    expect_match(lines[i], "\\([a-z_]+, [a-z_]+\\)")
  }
})

test_that("baseline_summary_text() handles NULL and empty cases", {
  expect_equal(baseline_summary_text(NULL), "(no baseline provided)")
  empty <- tibble::tibble(variable = character(), quarter = character(),
                          value = numeric())
  expect_equal(baseline_summary_text(empty),
               "(baseline has no headline variables)")
})

test_that("baseline_summary_text() trims to last 12 quarters per variable", {
  set.seed(1)
  many <- tibble::tibble(
    variable = "Y",
    quarter  = sprintf("%04dQ%d",
                       rep(2018:2024, each = 4),
                       rep(1:4, 7)),
    value    = stats::rnorm(28, 100, 5)
  )
  txt <- baseline_summary_text(many, variables = "Y")
  # Count comma-separated quarter=value pairs
  n_pairs <- length(strsplit(txt, ", ", fixed = TRUE)[[1]])
  expect_equal(n_pairs, 12L)
})

test_that("parse_proposal_to_adjustment() round-trips a valid proposal", {
  skip_if_not_installed("martin")
  p <- list(
    equation        = "PTM",
    horizon_start   = "2026Q1",
    horizon_end     = "2026Q3",
    values          = c(0.10, 0.08, 0.05),
    rationale       = "Sustained services-price pressure from migration",
    channel         = "PTM -> P -> PC",
    expected_effect = "+0.15pp headline CPI by 2026Q4",
    confidence      = "medium",
    tail            = "decay_50"
  )
  a <- judgement:::parse_proposal_to_adjustment(
    p, round_id = "test", owner = "llm"
  )
  expect_s3_class(a, "adjustment")
  expect_equal(a$equation, "PTM")
  expect_equal(a$horizon, c("2026Q1", "2026Q2", "2026Q3"))
  expect_equal(a$value, c(0.10, 0.08, 0.05))
  expect_equal(a$source, "llm")
})

test_that("parse_proposal_to_adjustment() warns on length mismatch and pads", {
  p <- list(
    equation = "PTM",
    horizon_start = "2026Q1", horizon_end = "2026Q3",
    values = c(0.10, 0.05),  # length 2, horizon length 3
    rationale = "test", confidence = "medium", tail = "zero"
  )
  expect_warning(
    a <- judgement:::parse_proposal_to_adjustment(p),
    "2 values for 3-quarter horizon"
  )
  expect_equal(a$value, c(0.10, 0.05, 0.05))  # padded with last
})

test_that("parse_proposal_to_adjustment() warns on length mismatch and truncates", {
  p <- list(
    equation = "PTM",
    horizon_start = "2026Q1", horizon_end = "2026Q3",
    values = c(0.10, 0.05, 0.03, 0.02),  # length 4, horizon length 3
    rationale = "test", confidence = "medium", tail = "zero"
  )
  expect_warning(
    a <- judgement:::parse_proposal_to_adjustment(p),
    "4 values for 3-quarter horizon"
  )
  expect_equal(a$value, c(0.10, 0.05, 0.03))  # truncated
})

test_that("parse_proposal_to_adjustment() errors on missing fields", {
  expect_error(
    judgement:::parse_proposal_to_adjustment(
      list(equation = "PTM")
    ),
    "missing fields"
  )
})

test_that("projection_diff_text() computes per-variable diff strings", {
  baseline <- tibble::tibble(
    variable = rep(c("Y", "LUR"), each = 3),
    quarter  = rep(c("2026Q1", "2026Q2", "2026Q3"), 2),
    value    = c(100, 101, 102, 4.5, 4.4, 4.3),
    scenario = "baseline"
  )
  projection <- baseline
  projection$value <- projection$value + c(rep(1.0, 3), rep(0.1, 3))
  txt <- projection_diff_text(projection, baseline, variables = c("Y", "LUR"))
  # Y is a level variable: emits absolute diff + percent change.
  expect_match(txt, "Y\\b.*diff=\\+1\\.00")
  # LUR is a rate variable: emits diff in pp (the "(-5.2%)" form would be
  # percent-change-of-a-percent, which the describer has misread as pp).
  expect_match(txt, "LUR\\b.*diff=\\+0\\.10 pp")
  # Both heads include the plain-English glossary label.
  expect_match(txt, "Y \\[Real GDP")
  expect_match(txt, "LUR \\[Unemployment rate")
})
