#' Optional MARTIN model features (baseline-neutral by default)
#'
#' The enhancements from `docs/martin_enhancements_plan.md` are delivered as
#' opt-in *features*: load-time transforms of the bimets model text plus the
#' data seeding bimets requires (every endogenous variable must have a series
#' present in the database). With no features requested the model text is
#' returned verbatim, so the frozen, no-adjustment baseline stays bit-identical
#' to the bimets reference (design principle 6).
#'
#' Implemented features:
#' \describe{
#'   \item{`output_gap`}{CES production function inverted EMMA-style. Adds the
#'     identities `KSTAR`, `NSTAR`, `YSTAR`, `YGAP`, `LESTAR`. Requires the
#'     labour-augmenting efficiency trend `EFF` in the database (see
#'     [sibyldata::fit_efficiency_trend()]). Calibration via
#'     `feature_params$ces_*`.}
#'   \item{`external_accounting`}{Net-foreign-liability / current-account stock
#'     accounting. Adds `NTB`, `TB_GDP`, `NCA`, `VNFL`, `NFL_GDP`, `CAD_GDP`.
#'     Uses `NFOY`/`NTRF` if present (else 0) and a `VNFL` seed.}
#'   \item{`fiscal_accounting`}{Government budget-and-debt accounting. Adds
#'     `NREV`, `NSPEND`, `NLEND`, `INTG`, `BG`, `BG_GDP`, `DEF_GDP`. Uses
#'     effective tax rates / transfers as exogenous inputs.}
#'   \item{`fx_premium`}{(T2) Debt-elastic exchange-rate risk premium: adds a
#'     `NFL_GDP` term to the `RTWI` equation. Needs `external_accounting`.}
#'   \item{`fiscal_rule`}{(T2) Debt-stabilising fiscal rule on the effective
#'     household tax rate. Needs `fiscal_accounting`.}
#'   \item{`convex_ptm`}{(T3) Convex Phillips curve: swaps the linear `c7*LURGAP`
#'     gap term in `PTM` for the reciprocal `c7*(LURGAP/LUR)` form (re-estimated).}
#'   \item{`inverted_le`}{(T3) Capital-aware employment: swaps the reduced-form
#'     error-correction target in `LE` for the inverted-production-function
#'     employment `LESTAR` (re-estimated). Needs `output_gap`.}
#' }
#'
#' @name model_features
NULL

# Order matters: insertions first (so swap-based features can target inserted
# blocks), then swaps.
.MARTIN_FEATURES <- c(
  "output_gap", "external_accounting", "fiscal_accounting",
  "fx_premium", "fiscal_rule", "convex_ptm", "inverted_le"
)

#' Default calibration constants for the optional features
#' @return A named list of calibration parameters.
#' @export
feature_defaults <- function() {
  list(
    # CES (sigma = 0.5 -> rho = -1; identities use the harmonic form so no
    # power operator is needed). theta_k is the Australian capital share;
    # gamma is the CES scale, calibrated from data (NA forces the caller to
    # supply it for output_gap).
    ces_theta_k = 0.38,
    ces_gamma   = NA_real_,
    # Debt-elastic FX premium (per cent of GDP units on NFL_GDP).
    fx_phi  = 0.03,
    fx_norm = 50,
    # Debt-stabilising fiscal rule.
    fiscal_rho1     = 0.10,
    fiscal_rho2     = 0.10,
    fiscal_bg_target = 30,
    fiscal_etr_direct = 0.16,
    # External accounting.
    nfl_seed = NA_real_
  )
}

#' Which new endogenous variables each feature introduces
#' @param features Character vector of feature names.
#' @return Character vector of new endogenous variable names.
#' @keywords internal
feature_new_vars <- function(features) {
  v <- character(0)
  if ("output_gap" %in% features)
    v <- c(v, "KSTAR", "NSTAR", "YSTAR", "YGAP", "LESTAR")
  if ("external_accounting" %in% features)
    v <- c(v, "NTB", "TB_GDP", "NCA", "VNFL", "NFL_GDP", "CAD_GDP")
  if ("fiscal_accounting" %in% features)
    v <- c(v, "NREV", "NSPEND", "NLEND", "INTG", "BG", "BG_GDP", "DEF_GDP")
  unique(v)
}

# --- text helpers ----------------------------------------------------------

# Replace `pattern` with `replacement` exactly once; error if not found or not
# unique. The loud failure is deliberate — a silent no-op swap would ship a
# feature that does nothing.
.swap_once <- function(text, pattern, replacement) {
  hits <- gregexpr(pattern, text, fixed = TRUE)[[1]]
  found <- !(length(hits) == 1L && hits[1] == -1L)
  n <- if (found) length(hits) else 0L
  if (n != 1L) {
    stop(sprintf("feature swap matched %d times (need exactly 1): %s",
                 n, pattern), call. = FALSE)
  }
  sub(pattern, replacement, text, fixed = TRUE)
}

.insert_blocks_before_end <- function(lines, blocks) {
  end_i <- which(grepl("^END\\s*$", lines))
  if (!length(end_i)) stop("model text has no END line", call. = FALSE)
  end_i <- max(end_i)
  append(lines, blocks, after = end_i - 1L)
}

# --- feature blocks (inserted identities) ----------------------------------

.block_output_gap <- function(p) {
  if (is.na(p$ces_gamma)) {
    stop("output_gap feature needs feature_params$ces_gamma ",
         "(calibrate via sibyldata::ces_calibration()).", call. = FALSE)
  }
  tk <- p$ces_theta_k
  tn <- 1 - tk
  g  <- p$ces_gamma
  # sigma = 0.5 -> CES collapses to the harmonic form
  #   Y = gamma / ( theta_n/(EFF*LHPP*LE) + theta_k/K )
  # so potential and the inverted employment need only * and / (no powers).
  c(
    "COMMENT> SIBYL output_gap: CES production block (sigma=0.5 harmonic form)",
    "COMMENT> KSTAR  market capital stock",
    "IDENTITY> KSTAR",
    "EQ> KSTAR = KIBN + KIBRE",
    "",
    "COMMENT> NSTAR  employment at the NAIRU (actual participation, v1)",
    "IDENTITY> NSTAR",
    "EQ> NSTAR = LPOP * (LPR/100) * (1 - TLUR/100)",
    "",
    "COMMENT> YSTAR  potential output (CES at trend efficiency, NAIRU employment, actual capital)",
    "IDENTITY> YSTAR",
    sprintf("EQ> YSTAR = %.10g / ( %.10g/(EFF*LHPP*NSTAR) + %.10g/KSTAR )", g, tn, tk),
    "",
    "COMMENT> YGAP  output gap, per cent",
    "IDENTITY> YGAP",
    "EQ> YGAP = (LOG(Y) - LOG(YSTAR)) * 100",
    "",
    "COMMENT> LESTAR  inverted-production-function employment (EMMA Eq 6a)",
    "COMMENT> denom (gamma/Y - theta_k/KSTAR) > 0 holds empirically; a NaN here",
    "COMMENT> is surfaced by solve_martin's convergence diagnostic.",
    "IDENTITY> LESTAR",
    sprintf("EQ> LESTAR = ( %.10g / (%.10g/Y - %.10g/KSTAR) ) / (EFF*LHPP)",
            tn, g, tk),
    ""
  )
}

.block_external <- function(p) {
  c(
    "COMMENT> SIBYL external_accounting: current account + net foreign liability stock",
    "COMMENT> NTB  nominal trade balance",
    "IDENTITY> NTB",
    "EQ> NTB = NX - NM",
    "",
    "COMMENT> TB_GDP  trade balance, per cent of GDP",
    "IDENTITY> TB_GDP",
    "EQ> TB_GDP = NTB / NY * 100",
    "",
    "COMMENT> NCA  current account = trade balance + net foreign income + transfers",
    "COMMENT> NFOY (net primary income) and NTRF (net secondary income) are exogenous inputs (0 if absent)",
    "IDENTITY> NCA",
    "EQ> NCA = NTB + NFOY + NTRF",
    "",
    "COMMENT> VNFL  net foreign liability stock (accumulates the current-account deficit)",
    "IDENTITY> VNFL",
    "EQ> VNFL = TSLAG(VNFL,1) - NCA",
    "",
    "COMMENT> NFL_GDP  net foreign liabilities, per cent of GDP",
    "IDENTITY> NFL_GDP",
    "EQ> NFL_GDP = VNFL / NY * 100",
    "",
    "COMMENT> CAD_GDP  current account deficit, per cent of GDP",
    "IDENTITY> CAD_GDP",
    "EQ> CAD_GDP = -NCA / NY * 100",
    ""
  )
}

.block_fiscal <- function(p) {
  # ETR_DIRECT, ETR_INDIRECT, ETR_CORP, NTRANSFERS, IIRG are exogenous inputs.
  # When fiscal_rule is also requested, ETR_DIRECT is replaced by an identity
  # (see .feature_fiscal_rule). Bases reuse in-model nominal series.
  c(
    "COMMENT> SIBYL fiscal_accounting: government budget + debt accounting",
    "COMMENT> NREV  nominal government revenue (effective-rate x base)",
    "IDENTITY> NREV",
    "EQ> NREV = ETR_DIRECT*NHDY + ETR_INDIRECT*NC + ETR_CORP*(NY - NHCOE)",
    "",
    "COMMENT> NSPEND  nominal government spending (demand + transfers)",
    "IDENTITY> NSPEND",
    "EQ> NSPEND = NG + NTRANSFERS",
    "",
    "COMMENT> INTG  debt interest (implicit rate on lagged debt)",
    "IDENTITY> INTG",
    "EQ> INTG = IIRG/100 * TSLAG(BG,1)",
    "",
    "COMMENT> NLEND  government net lending",
    "IDENTITY> NLEND",
    "EQ> NLEND = NREV - NSPEND - INTG",
    "",
    "COMMENT> BG  government debt stock",
    "IDENTITY> BG",
    "EQ> BG = TSLAG(BG,1) - NLEND",
    "",
    "COMMENT> BG_GDP  debt, per cent of GDP",
    "IDENTITY> BG_GDP",
    "EQ> BG_GDP = BG / NY * 100",
    "",
    "COMMENT> DEF_GDP  fiscal deficit, per cent of GDP",
    "IDENTITY> DEF_GDP",
    "EQ> DEF_GDP = -NLEND / NY * 100",
    ""
  )
}

# --- swap-based features ----------------------------------------------------

.feature_fx_premium <- function(text, p) {
  .swap_once(
    text,
    "- 5  / 100  * TSDELTA(WR2SP,1) )",
    sprintf("- 5  / 100  * TSDELTA(WR2SP,1)  - %.10g*(TSLAG(NFL_GDP,1) - %.10g) )",
            p$fx_phi, p$fx_norm)
  )
}

.feature_inverted_le <- function(text, p) {
  .swap_once(
    text,
    "c2*(LOG(TSLAG(LE,1)) - LOG(TSLAG(Y,1))+0.4*(LOG(TSLAG(RLC,1)) - TSLAG(TLLA,1)) + TSLAG(TLLA,1) + TSLAG(TLLHPP,1) )",
    "c2*(LOG(TSLAG(LE,1)) - LOG(TSLAG(LESTAR,1)) )"
  )
}

.feature_fiscal_rule <- function(text, p) {
  # Replace the exogenous ETR_DIRECT input with a debt-stabilising identity.
  # Inserted as an identity just after the fiscal block's NREV definition.
  rule <- paste0(
    "\nCOMMENT> SIBYL fiscal_rule: debt-stabilising effective household tax rate\n",
    "IDENTITY> ETR_DIRECT\n",
    sprintf(paste0("EQ> ETR_DIRECT = %.10g + %.10g*(TSLAG(BG_GDP,1) - %.10g) ",
                   "+ %.10g*TSDELTA(TSLAG(BG_GDP,1),1)\n"),
            p$fiscal_etr_direct, p$fiscal_rho1, p$fiscal_bg_target, p$fiscal_rho2)
  )
  .swap_once(text, "COMMENT> SIBYL fiscal_accounting: government budget + debt accounting",
             paste0(rule, "\nCOMMENT> SIBYL fiscal_accounting: government budget + debt accounting"))
}

#' Apply requested features to MARTIN model text lines
#' @param lines Character vector of model-file lines.
#' @param features Character vector of feature names (subset of
#'   [model_features]). Empty returns `lines` unchanged.
#' @param feature_params Calibration overrides; merged over [feature_defaults()].
#' @return Transformed character vector of model lines.
#' @export
apply_model_features <- function(lines, features = character(0),
                                 feature_params = list()) {
  if (!length(features)) return(lines)
  unknown <- setdiff(features, .MARTIN_FEATURES)
  if (length(unknown)) {
    stop("unknown model feature(s): ", paste(unknown, collapse = ", "),
         call. = FALSE)
  }
  p <- utils::modifyList(feature_defaults(), feature_params)

  # 1. insert new equation blocks before END
  blocks <- character(0)
  if ("output_gap" %in% features)
    blocks <- c(blocks, .block_output_gap(p))
  if ("external_accounting" %in% features)
    blocks <- c(blocks, .block_external(p))
  if ("fiscal_accounting" %in% features)
    blocks <- c(blocks, .block_fiscal(p))
  if (length(blocks)) lines <- .insert_blocks_before_end(lines, blocks)

  # 2. text swaps (operate on the full text, incl. inserted blocks)
  text <- paste(lines, collapse = "\n")
  if ("fiscal_rule" %in% features)  text <- .feature_fiscal_rule(text, p)
  if ("fx_premium" %in% features)   text <- .feature_fx_premium(text, p)
  if ("convex_ptm" %in% features)
    text <- .swap_once(text, "+c7*LURGAP", "+c7*(LURGAP/LUR)")
  if ("inverted_le" %in% features)  text <- .feature_inverted_le(text, p)

  strsplit(text, "\n", fixed = TRUE)[[1]]
}

#' Seed the database with series required by the requested features
#'
#' bimets requires every endogenous variable to have a series in the database.
#' Non-lagged new identities are seeded with NA over the database span (bimets
#' computes them inside TSRANGE); lagged stocks (`VNFL`, `BG`) and exogenous
#' inputs (`EFF`, `NFOY`, `NTRF`, `ETR_*`, `NTRANSFERS`, `IIRG`) must carry real
#' values and are seeded if absent.
#'
#' @param database Named list of bimets TIMESERIES.
#' @param features Character vector of feature names.
#' @param feature_params Calibration overrides; merged over [feature_defaults()].
#' @return The database with the required series added/seeded.
#' @export
seed_feature_data <- function(database, features = character(0),
                              feature_params = list()) {
  if (!length(features)) return(database)
  p <- utils::modifyList(feature_defaults(), feature_params)

  span <- .db_span(database)
  na_series  <- function() bimets::TIMESERIES(rep(NA_real_, span$n),
                                              START = span$start, FREQ = 4)
  zero_series <- function() bimets::TIMESERIES(rep(0, span$n),
                                               START = span$start, FREQ = 4)
  ensure_exog <- function(db, nm, fill = 0) {
    if (is.null(db[[nm]])) db[[nm]] <- bimets::TIMESERIES(
      rep(fill, span$n), START = span$start, FREQ = 4)
    db
  }

  if ("output_gap" %in% features) {
    if (is.null(database[["EFF"]])) {
      stop("output_gap feature requires `EFF` in the database ",
           "(sibyldata::fit_efficiency_trend()).", call. = FALSE)
    }
    if (is.na(p$ces_gamma)) {
      stop("output_gap feature requires feature_params$ces_gamma.",
           call. = FALSE)
    }
    # bimets needs defined initialisation values for every endogenous series,
    # so compute the CES block historically rather than NA-seeding.
    ser <- .compute_output_gap_series(database, p)
    for (nm in names(ser)) {
      if (is.null(database[[nm]])) database[[nm]] <- ser[[nm]]
    }
  }

  if ("external_accounting" %in% features) {
    database <- ensure_exog(database, "NFOY", 0)
    database <- ensure_exog(database, "NTRF", 0)
    for (nm in c("NTB", "TB_GDP", "NCA", "NFL_GDP", "CAD_GDP")) {
      if (is.null(database[[nm]])) database[[nm]] <- na_series()
    }
    # VNFL is lagged: needs a real seed path. Default: a constant seed at the
    # supplied level (per cent of GDP -> nominal via NY) if absent.
    if (is.null(database[["VNFL"]])) {
      ny <- database[["NY"]]
      seed_level <- if (!is.na(p$nfl_seed)) p$nfl_seed else 0
      vnfl0 <- if (!is.null(ny)) seed_level/100 * as.numeric(ny) else rep(seed_level, span$n)
      database[["VNFL"]] <- bimets::TIMESERIES(vnfl0, START = span$start, FREQ = 4)
    }
  }

  if ("fiscal_accounting" %in% features) {
    database <- ensure_exog(database, "ETR_DIRECT",   p$fiscal_etr_direct)
    database <- ensure_exog(database, "ETR_INDIRECT", 0.10)
    database <- ensure_exog(database, "ETR_CORP",     0.05)
    database <- ensure_exog(database, "NTRANSFERS",   0)
    database <- ensure_exog(database, "IIRG",         3)
    for (nm in c("NREV", "NSPEND", "INTG", "NLEND", "BG_GDP", "DEF_GDP")) {
      if (is.null(database[[nm]])) database[[nm]] <- na_series()
    }
    if (is.null(database[["BG"]])) {  # lagged stock: seed at target % of GDP
      ny <- database[["NY"]]
      bg0 <- if (!is.null(ny)) p$fiscal_bg_target/100 * as.numeric(ny)
             else rep(0, span$n)
      database[["BG"]] <- bimets::TIMESERIES(bg0, START = span$start, FREQ = 4)
    }
  }

  database
}

# Compute the CES output-gap block historically (harmonic form, sigma=0.5) on
# the window common to its inputs, returning bimets TIMESERIES for seeding.
.compute_output_gap_series <- function(db, p) {
  need <- c("Y", "KIBN", "KIBRE", "LPOP", "LPR", "TLUR", "LHPP", "EFF")
  miss <- need[vapply(need, function(n) is.null(db[[n]]), logical(1))]
  if (length(miss))
    stop("output_gap needs series: ", paste(miss, collapse = ", "), call. = FALSE)
  tss <- lapply(need, function(n) stats::as.ts(db[[n]]))
  lo <- max(vapply(tss, function(x) stats::tsp(x)[1], 0))
  hi <- min(vapply(tss, function(x) stats::tsp(x)[2], 0))
  w  <- lapply(tss, function(x) as.numeric(stats::window(x, start = lo, end = hi)))
  names(w) <- need
  tk <- p$ces_theta_k; tn <- 1 - tk; g <- p$ces_gamma
  kstar  <- w$KIBN + w$KIBRE
  nstar  <- w$LPOP * (w$LPR / 100) * (1 - w$TLUR / 100)
  ystar  <- g / (tn / (w$EFF * w$LHPP * nstar) + tk / kstar)
  ygap   <- (log(w$Y) - log(ystar)) * 100
  lestar <- (tn / (g / w$Y - tk / kstar)) / (w$EFF * w$LHPP)
  sy <- floor(lo + 1e-9); sq <- round((lo - sy) * 4 + 1)
  mk <- function(v) bimets::TIMESERIES(v, START = c(sy, sq), FREQ = 4)
  list(KSTAR = mk(kstar), NSTAR = mk(nstar), YSTAR = mk(ystar),
       YGAP = mk(ygap), LESTAR = mk(lestar))
}

# Span (start year/quarter + length) of the longest series in the database.
.db_span <- function(database) {
  lens <- vapply(database, function(x) length(as.numeric(x)), integer(1))
  ref  <- database[[which.max(lens)]]
  tsp  <- stats::tsp(ref)
  sy   <- floor(tsp[1] + 1e-9)
  sq   <- round((tsp[1] - sy) * 4 + 1)
  list(start = c(sy, sq), n = length(as.numeric(ref)))
}
