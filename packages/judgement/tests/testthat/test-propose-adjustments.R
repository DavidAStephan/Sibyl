# Tests for propose_adjustments(). The unit-test path injects a fake chat
# object that returns a fixed structured response — no network, no API key.
# A live test against Anthropic is provided too, skipped when ANTHROPIC_API_KEY
# isn't set.

# A minimal stand-in for an ellmer Chat object. propose_adjustments() only
# calls chat_structured(); set_system_prompt() is also called by get_chat()
# when chat is provided.
fake_chat <- function(structured_response) {
  structured <- structured_response
  list(
    set_system_prompt = function(p) invisible(NULL),
    chat_structured   = function(prompt, type) structured,
    chat              = function(prompt) {
      stop("fake_chat$chat() not configured for free-form calls.")
    }
  )
}

baseline_fixture <- function() {
  tibble::tibble(
    variable = rep(c("Y", "LUR", "PTM"), each = 4),
    quarter  = rep(c("2026Q1", "2026Q2", "2026Q3", "2026Q4"), 3),
    value    = c(100, 101, 102, 103, 4.2, 4.2, 4.1, 4.1, 0.6, 0.6, 0.6, 0.6),
    scenario = "baseline"
  )
}

test_that("propose_adjustments() parses a structured response", {
  skip_if_not_installed("martin")
  response <- list(
    reasoning = "Two adjustments motivated by migration / fiscal narrative",
    adjustments = list(
      list(
        equation        = "PTM",
        horizon_start   = "2026Q1",
        horizon_end     = "2026Q3",
        values          = c(0.10, 0.08, 0.05),
        rationale       = "Sustained services-price pressure from migration",
        channel         = "PTM -> P -> PC",
        expected_effect = "+0.15pp headline CPI by 2026Q4",
        confidence      = "medium",
        tail            = "decay_50"
      ),
      list(
        equation        = "NCR",
        horizon_start   = "2026Q2",
        horizon_end     = "2026Q4",
        values          = c(0.25, 0.25, 0.25),
        rationale       = "Faster rate normalisation than baseline",
        channel         = "NCR -> RCR -> RC",
        expected_effect = "Cash rate 25bp higher through end-2026",
        confidence      = "high",
        tail            = "carry"
      )
    )
  )
  al <- propose_adjustments(
    narrative = paste(
      "Services inflation stays elevated and the RBA hikes faster."
    ),
    baseline  = baseline_fixture(),
    round_id  = "test-round",
    chat      = fake_chat(response)
  )
  expect_s3_class(al, "adjustment_list")
  expect_length(al, 2L)
  expect_equal(al[[1]]$equation, "PTM")
  expect_equal(al[[1]]$horizon, c("2026Q1", "2026Q2", "2026Q3"))
  expect_equal(al[[1]]$source, "llm")
  expect_equal(al[[1]]$round_id, "test-round")
  expect_equal(al[[2]]$equation, "NCR")
  expect_equal(al[[2]]$tail, "carry")
})

test_that("propose_adjustments() returns empty list for empty response", {
  skip_if_not_installed("martin")
  response <- list(reasoning = "narrative is qualitative; no adjustments",
                   adjustments = list())
  al <- propose_adjustments(
    narrative = "Things look broadly on track.",
    baseline  = baseline_fixture(),
    chat      = fake_chat(response)
  )
  expect_s3_class(al, "adjustment_list")
  expect_length(al, 0L)
})

test_that("propose_adjustments() rejects empty narrative", {
  expect_error(
    propose_adjustments(narrative = "", baseline = baseline_fixture(),
                        chat = fake_chat(list(adjustments = list()))),
    "nzchar"
  )
})

test_that("propose_adjustments() surfaces parse errors with equation context", {
  skip_if_not_installed("martin")
  # values length mismatch on PTM
  response <- list(
    reasoning = "test",
    adjustments = list(list(
      equation        = "PTM",
      horizon_start   = "2026Q1",
      horizon_end     = "2026Q3",
      values          = c(0.10, 0.05),  # only 2, horizon is 3
      rationale       = "test",
      channel         = NA,
      expected_effect = NA,
      confidence      = "medium",
      tail            = "zero"
    ))
  )
  expect_error(
    propose_adjustments(
      narrative = "test", baseline = baseline_fixture(),
      chat = fake_chat(response)
    ),
    "PTM.*values has length 2"
  )
})

test_that("propose_adjustments() rejects non-adjustable equations", {
  skip_if_not_installed("martin")
  response <- list(
    reasoning = "test",
    adjustments = list(list(
      equation        = "Y",                       # identity -- not adjustable
      horizon_start   = "2026Q1",
      horizon_end     = "2026Q1",
      values          = c(1.0),
      rationale       = "test",
      channel         = NA,
      expected_effect = NA,
      confidence      = "medium",
      tail            = "zero"
    ))
  )
  expect_error(
    propose_adjustments(
      narrative = "test", baseline = baseline_fixture(),
      chat = fake_chat(response)
    ),
    "not adjustable"
  )
})

test_that("review_and_approve() bypasses the gate in non-interactive mode", {
  skip_if_not_installed("martin")
  a <- adjustment(
    equation = "PTM", horizon = c("2026Q1", "2026Q2"),
    value = c(0.1, 0.05), rationale = "test", tail = "zero",
    confidence = "medium", source = "llm"
  )
  al <- adjustment_list(a)
  expect_message(
    review_and_approve(al, interactive = FALSE),
    "non-interactive"
  )
  out <- suppressMessages(review_and_approve(al, interactive = FALSE))
  expect_identical(out, al)
})

test_that("review_and_approve() returns empty list when given empty list", {
  out <- review_and_approve(adjustment_list(), interactive = TRUE)
  expect_length(out, 0L)
})

# Live test: round-trips a real narrative through Anthropic Claude. Skipped
# when ANTHROPIC_API_KEY isn't set; expensive otherwise. The bar is "the
# pipeline runs and returns at least one valid adjustment on a narrative
# that obviously implies one", not "the LLM picks the best adjustment".
test_that("propose_adjustments() round-trips with live Anthropic Claude", {
  skip_if(Sys.getenv("ANTHROPIC_API_KEY") == "",
          "ANTHROPIC_API_KEY not set")
  skip_on_cran()
  skip_if_not_installed("martin")
  skip_if_offline()

  al <- propose_adjustments(
    narrative = paste(
      "Services inflation has been persistently sticky in our latest data.",
      "We think trimmed-mean inflation stays roughly 0.1pp higher than",
      "baseline through 2026Q3, fading thereafter as labour-market slack",
      "opens up. No change to our view on the cash-rate path."
    ),
    baseline  = baseline_fixture(),
    round_id  = "live-test",
    model     = "claude-haiku-4-5"  # cheaper for tests
  )
  expect_s3_class(al, "adjustment_list")
  expect_gte(length(al), 1L)
  # Should propose a PTM adjustment given the narrative explicitly names it
  expect_true(any(vapply(al, function(a) a$equation == "PTM",
                         logical(1))),
              info = "expected at least one PTM adjustment for this narrative")
})
