#' Draft prose describing a projection relative to baseline
#'
#' Closes the round-trip loop: feed the solved projection back to the LLM
#' and let it write a description. If the description says different things
#' from the original narrative, the translation has failed somewhere — and
#' [compare_narrative_to_description()] surfaces that.
#'
#' The describer is **deliberately blind to the input narrative.** It sees
#' only the numerical diff from baseline. If we fed it the narrative it
#' would naturally mirror that framing, which makes the round-trip audit
#' trivially satisfied even when the projection's numbers actually
#' contradict the narrative. The `narrative` argument is retained but
#' ignored (kept for API back-compat, with a one-time deprecation warning).
#'
#' Free-form prose (not structured), since the description is meant to be
#' human-readable. Includes a compact diff-from-baseline summary in the
#' user message so the LLM is grounded in the numbers.
#'
#' @param projection A projection tibble from [martin::solve_martin()].
#' @param baseline   The baseline projection (also from
#'   [martin::solve_martin()]) the new one is being compared to.
#' @param narrative  Deprecated and ignored — the describer is blind by
#'   design. See the description above.
#' @param focus A character vector of variables to emphasise. Defaults to
#'   the SMP-style headline aggregates.
#' @param model Character. The `ellmer` model identifier.
#' @param chat An `ellmer::Chat` object (for testing).
#'
#' @return A character string of prose.
#' @export
describe_projection <- function(projection,
                                baseline,
                                narrative = NULL,
                                focus = c("Y", "RC", "GNE", "LUR", "PTM",
                                          "P", "NCR"),
                                model = "claude-opus-4-7",
                                chat  = NULL) {
  stopifnot(is.data.frame(projection), is.data.frame(baseline))
  if (!is.null(narrative)) {
    warning("`narrative` is deprecated and ignored: the describer is blind ",
            "by design so the round-trip audit can be meaningful.",
            call. = FALSE)
  }

  diff_text <- projection_diff_text(projection, baseline, variables = focus)

  user_msg <- paste(
    "Solved projection (differences from baseline on headline aggregates):",
    "",
    diff_text,
    "",
    "Draft a short, plain-English paragraph (3-6 sentences) describing how",
    "this projection differs from baseline. Lead with the headline numbers;",
    "be specific about quarters and magnitudes; never report a number that",
    "isn't in the diff summary above.",
    sep = "\n"
  )

  sysprompt <- paste(
    "You are SIBYL's projection describer. Given a difference summary,",
    "draft a short readable paragraph that a forecaster could paste into a",
    "round report. Never invent numbers; always reference the diff summary",
    "you were given. You do NOT have access to the narrative that produced",
    "the projection - describe what the numbers say, not what you think the",
    "forecaster intended.",
    sep = " "
  )
  chat <- get_chat(chat, system_prompt = sysprompt, model = model)
  chat$chat(user_msg)
}

#' Round-trip check: does the LLM's description match the narrative?
#'
#' Asks the LLM (with structured output) to compare the input narrative
#' against the description of the solved projection, and return a
#' claim-by-claim verdict. If `overall_match != "agree"`, the round has a
#' translation gap worth flagging in the report.
#'
#' @param narrative   The original narrative.
#' @param description The projection description from [describe_projection()].
#' @param model Character. The `ellmer` model identifier.
#' @param chat An `ellmer::Chat` object (for testing).
#' @return A tibble of `(claim, status, note)` plus an `overall_match`
#'   attribute.
#' @export
compare_narrative_to_description <- function(narrative,
                                             description,
                                             model = "claude-opus-4-7",
                                             chat  = NULL) {
  stopifnot(
    is.character(narrative),   length(narrative)   == 1L, nzchar(narrative),
    is.character(description), length(description) == 1L, nzchar(description)
  )
  prompt <- paste(
    "Narrative (the forecaster's framing of this round):",
    "",
    narrative,
    "",
    "Projection description (what the model actually produced):",
    "",
    description,
    "",
    paste(
      "Identify discrete claims in the narrative and verdict each one",
      "against the description: agree, disagree, or not_addressed. Provide",
      "an overall_match label too."
    ),
    sep = "\n"
  )

  sysprompt <- paste(
    "You are SIBYL's round-trip auditor. Compare a forecaster's narrative",
    "against a description of the solved projection and flag any",
    "translation failures. Be a strict reader: a claim only counts as",
    "'agree' if the description supports it specifically.",
    sep = " "
  )
  chat <- get_chat(chat, system_prompt = sysprompt, model = model)
  result <- chat$chat_structured(prompt, type = comparison_schema())

  # ellmer normalizes `type_array(items = type_object(...))` to a tibble
  # rather than a list-of-lists. Handle both shapes.
  tbl <- if (is.data.frame(result$claims)) {
    tibble::tibble(
      claim  = as.character(result$claims$claim),
      status = as.character(result$claims$status),
      note   = as.character(result$claims$note)
    )
  } else if (length(result$claims) == 0L) {
    tibble::tibble(claim = character(),
                   status = character(),
                   note = character())
  } else {
    tibble::tibble(
      claim  = vapply(result$claims, `[[`, character(1), "claim"),
      status = vapply(result$claims, `[[`, character(1), "status"),
      note   = vapply(result$claims, `[[`, character(1), "note")
    )
  }
  attr(tbl, "overall_match") <- as.character(result$overall_match)
  tbl
}
