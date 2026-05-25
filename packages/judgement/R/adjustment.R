# The adjustment S3 class.
#
# An adjustment is the contract between four parties: a human narrating a
# judgement call, the LLM translating that narrative into specific
# perturbations of MARTIN equations, the bimets-shaped ConstantAdjustment list
# the model consumes, and the round-report prose. It carries enough metadata
# to flow through that whole pipeline.
#
# Tail behaviour codifies the EViews `_a = _a(-1) * -0.5` convention from
# references/MARTIN-master/Programs/solve_model.prg: decay_50 reproduces it,
# carry holds the last value forward, zero truncates.

#' Construct an adjustment
#'
#' An `adjustment` is a single judgemental perturbation of one MARTIN
#' equation over a horizon, with all the metadata required to flow through
#' SIBYL's pipeline (LLM proposal -> human review -> bimets solve -> report).
#'
#' @param equation Character. MARTIN equation code (e.g. `"PTM"`). Must match
#'   a row in [martin::equation_catalogue()] with `adjustable = TRUE`.
#' @param horizon  Character vector of quarters in `"yyyyQq"` form
#'   (e.g. `c("2026Q1", "2026Q2", "2026Q3")`).
#' @param value    Numeric vector the same length as `horizon` — the additive
#'   value applied to the equation's residual each period.
#' @param rationale Character. The "why" — typically lifted from the narrative
#'   the LLM read.
#' @param channel  Character. The chain of downstream variables the
#'   adjustment is expected to move (e.g. `"PTM -> P -> PC"`). Used in
#'   [describe_projection()] for the round-trip check.
#' @param expected_effect Character. Plain-English description of what the
#'   adjustment should do (e.g. `"+0.2pp CPI by 2027Q4"`).
#' @param confidence One of `"high"`, `"medium"`, `"low"`.
#' @param tail One of `"decay_50"` (default — matches the EViews
#'   `_a(-1) * -0.5` convention from `solve_model.prg`), `"carry"` (hold last
#'   value forward), or `"zero"` (truncate to zero beyond horizon).
#' @param owner    Character. Who proposed this adjustment.
#' @param round_id Character. The round this adjustment belongs to.
#' @param source   One of `"human"` or `"llm"`.
#'
#' @return An `adjustment` S3 object (a named list with class
#'   `c("adjustment", "list")`).
#'
#' @seealso [adjustment_list()], [validate_adjustment()],
#'   [expand_adjustments()] (numeric expansion onto a quarter range), and
#'   `martin::to_constant_adjustment_list()` (the bimets wrapper).
#' @export
adjustment <- function(equation,
                       horizon,
                       value,
                       rationale,
                       channel        = NA_character_,
                       expected_effect = NA_character_,
                       confidence     = c("medium", "high", "low"),
                       tail           = c("decay_50", "carry", "zero"),
                       owner          = NA_character_,
                       round_id       = NA_character_,
                       source         = c("human", "llm", "llm-refined")) {
  confidence <- match.arg(confidence)
  tail       <- match.arg(tail)
  source     <- match.arg(source)

  obj <- list(
    equation        = equation,
    horizon         = horizon,
    value           = value,
    rationale       = rationale,
    channel         = channel,
    expected_effect = expected_effect,
    confidence      = confidence,
    tail            = tail,
    owner           = owner,
    round_id        = round_id,
    source          = source
  )
  class(obj) <- c("adjustment", "list")
  validate_adjustment(obj)
}

#' Validate an adjustment object
#'
#' Checks types, lengths, and that `equation` is a known MARTIN equation
#' flagged adjustable in [martin::equation_catalogue()]. The catalogue check
#' is skipped if the `martin` package isn't loadable (e.g. when judgement is
#' being tested in isolation).
#'
#' Errors carry the field name so messages are easy to chase.
#'
#' @param x An object that should be an `adjustment`.
#' @return `x` invisibly. Throws on failure.
#' @export
validate_adjustment <- function(x) {
  if (!inherits(x, "adjustment")) {
    stop("Not an `adjustment` object.", call. = FALSE)
  }

  required <- c("equation", "horizon", "value", "rationale",
                "channel", "expected_effect", "confidence",
                "tail", "owner", "round_id", "source")
  missing <- setdiff(required, names(x))
  if (length(missing)) {
    stop("adjustment is missing fields: ",
         paste(missing, collapse = ", "), call. = FALSE)
  }

  if (!is.character(x$equation) || length(x$equation) != 1L || !nzchar(x$equation)) {
    stop("`equation` must be a non-empty single string.", call. = FALSE)
  }
  if (!is.character(x$horizon) || length(x$horizon) < 1L) {
    stop("`horizon` must be a non-empty character vector of `yyyyQq` quarters.",
         call. = FALSE)
  }
  # Reuse the shared parser; it throws on malformed strings with the same
  # "yyyyQq" hint.
  tryCatch(
    parse_quarter(x$horizon),
    error = function(e) stop("`horizon` values must match `yyyyQq` (e.g. `2026Q1`). ",
                             conditionMessage(e), call. = FALSE)
  )
  # Horizon must be strictly increasing — out-of-order quarters would silently
  # collide when expanded onto a continuous range.
  yq <- parse_quarter(x$horizon)
  idx <- quarter_index(yq$year, yq$quarter)
  if (any(diff(idx) <= 0L)) {
    stop("`horizon` quarters must be strictly increasing. Got: ",
         paste(x$horizon, collapse = ", "), call. = FALSE)
  }
  if (!is.numeric(x$value) || length(x$value) != length(x$horizon)) {
    stop("`value` must be numeric and the same length as `horizon`.",
         call. = FALSE)
  }
  if (!is.character(x$rationale) || length(x$rationale) != 1L || !nzchar(x$rationale)) {
    stop("`rationale` must be a non-empty single string. ",
         "Adjustments without a rationale defeat the point of SIBYL.",
         call. = FALSE)
  }
  if (!x$confidence %in% c("high", "medium", "low")) {
    stop("`confidence` must be one of high, medium, low.", call. = FALSE)
  }
  if (!x$tail %in% c("decay_50", "carry", "zero")) {
    stop("`tail` must be one of decay_50, carry, zero.", call. = FALSE)
  }
  if (!x$source %in% c("human", "llm", "llm-refined")) {
    stop("`source` must be one of human, llm, llm-refined.", call. = FALSE)
  }

  # Cross-check against the catalogue if available. Soft check: if martin
  # isn't loadable (judgement tested standalone), skip silently.
  cat <- try(martin::equation_catalogue(), silent = TRUE)
  if (!inherits(cat, "try-error")) {
    row <- cat[cat$code == x$equation, , drop = FALSE]
    if (nrow(row) == 0L) {
      stop("Unknown MARTIN equation code: ", x$equation,
           ". See martin::equation_catalogue().", call. = FALSE)
    }
    if (!isTRUE(row$adjustable)) {
      stop("Equation `", x$equation,
           "` is flagged not adjustable in the equation catalogue ",
           "(typically because it's a pure identity).", call. = FALSE)
    }
  }

  invisible(x)
}

#' Test whether an object is an adjustment
#'
#' @param x Any object.
#' @return `TRUE` if `x` inherits from `"adjustment"`.
#' @export
is_adjustment <- function(x) inherits(x, "adjustment")

#' @rdname adjustment
#' @export
format.adjustment <- function(x, ...) {
  hdr <- glue::glue(
    "<adjustment {x$equation}> ",
    "{length(x$horizon)} quarter(s), ",
    "{x$horizon[1]}..{x$horizon[length(x$horizon)]} ",
    "[tail={x$tail}, conf={x$confidence}, src={x$source}]"
  )
  body <- c(
    glue::glue("  value:     {paste(format(x$value, nsmall = 2), collapse = ', ')}"),
    glue::glue("  rationale: {x$rationale}"),
    if (!is.na(x$channel))         glue::glue("  channel:   {x$channel}"),
    if (!is.na(x$expected_effect)) glue::glue("  expected:  {x$expected_effect}"),
    if (!is.na(x$owner))           glue::glue("  owner:     {x$owner}"),
    if (!is.na(x$round_id))        glue::glue("  round:     {x$round_id}")
  )
  paste(c(hdr, body), collapse = "\n")
}

#' @rdname adjustment
#' @export
print.adjustment <- function(x, ...) {
  cat(format(x, ...), "\n", sep = "")
  invisible(x)
}

# -----------------------------------------------------------------------------
# adjustment_list — the collection used by the rest of the pipeline
# -----------------------------------------------------------------------------

#' Construct an adjustment list
#'
#' A typed wrapper around a list of [adjustment()] objects. Multiple
#' adjustments may target the same equation; they are summed when converted
#' to a bimets `ConstantAdjustment` list.
#'
#' @param ... `adjustment` objects.
#' @return An `adjustment_list` S3 object.
#' @export
adjustment_list <- function(...) {
  xs <- list(...)
  for (x in xs) validate_adjustment(x)
  class(xs) <- c("adjustment_list", "list")
  xs
}

#' @rdname adjustment_list
#' @export
print.adjustment_list <- function(x, ...) {
  if (length(x) == 0L) {
    cat("<adjustment_list, empty>\n")
    return(invisible(x))
  }
  cat("<adjustment_list, ", length(x), " item(s)>\n", sep = "")
  for (a in x) {
    cat(format(a), "\n", sep = "")
  }
  invisible(x)
}

#' Coerce an adjustment list to a tidy tibble
#'
#' Useful for showing the human reviewer a table before they approve.
#'
#' @param x An `adjustment_list`.
#' @return A tibble: one row per `(adjustment, horizon-quarter)` pair, with
#'   the metadata fields broadcast.
#' @export
as_tibble_adjustments <- function(x) {
  if (!inherits(x, "adjustment_list")) {
    stop("Expected an adjustment_list.", call. = FALSE)
  }
  if (length(x) == 0L) {
    return(tibble::tibble(
      equation = character(), quarter = character(), value = numeric(),
      rationale = character(), channel = character(),
      expected_effect = character(), confidence = character(),
      tail = character(), owner = character(), round_id = character(),
      source = character()
    ))
  }
  rows <- purrr::map_dfr(x, function(a) {
    tibble::tibble(
      equation        = a$equation,
      quarter         = a$horizon,
      value           = a$value,
      rationale       = a$rationale,
      channel         = a$channel,
      expected_effect = a$expected_effect,
      confidence      = a$confidence,
      tail            = a$tail,
      owner           = a$owner,
      round_id        = a$round_id,
      source          = a$source
    )
  })
  rows
}

#' Expand an adjustment list onto a continuous quarter range
#'
#' Produces a named list of numeric vectors keyed by MARTIN equation code.
#' Each vector is aligned to the quarters returned by `quarter_seq(solve_range[1],
#' solve_range[2])`. Bimets-shape conversion lives in `martin`; this function
#' deliberately has no bimets dependency.
#'
#' Per-adjustment behaviour:
#'
#' - Explicit horizon values are placed at the matching quarter positions.
#' - Cells before the first horizon quarter are zero.
#' - Cells after the last horizon quarter are filled per the adjustment's
#'   `tail` rule:
#'     - `"zero"`     — zero.
#'     - `"carry"`    — hold the last horizon value forward.
#'     - `"decay_50"` — geometric decay with sign flip, matching the EViews
#'                      `_a = _a(-1) * -0.5` convention from
#'                      `references/MARTIN-master/Programs/solve_model.prg`.
#'
#' Multiple adjustments targeting the same equation are summed element-wise.
#'
#' If an adjustment's entire horizon falls outside `solve_range` a warning is
#' issued and that adjustment contributes nothing. Partial overlap is allowed
#' silently — only the in-range portion is used (the tail rule continues to
#' extend from the last in-range horizon value).
#'
#' @param x An `adjustment_list` (possibly empty).
#' @param solve_range A length-2 character vector `c("yyyyQq", "yyyyQq")`
#'   identifying the inclusive simulation range.
#'
#' @return A named list. Names are equation codes; values are numeric vectors
#'   of length `length(quarter_seq(solve_range[1], solve_range[2]))`. The list
#'   carries `solve_range` and `quarters` attributes so downstream code can
#'   recover the alignment without re-parsing.
#' @export
expand_adjustments <- function(x, solve_range) {
  if (!inherits(x, "adjustment_list")) {
    stop("Expected an `adjustment_list`. Got: ", paste(class(x), collapse = "/"),
         call. = FALSE)
  }
  if (length(solve_range) != 2L || !is.character(solve_range)) {
    stop("`solve_range` must be a length-2 character vector ",
         "of `yyyyQq` strings.", call. = FALSE)
  }

  range_q <- quarter_seq(solve_range[1], solve_range[2])
  n <- length(range_q)

  out <- list()
  attr(out, "solve_range") <- solve_range
  attr(out, "quarters") <- range_q

  if (length(x) == 0L) return(out)

  for (a in x) {
    eq_values <- numeric(n)
    horizon_idx <- match(a$horizon, range_q)
    in_range <- !is.na(horizon_idx)

    if (!any(in_range)) {
      warning("Adjustment on `", a$equation,
              "` has no horizon quarters within solve_range; skipping.",
              call. = FALSE)
      next
    }

    eq_values[horizon_idx[in_range]] <- a$value[in_range]

    last_h_in_range <- max(horizon_idx[in_range])
    if (last_h_in_range < n) {
      last_val <- a$value[max(which(in_range))]
      tail_positions <- seq.int(last_h_in_range + 1L, n)
      step <- seq_along(tail_positions)
      tail_vals <- switch(
        a$tail,
        zero     = rep(0,        length(tail_positions)),
        carry    = rep(last_val, length(tail_positions)),
        decay_50 = last_val * (-0.5)^step
      )
      eq_values[tail_positions] <- tail_vals
    }

    out[[a$equation]] <- if (is.null(out[[a$equation]])) {
      eq_values
    } else {
      out[[a$equation]] + eq_values
    }
  }

  out
}
