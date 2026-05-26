# Tests for describe_projection() and compare_narrative_to_description().
# Unit tests use a fake chat; live tests skip without ANTHROPIC_API_KEY.

fake_chat_str <- function(structured = NULL, free = NULL) {
  list(
    set_system_prompt = function(p) invisible(NULL),
    chat_structured   = function(prompt, type) structured,
    chat              = function(prompt) free
  )
}

projection_fixture <- function(scenario, y_offset = 0, lur_offset = 0) {
  tibble::tibble(
    variable = rep(c("Y", "LUR", "PTM"), each = 4),
    quarter  = rep(c("2026Q1", "2026Q2", "2026Q3", "2026Q4"), 3),
    value    = c(100 + y_offset, 101 + y_offset,
                 102 + y_offset, 103 + y_offset,
                 4.2 + lur_offset, 4.2 + lur_offset,
                 4.1 + lur_offset, 4.1 + lur_offset,
                 0.6, 0.6, 0.6, 0.6),
    scenario = scenario
  )
}

test_that("describe_projection() returns the LLM's free-form prose", {
  prose <- "GDP is about 1 unit higher than baseline by 2026Q4 ..."
  chat <- fake_chat_str(free = prose)
  out <- describe_projection(
    projection = projection_fixture("scenario", y_offset = 1),
    baseline   = projection_fixture("baseline"),
    chat       = chat
  )
  expect_identical(out, prose)
})

test_that("describe_projection() warns when a narrative is supplied", {
  chat <- fake_chat_str(free = "ok")
  expect_warning(
    describe_projection(
      projection = projection_fixture("scenario"),
      baseline   = projection_fixture("baseline"),
      narrative  = "anything",
      chat       = chat
    ),
    "deprecated"
  )
})

test_that("describe_projection() works without a narrative", {
  chat <- fake_chat_str(free = "ok")
  out <- describe_projection(
    projection = projection_fixture("scenario"),
    baseline   = projection_fixture("baseline"),
    chat       = chat
  )
  expect_identical(out, "ok")
})

test_that("compare_narrative_to_description() parses claims into a tibble", {
  response <- list(
    overall_match = "partial",
    claims = list(
      list(claim  = "Growth is firmer",
           status = "agree",
           note   = "Y is +1 by 2026Q4"),
      list(claim  = "Unemployment rises",
           status = "disagree",
           note   = "LUR is unchanged")
    )
  )
  out <- compare_narrative_to_description(
    narrative   = "Growth firmer; unemployment rises slightly.",
    description = "GDP up 1 unit; LUR unchanged.",
    chat        = fake_chat_str(structured = response)
  )
  expect_s3_class(out, "tbl_df")
  expect_equal(nrow(out), 2L)
  expect_setequal(names(out), c("claim", "status", "note"))
  expect_equal(attr(out, "overall_match"), "partial")
  expect_equal(out$status, c("agree", "disagree"))
})

test_that("compare_narrative_to_description() rejects empty inputs", {
  expect_error(
    compare_narrative_to_description("", "x", chat = fake_chat_str()),
    "nzchar"
  )
  expect_error(
    compare_narrative_to_description("x", "", chat = fake_chat_str()),
    "nzchar"
  )
})

# ---- diagnose_audit() ----------------------------------------------------

test_that("diagnose_audit() classifies translation gaps vs model responses", {
  audit <- tibble::tibble(
    claim = c(
      "Employment growth has been persistently stronger than the model predicts",
      "Unemployment rate will fall by roughly 1.5 percentage points",
      "No change to our view on the cash-rate path",
      "No change to inflation outlook"
    ),
    status = c("agree", "disagree", "disagree", "disagree"),
    note   = c("desc covers it", "actual diff smaller",
               "NCR actually moved", "P actually moved")
  )
  attr(audit, "overall_match") <- "disagree"

  baseline <- tibble::tibble(
    variable = c("LUR", "NCR", "P"),
    quarter  = "2025Q4",
    value    = c(5.5, 1.5, 100),
    scenario = "baseline"
  )
  projection <- tibble::tibble(
    variable = c("LUR", "NCR", "P"),
    quarter  = "2025Q4",
    value    = c(5.0, 5.3, 100.2),  # LUR -0.5pp (vs -1.5pp target),
                                     # NCR +3.8pp, P +0.2%
    scenario = "scenario"
  )

  out <- diagnose_audit(audit, projection, baseline)
  expect_s3_class(out, "tbl_df")
  expect_equal(nrow(out), 4L)
  expect_setequal(
    names(out),
    c("claim", "status", "note", "variable", "diff_at_end",
      "category", "explanation")
  )
  # agree pass-through
  expect_equal(out$category[1], "agree")
  # LUR: quantified target, missed -> translation_gap
  expect_equal(out$variable[2], "LUR")
  expect_equal(out$category[2], "translation_gap")
  # NCR: "no change" but moved -> model_response
  expect_equal(out$variable[3], "NCR")
  expect_equal(out$category[3], "model_response")
  # P/inflation: "no change" but moved -> model_response
  expect_equal(out$variable[4], "P")
  expect_equal(out$category[4], "model_response")
  expect_equal(attr(out, "overall_match"), "disagree")
})

test_that("diagnose_audit() handles empty audit + unmatched variables", {
  empty <- tibble::tibble(claim = character(), status = character(),
                          note = character())
  baseline   <- tibble::tibble(variable = "Y", quarter = "2025Q4",
                                value = 100, scenario = "baseline")
  projection <- tibble::tibble(variable = "Y", quarter = "2025Q4",
                                value = 102, scenario = "scenario")
  expect_equal(nrow(diagnose_audit(empty, projection, baseline)), 0L)

  # Disagree with no recognizable variable -> unclassified.
  weird <- tibble::tibble(
    claim = "Something about widgets",
    status = "disagree", note = "?"
  )
  attr(weird, "overall_match") <- "disagree"
  out <- diagnose_audit(weird, projection, baseline)
  expect_equal(out$category, "unclassified")
  expect_true(is.na(out$variable))
})

test_that("diagnose_audit() detects variables via plain-English keywords", {
  audit <- tibble::tibble(
    claim = c("No change to the policy rate",
              "Headline inflation stays steady"),
    status = c("disagree", "disagree"),
    note   = c("rate moved", "prices moved")
  )
  attr(audit, "overall_match") <- "disagree"
  baseline <- tibble::tibble(
    variable = c("NCR", "P"), quarter = "2025Q4",
    value = c(2, 100), scenario = "baseline"
  )
  projection <- tibble::tibble(
    variable = c("NCR", "P"), quarter = "2025Q4",
    value = c(2.5, 100.3), scenario = "scenario"
  )
  out <- diagnose_audit(audit, projection, baseline)
  expect_equal(out$variable, c("NCR", "P"))
  expect_equal(out$category, c("model_response", "model_response"))
})

# Live tests
test_that("describe_projection() round-trips with live Anthropic Claude", {
  skip_if(Sys.getenv("ANTHROPIC_API_KEY") == "",
          "ANTHROPIC_API_KEY not set")
  skip_on_cran()
  skip_if_offline()

  out <- describe_projection(
    projection = projection_fixture("scenario", y_offset = 2),
    baseline   = projection_fixture("baseline"),
    model      = "claude-haiku-4-5"
  )
  expect_type(out, "character")
  expect_gt(nchar(out), 50L)  # non-trivial paragraph
})

test_that("compare_narrative_to_description() works with live Anthropic", {
  skip_if(Sys.getenv("ANTHROPIC_API_KEY") == "",
          "ANTHROPIC_API_KEY not set")
  skip_on_cran()
  skip_if_offline()

  out <- compare_narrative_to_description(
    narrative   = "Growth firmer; unemployment rises.",
    description = "GDP is about 2 units higher than baseline by 2026Q4. Unemployment is unchanged.",
    model       = "claude-haiku-4-5"
  )
  expect_s3_class(out, "tbl_df")
  expect_true(nrow(out) >= 1L)
  expect_true(attr(out, "overall_match") %in% c("agree", "partial", "disagree"))
})
