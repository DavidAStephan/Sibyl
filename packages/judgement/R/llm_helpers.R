# Helpers that build prompts and parse structured-output responses from an
# LLM. The three LLM-facing functions (propose_adjustments,
# describe_projection, compare_narrative_to_description) all use the same
# primitives, so we keep them in one place.
#
# Schemas are constructed via ellmer's type_*() helpers; LLM responses come
# back as named lists which we then validate and convert to SIBYL types.

# ---- Schemas --------------------------------------------------------------

# Schema for one proposed adjustment. Mirrors the adjustment() S3 fields but
# uses horizon_start/horizon_end+length instead of an enumerated horizon
# vector, since enumerated quarter strings are awkward for the LLM to
# reliably produce.
proposal_item_schema <- function() {
  ellmer::type_object(
    .description = paste(
      "A single proposed add-factor adjustment on one MARTIN equation",
      "over one contiguous horizon."
    ),
    equation = ellmer::type_string(
      "MARTIN equation code (e.g. 'PTM', 'RC', 'NCR'). Must be one of the codes flagged adjustable in the equation catalogue."
    ),
    horizon_start = ellmer::type_string(
      "First quarter of the adjustment horizon, in 'yyyyQq' format (e.g. '2026Q1')."
    ),
    horizon_end = ellmer::type_string(
      "Last quarter of the adjustment horizon, inclusive, in 'yyyyQq' format. Must be on or after horizon_start."
    ),
    values = ellmer::type_array(
      items = ellmer::type_number(),
      description = paste(
        "Per-quarter add-factor values, one per quarter from horizon_start",
        "to horizon_end inclusive. Same length as the horizon."
      )
    ),
    rationale = ellmer::type_string(
      "Non-empty plain-English explanation of why this adjustment is being proposed. Should be drawn directly from the narrative."
    ),
    channel = ellmer::type_string(
      "Downstream variables the adjustment is expected to move (e.g. 'PTM -> P -> PC'). Use the transmission_channel field from the equation catalogue when possible."
    ),
    expected_effect = ellmer::type_string(
      "Specific quantitative prediction of the impact (e.g. '+0.2pp CPI by 2027Q4')."
    ),
    confidence = ellmer::type_enum(
      c("high", "medium", "low"),
      description = "How confident the proposer is in the magnitude."
    ),
    tail = ellmer::type_enum(
      c("decay_50", "carry", "zero"),
      description = paste(
        "How beyond-horizon cells should be filled. decay_50 (default for",
        "shocks): geometric decay with sign flip, matching the EViews",
        "_a(-1)*-0.5 convention. carry: hold the last value forward. zero:",
        "truncate."
      )
    )
  )
}

# Top-level schema for propose_adjustments(). The LLM returns a reasoning
# string plus an array of proposals.
proposal_schema <- function() {
  ellmer::type_object(
    .description = "Set of add-factor adjustments proposed for one forecast round.",
    reasoning = ellmer::type_string(
      "Brief overall reasoning for the proposed set."
    ),
    adjustments = ellmer::type_array(
      items = proposal_item_schema(),
      description = paste(
        "List of proposed adjustments. Use an empty array if the narrative",
        "does not imply any specific quantitative adjustments."
      )
    )
  )
}

# Schema for compare_narrative_to_description(): a list of structured
# claim-by-claim comparisons.
comparison_schema <- function() {
  ellmer::type_object(
    .description = "Round-trip check between input narrative and projection description.",
    overall_match = ellmer::type_enum(
      c("agree", "partial", "disagree"),
      description = "Top-level agreement summary."
    ),
    claims = ellmer::type_array(
      items = ellmer::type_object(
        claim = ellmer::type_string("A discrete claim from the narrative."),
        status = ellmer::type_enum(
          c("agree", "disagree", "not_addressed"),
          description = "Whether the description supports the claim."
        ),
        note = ellmer::type_string("Short justification, citing values where useful.")
      ),
      description = "Per-claim verdicts."
    )
  )
}

# ---- Prompt construction --------------------------------------------------

# Build the system prompt for propose_adjustments(). Includes the equation
# catalogue (filtered to adjustable) and the SIBYL rules of engagement.
system_prompt_propose <- function() {
  cat <- catalogue_adjustable_text()
  paste(
    "You are SIBYL's adjustment proposer.",
    "",
    "Your job is to translate a forecaster's narrative into specific add-factor",
    "adjustments on MARTIN equations. You are NOT a forecaster. You only propose",
    "which equations to adjust, over what horizon, by how much, and why -- all",
    "grounded in the user's narrative.",
    "",
    "Rules of engagement:",
    "  1. You may only adjust equations flagged adjustable in the catalogue below.",
    "  2. Every adjustment MUST include a rationale lifted from the narrative.",
    "  3. CRITICAL — the add-factor value goes on the equation's RESIDUAL, in",
    "     the LHS's natural units. Read the `units` column carefully:",
    "       * units=log_diff: residual is in quarterly LOG CHANGE. Value 0.001",
    "         is +0.1pp on the quarterly inflation/growth rate, ≈ +0.4pp",
    "         annualised. NEVER set values > 0.01/quarter unless the narrative",
    "         calls out a crisis-level shock. A naive value of 0.1 means +10pp",
    "         per quarter, which compounds catastrophically.",
    "       * units=level: residual is in the variable's level units. For an",
    "         unemployment-rate equation (LUR), value -0.1 is -0.1pp/quarter",
    "         on LUR's first difference; over 20 quarters that's -2pp.",
    "       * units=percent: residual is in percentage points. NCR/N2R/N10R",
    "         residuals at value 0.25 are +25 basis points / quarter.",
    "  4. Calibrate magnitudes to the typical_af_sd field (already expressed in",
    "     the LHS's natural units). One standard deviation is a meaningful but",
    "     not extreme adjustment. Going beyond 2x typical_af_sd requires",
    "     explicit narrative justification.",
    "",
    "     Worked examples from prior SIBYL rounds (use as scale anchors — your",
    "     proposed values should produce comparable end-of-horizon effects):",
    "",
    "       Example A — sticky inflation, PTM (units=log_diff)",
    "         Narrative: trimmed-mean inflation ~0.1pp/qtr higher than baseline",
    "         AF: equation=PTM, values=0.001 repeated for 6 quarters, decay_50",
    "         Realised: price level +1.3% by end-horizon, real Y/RC/GNE -0.5%,",
    "                   NCR +1pp via endogenous Taylor Rule. Round-trip: agree.",
    "",
    "       Example B — structural NAIRU shift, TLUR (units=percent)",
    "         Narrative: structural shift lowers LUR by ~1.5pp by 2025Q4",
    "         AF: equation=TLUR, values=-0.075 repeated for 12 quarters, carry",
    "         Realised: LUR -0.29pp by 2025Q4 (NOT -1.5pp). Only ~30% of TLUR's",
    "                   level shift passes through to LUR within 12 quarters",
    "                   because LUR's Okun error-correction is slow (LUR_DUM",
    "                   coefficient = 0.025). Round-trip: partial — narrative",
    "                   said -1.5pp, audit flagged the magnitude undershoot.",
    "         LESSON: to hit a -1.5pp LUR target via TLUR, you need either a",
    "         larger value (~-0.25/quarter) or a longer horizon (~30 quarters).",
    "",
    "       Example C — direct cyclical labour gap, LUR (units=level)",
    "         Narrative: post-COVID structural tightening, LUR -1.6pp by 2024Q4",
    "         AF: equation=LUR, values=-0.08 repeated for 20 quarters, decay_50",
    "         Realised: LUR -1.6pp by 2024Q4 — closes the gap directly. LUR's",
    "                   residual is on TSDELTA(LUR), so -0.08/qtr cumulates to",
    "                   -1.6pp over 20 quarters. Round-trip: agree.",
    "         LESSON: adjusting LUR directly delivers the target faster than",
    "         going via TLUR; choose TLUR only when the narrative explicitly",
    "         frames the shift as structural/equilibrium.",
    "",
    "       Critical heuristic: AFs on trend / NAIRU / R-star equations pass",
    "       through to the corresponding cyclical variable only at ~25-40% of",
    "       their level shift within the typical projection window. If the",
    "       narrative quantifies the cyclical effect, prefer the cyclical",
    "       equation. If it frames the change as structural/equilibrium, the",
    "       trend equation is the right channel — but scale the AF up by ~3x",
    "       to compensate for the damping.",
    "",
    "  5. Adjustment LENGTH — `values` must have exactly horizon_end -",
    "     horizon_start + 1 quarters. Count carefully: 2025Q4 to 2027Q4 is 9",
    "     quarters (Q4 + 4 + 4), not 8 or 32. The parser will warn and",
    "     truncate/pad on mismatch but accurate counts produce better solves.",
    "  6. Use decay_50 as the default tail rule for shocks (the EViews",
    "     convention). Use carry for persistent regime changes, zero for",
    "     one-off announcements.",
    "  7. Prefer fewer, targeted adjustments over many small ones.",
    "  8. If the narrative is silent on quantitative changes, return an empty",
    "     adjustments array.",
    "",
    "MARTIN equation catalogue (adjustable equations only):",
    "",
    cat,
    sep = "\n"
  )
}

# Format the adjustable catalogue as a compact table-like text block. The LLM
# parses it more reliably as text-tables than as a CSV blob.
catalogue_adjustable_text <- function() {
  if (!requireNamespace("martin", quietly = TRUE)) {
    stop("`martin` package not available; equation catalogue unreadable.",
         call. = FALSE)
  }
  cat <- martin::equation_catalogue()
  cat <- cat[isTRUE_safe(cat$adjustable), , drop = FALSE]
  rows <- vapply(seq_len(nrow(cat)), function(i) {
    row <- cat[i, ]
    sprintf(
      "- %s (%s, %s): %s\n    units=%s, typical_af_sd=%s, channel=%s",
      row$code, row$sector, row$equation_type,
      row$plain_english, row$units,
      format(row$typical_af_sd, na.encode = TRUE),
      row$transmission_channel
    )
  }, character(1))
  paste(rows, collapse = "\n")
}

# Cast a logical-ish column to TRUE safely
isTRUE_safe <- function(x) !is.na(x) & as.logical(x)

# Format a baseline projection as a compact summary the LLM can scan. Only
# headline aggregates, at quarterly granularity over the projection horizon.
baseline_summary_text <- function(baseline,
                                  variables = c("Y", "RC", "GNE", "LUR",
                                                "PTM", "P", "NCR")) {
  if (is.null(baseline)) return("(no baseline provided)")
  stopifnot(all(c("variable", "quarter", "value") %in% names(baseline)))
  sub <- baseline[baseline$variable %in% variables, , drop = FALSE]
  if (nrow(sub) == 0L) return("(baseline has no headline variables)")

  rows <- split(sub, sub$variable)
  lines <- vapply(rows, function(r) {
    r <- r[order(r$quarter), ]
    if (nrow(r) > 12L) r <- r[seq.int(nrow(r) - 11L, nrow(r)), ]
    paste0(
      r$variable[1], ": ",
      paste(sprintf("%s=%.2f", r$quarter, r$value), collapse = ", ")
    )
  }, character(1))
  paste(lines, collapse = "\n")
}

# Convert a parsed LLM proposal (named list with `equation`, `horizon_start`,
# `horizon_end`, `values`, `rationale`, etc.) into a judgement::adjustment.
# Throws if the LLM produced something that doesn't validate; the caller is
# expected to catch and report.
parse_proposal_to_adjustment <- function(p,
                                          round_id  = NA_character_,
                                          owner     = NA_character_,
                                          source    = "llm") {
  if (!is.list(p)) stop("Proposal must be a named list.", call. = FALSE)
  required <- c("equation", "horizon_start", "horizon_end", "values",
                "rationale", "confidence", "tail")
  missing <- setdiff(required, names(p))
  if (length(missing)) {
    stop("LLM proposal is missing fields: ",
         paste(missing, collapse = ", "), call. = FALSE)
  }
  horizon <- quarter_seq(p$horizon_start, p$horizon_end)
  # LLMs miscount horizons by 1-3 quarters fairly routinely. Rather than
  # rejecting the whole proposal (and losing useful judgement), normalize
  # to the horizon length: truncate if values is too long, repeat the
  # last value if too short. The forecaster can correct in review.
  if (length(p$values) != length(horizon)) {
    warning(sprintf(
      "Proposal on %s: LLM returned %d values for %d-quarter horizon; %s.",
      p$equation, length(p$values), length(horizon),
      if (length(p$values) > length(horizon)) "truncating"
      else "padding with last value"),
      call. = FALSE)
    if (length(p$values) > length(horizon)) {
      p$values <- p$values[seq_len(length(horizon))]
    } else {
      n_pad <- length(horizon) - length(p$values)
      p$values <- c(p$values,
                    rep(p$values[length(p$values)], n_pad))
    }
  }
  adjustment(
    equation        = p$equation,
    horizon         = horizon,
    value           = as.numeric(p$values),
    rationale       = p$rationale,
    channel         = if (!is.null(p$channel)) p$channel else NA_character_,
    expected_effect = if (!is.null(p$expected_effect))
                        p$expected_effect else NA_character_,
    # ellmer's type_enum returns factors; adjustment() uses match.arg
    # which needs character.
    confidence      = as.character(p$confidence),
    tail            = as.character(p$tail),
    owner           = owner,
    round_id        = round_id,
    source          = source
  )
}

# Build a diff-from-baseline summary for describe_projection().
#
# For variables that are intrinsically rates (LUR, NCR, LPR, ...) the diff
# is in pp directly and percent-of-baseline would be a percent change of a
# percent, which is confusing -- the LLM has been observed to misread that
# as pp. So we emit pp for rate variables and (units + percent) for level
# variables.
.percent_rate_vars <- c("LUR", "TLUR", "NCR", "RBR", "LPR", "NMR", "PI_E")

# Short glossary for headline diff_text so the describer doesn't have to
# guess variable meanings from cryptic MARTIN symbols (NCR is the nominal
# cash rate, not "nominal cost of revenue", etc.).
.variable_glossary <- list(
  Y    = "Real GDP (chained $m)",
  RC   = "Real household consumption (chained $m)",
  GNE  = "Real gross national expenditure (chained $m)",
  LUR  = "Unemployment rate (%)",
  TLUR = "Trend unemployment / NAIRU (%)",
  PTM  = "Trimmed-mean CPI (index)",
  P    = "Headline CPI (index)",
  NCR  = "Nominal cash rate / policy rate (%)",
  RBR  = "Real cash rate (%)",
  NMR  = "Bank mortgage rate (%)",
  LPR  = "Labour participation rate (%)",
  PI_E = "Inflation expectations (% annualised)"
)

projection_diff_text <- function(projection,
                                  baseline,
                                  variables = c("Y", "RC", "GNE", "LUR",
                                                "PTM", "P", "NCR")) {
  stopifnot(
    all(c("variable", "quarter", "value") %in% names(projection)),
    all(c("variable", "quarter", "value") %in% names(baseline))
  )
  joined <- dplyr::inner_join(
    dplyr::select(projection, "variable", "quarter", scenario_value = "value"),
    dplyr::select(baseline,   "variable", "quarter", baseline_value = "value"),
    by = c("variable", "quarter")
  )
  joined <- joined[joined$variable %in% variables, , drop = FALSE]
  joined$diff_abs <- joined$scenario_value - joined$baseline_value
  joined$diff_pct <- joined$diff_abs / pmax(abs(joined$baseline_value), 1e-9) * 100

  lines <- vapply(split(joined, joined$variable), function(r) {
    r <- r[order(r$quarter), ]
    if (nrow(r) > 8L) r <- r[seq.int(nrow(r) - 7L, nrow(r)), ]
    v <- r$variable[1]
    is_rate <- v %in% .percent_rate_vars
    label <- .variable_glossary[[v]]
    head <- if (!is.null(label)) sprintf("%s [%s]", v, label) else v
    cells <- if (is_rate) {
      sprintf("%s diff=%+.2f pp (baseline=%.2f pp)",
              r$quarter, r$diff_abs, r$baseline_value)
    } else {
      sprintf("%s diff=%+.2f (%+.1f%%)",
              r$quarter, r$diff_abs, r$diff_pct)
    }
    paste0(head, ": ", paste(cells, collapse = ", "))
  }, character(1))
  paste(lines, collapse = "\n")
}

# Get an LLM chat object. Prefers explicit `chat` argument so tests can
# inject mocks; otherwise constructs a fresh ellmer chat. Anthropic by
# default since that's the SIBYL-recommended model and `ANTHROPIC_API_KEY`
# is what the .Renviron.example documents.
get_chat <- function(chat = NULL,
                     system_prompt = NULL,
                     model = "claude-opus-4-7") {
  if (!is.null(chat)) {
    if (!is.null(system_prompt)) chat$set_system_prompt(system_prompt)
    return(chat)
  }
  if (!requireNamespace("ellmer", quietly = TRUE)) {
    stop("ellmer is not installed.", call. = FALSE)
  }
  if (Sys.getenv("ANTHROPIC_API_KEY") == "") {
    stop("ANTHROPIC_API_KEY is not set. Add it to .Renviron.", call. = FALSE)
  }
  ellmer::chat_anthropic(system_prompt = system_prompt, model = model)
}
