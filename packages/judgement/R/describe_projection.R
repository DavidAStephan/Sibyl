#' Draft prose describing a projection relative to baseline
#'
#' Closes the round-trip loop: feed the solved projection back to the LLM
#' and let it write a description. If the description says different things
#' from the original narrative, the translation has failed somewhere — and
#' [compare_narrative_to_description()] surfaces that.
#'
#' Free-form prose (not structured), since the description is meant to be
#' human-readable. Includes a compact diff-from-baseline summary in the
#' user message so the LLM is grounded in the numbers.
#'
#' @param projection A projection tibble from [martin::solve_martin()].
#' @param baseline   The baseline projection (also from
#'   [martin::solve_martin()]) the new one is being compared to.
#' @param narrative  The narrative that produced the adjustments. Optional
#'   but recommended; including it lets the LLM mirror the narrative's
#'   framing.
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

  diff_text <- projection_diff_text(projection, baseline, variables = focus)

  user_msg <- paste(
    "Solved projection (differences from baseline on headline aggregates):",
    "",
    diff_text,
    "",
    if (!is.null(narrative)) {
      "The narrative that produced this projection:"
    } else {
      NULL
    },
    if (!is.null(narrative)) narrative else NULL,
    if (!is.null(narrative)) "" else NULL,
    "Draft a short, plain-English paragraph (3-6 sentences) describing how",
    "this projection differs from baseline. Mirror the framing of the",
    "narrative when reasonable; lead with the headline numbers; be specific",
    "about quarters and magnitudes; do not introduce claims not supported by",
    "the numbers shown.",
    sep = "\n"
  )

  sysprompt <- paste(
    "You are SIBYL's projection describer. Given a difference summary,",
    "draft a short readable paragraph that a forecaster could paste into a",
    "round report. Never invent numbers; always reference the diff summary",
    "you were given.",
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

  tbl <- tibble::tibble(
    claim  = vapply(result$claims, `[[`, character(1), "claim"),
    status = vapply(result$claims, `[[`, character(1), "status"),
    note   = vapply(result$claims, `[[`, character(1), "note")
  )
  attr(tbl, "overall_match") <- result$overall_match
  tbl
}
