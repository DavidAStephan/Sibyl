#' Propose add-factor adjustments from a narrative
#'
#' Calls an LLM (via `ellmer`) with structured output to translate a
#' free-text narrative into a list of [adjustment()] proposals. The LLM is
#' given the [martin::equation_catalogue()] as its menu, the baseline
#' projection so it knows the counterfactual, and (optionally) historical
#' add-factors as in-context examples.
#'
#' The LLM does not forecast. It only proposes which equations to adjust,
#' how much, over what horizon, and why — all grounded in the narrative.
#' Every adjustment is validated against the catalogue before it's returned.
#'
#' @param narrative Character. The forecaster's narrative for this round.
#' @param baseline A baseline projection tibble from
#'   [martin::solve_martin()]. Used to give the LLM the counterfactual it's
#'   nudging.
#' @param round_id Character. Round identifier; propagated to every
#'   proposed adjustment.
#' @param owner   Character. Defaults to `"llm"`.
#' @param historical_afs A tibble of past adjustments (optional). Currently
#'   summarised as a text block appended to the user message; future
#'   versions may serialise more deliberately.
#' @param model Character. Anthropic model identifier passed to
#'   `ellmer::chat_anthropic()`. Defaults to `"claude-opus-4-7"`.
#' @param chat An `ellmer::Chat` object. If supplied, the function uses it
#'   directly (useful for testing with a mock chat). Otherwise a fresh
#'   `chat_anthropic()` is created.
#'
#' @return A [judgement::adjustment_list()].
#' @export
propose_adjustments <- function(narrative,
                                baseline       = NULL,
                                round_id       = NA_character_,
                                owner          = "llm",
                                historical_afs = NULL,
                                model          = "claude-opus-4-7",
                                chat           = NULL) {
  stopifnot(
    is.character(narrative), length(narrative) == 1L, nzchar(narrative)
  )

  prompt <- paste(
    "Forecast-round narrative:",
    "",
    narrative,
    "",
    "Baseline projection (headline aggregates):",
    "",
    baseline_summary_text(baseline),
    if (!is.null(historical_afs)) "" else NULL,
    if (!is.null(historical_afs)) "Historical add-factors (for calibration):" else NULL,
    if (!is.null(historical_afs)) format_historical_afs(historical_afs) else NULL,
    "",
    paste(
      "Return a structured proposal. Use an empty adjustments array if the",
      "narrative doesn't justify any specific quantitative changes."
    ),
    sep = "\n"
  )

  chat <- get_chat(chat, system_prompt = system_prompt_propose(),
                   model = model)
  result <- chat$chat_structured(prompt, type = proposal_schema())

  if (is.null(result$adjustments) ||
      (is.data.frame(result$adjustments) && nrow(result$adjustments) == 0L) ||
      (!is.data.frame(result$adjustments) &&
       length(result$adjustments) == 0L)) {
    return(adjustment_list())
  }

  # ellmer normalizes `type_array(items = type_object(...))` to a tibble
  # rather than a list-of-lists. Convert each row to a named list so
  # parse_proposal_to_adjustment() can treat it uniformly.
  proposals <- if (is.data.frame(result$adjustments)) {
    lapply(seq_len(nrow(result$adjustments)), function(i) {
      row <- as.list(result$adjustments[i, , drop = FALSE])
      # list-columns come back wrapped (e.g. `values` is a list of length 1
      # containing the actual numeric vector); unwrap.
      lapply(row, function(x) if (is.list(x) && length(x) == 1L) x[[1]] else x)
    })
  } else {
    result$adjustments
  }

  parsed <- lapply(proposals, function(p) {
    parse_proposal_to_adjustment(p, round_id = round_id, owner = owner,
                                 source = "llm")
  })
  do.call(adjustment_list, parsed)
}

format_historical_afs <- function(historical_afs) {
  if (!is.data.frame(historical_afs) || nrow(historical_afs) == 0L) {
    return("(none)")
  }
  required <- c("equation", "value", "rationale")
  if (!all(required %in% names(historical_afs))) {
    return("(unrecognised shape; expected columns include equation, value, rationale)")
  }
  rows <- vapply(seq_len(nrow(historical_afs)), function(i) {
    r <- historical_afs[i, ]
    sprintf("- %s: value=%s, rationale=%s",
            r$equation, format(r$value), r$rationale)
  }, character(1))
  paste(rows, collapse = "\n")
}

#' Human-in-the-loop approval step
#'
#' Renders a proposed [adjustment_list()] as a tibble for human review. In
#' interactive mode, writes the table to a CSV path and blocks until the
#' user signs off; in non-interactive mode (or with `interactive = FALSE`),
#' returns the proposed list unchanged with a one-time message.
#'
#' The CSV round-trips through [as_tibble_adjustments()] (write) and a
#' validating reader (read). Edits to `value`, `rationale`, `tail`,
#' `confidence`, and `horizon` are honoured; the row order is preserved.
#' Deleting a row drops that adjustment.
#'
#' @param proposed An `adjustment_list`.
#' @param interactive Logical. Set `FALSE` to bypass the human gate (e.g. in
#'   tests or unattended pipelines).
#' @param csv_path Path to write the review CSV. Defaults to a tempfile.
#' @return An `adjustment_list` containing only the approved subset.
#' @export
review_and_approve <- function(proposed,
                               interactive = base::interactive(),
                               csv_path    = NULL) {
  if (!inherits(proposed, "adjustment_list")) {
    stop("`proposed` must be an adjustment_list.", call. = FALSE)
  }
  if (length(proposed) == 0L) {
    return(proposed)
  }

  if (!isTRUE(interactive)) {
    message("review_and_approve: non-interactive mode; ",
            "returning proposed adjustments unchanged.")
    return(proposed)
  }

  if (is.null(csv_path)) {
    csv_path <- tempfile("sibyl-review-", fileext = ".csv")
  }

  # Write proposals
  tbl <- as_tibble_adjustments(proposed)
  utils::write.csv(tbl, csv_path, row.names = FALSE)
  cat("\n--- SIBYL review gate ----------------------------------------\n")
  cat("Proposed adjustments written to:\n  ", csv_path, "\n", sep = "")
  cat("Edit values / rationales / horizon, delete rows you reject,\n")
  cat("save, then press Enter to continue.\n")
  readline(prompt = "Press Enter when ready: ")

  # Re-read and reconstruct adjustments
  edited <- utils::read.csv(csv_path, stringsAsFactors = FALSE)
  reconstruct_adjustments(edited, original = proposed)
}

# Reconstruct an adjustment_list from an edited review CSV. Groups rows by
# (equation, rationale) to recover horizon vectors; preserves metadata that
# isn't user-editable (round_id, owner, source) from the original proposals.
reconstruct_adjustments <- function(edited, original) {
  required <- c("equation", "quarter", "value", "rationale",
                "tail", "confidence")
  missing <- setdiff(required, names(edited))
  if (length(missing)) {
    stop("Edited CSV is missing columns: ", paste(missing, collapse = ", "),
         call. = FALSE)
  }
  if (nrow(edited) == 0L) {
    return(adjustment_list())
  }
  # Look-up of original metadata by (equation, rationale)
  meta_lookup <- list()
  for (a in original) {
    key <- paste(a$equation, a$rationale, sep = "||")
    meta_lookup[[key]] <- a
  }

  edited$.group_key <- paste(edited$equation, edited$rationale, sep = "||")
  groups <- split(edited, edited$.group_key)

  result <- lapply(groups, function(g) {
    g <- g[order(g$quarter), , drop = FALSE]
    key <- g$.group_key[1]
    base_meta <- meta_lookup[[key]]
    adjustment(
      equation        = g$equation[1],
      horizon         = g$quarter,
      value           = as.numeric(g$value),
      rationale       = g$rationale[1],
      channel         = if (!is.null(base_meta)) base_meta$channel
                        else NA_character_,
      expected_effect = if (!is.null(base_meta)) base_meta$expected_effect
                        else NA_character_,
      confidence      = g$confidence[1],
      tail            = g$tail[1],
      owner           = if (!is.null(base_meta)) base_meta$owner
                        else NA_character_,
      round_id        = if (!is.null(base_meta)) base_meta$round_id
                        else NA_character_,
      source          = "human"
    )
  })
  do.call(adjustment_list, result)
}
