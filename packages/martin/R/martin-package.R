#' martin: SIBYL wrapper around the bimets implementation of MARTIN
#'
#' The Reserve Bank of Australia's MARTIN macroeconometric model, solved via
#' the `bimets` package. Built on the code in
#' `references/bimets-main/`; the model definition files are vendored into
#' `inst/extdata/` of this package with attribution.
#'
#' The public surface is small:
#'
#' - [load_martin()] — read the bimets model file and a database, return a
#'   loaded bimets model object.
#' - [solve_martin()] — solve baseline plus add-factor scenarios; returns a
#'   tidy projection tibble.
#' - [equation_catalogue()] — the equation menu the LLM sees, with
#'   plain-English descriptions, sector groupings, and which equations are
#'   eligible for adjustment.
#' - [martin_data_fixture()] — the frozen MARTINDATA_XLSX snapshot used by
#'   regression tests.
#'
#' v0 uses the `MARTINMOD_AF.txt` form with frozen EViews coefficients.
#' Re-estimation via `MARTINMOD_EST.txt` is a future flag.
#'
#' @keywords internal
"_PACKAGE"
