#' Path to one of the vendored MARTIN model files
#'
#' The bimets `.txt` model definitions are vendored into `inst/extdata/` from
#' `references/bimets-main/`. This helper returns the absolute path on disk.
#'
#' @param variant One of `"af"` (default — `MARTINMOD_AF.txt`, behavioural form
#'   with `RESTRICT> c1=1` so each equation is mathematically an identity with
#'   frozen EViews coefficients but a `ConstantAdjustment` residual slot),
#'   `"identity"` (`MARTINMOD.txt`, pure-identity equivalent), or `"est"`
#'   (`MARTINMOD_EST.txt`, the true behavioural form for re-estimation).
#' @return Absolute path to the `.txt` file.
#' @export
model_file_path <- function(variant = c("af", "identity", "est")) {
  variant <- match.arg(variant)
  fname <- switch(variant,
    af       = "MARTINMOD_AF.txt",
    identity = "MARTINMOD.txt",
    est      = "MARTINMOD_EST.txt"
  )
  path <- system.file("extdata", fname, package = "martin", mustWork = FALSE)
  if (!nzchar(path) || !file.exists(path)) {
    # devtools::load_all() path during development
    path <- file.path("inst", "extdata", fname)
  }
  path
}

#' Path to the bundled MARTINDATA fixture
#'
#' The frozen `MARTINDATA_XLSX.xlsx` copied from
#' `references/bimets-main/`. Used by the regression test that asserts
#' SIBYL's solve matches the bimets reference solve.
#'
#' @return Absolute path to the `.xlsx` file.
#' @export
martin_data_fixture <- function() {
  path <- system.file(
    "extdata", "martin_data_fixture.xlsx",
    package = "martin", mustWork = FALSE
  )
  if (!nzchar(path) || !file.exists(path)) {
    path <- file.path("inst", "extdata", "martin_data_fixture.xlsx")
  }
  path
}

#' Load a MARTIN bimets model with data
#'
#' Wraps the canonical pattern from
#' `references/bimets-main/BIMETS_MARTIN_LOAD.R`:
#'
#' ```r
#' MARTIN <- bimets::LOAD_MODEL("MARTINMOD_AF.txt")
#' MARTIN <- bimets::LOAD_MODEL_DATA(MARTIN, data)
#' MARTIN <- bimets::ESTIMATE(MARTIN)
#' ```
#'
#' For the default `variant = "af"`, ESTIMATE simply confirms the imposed
#' coefficients (every equation is `BEHAVIORAL>` with `RESTRICT> c1=1`) and
#' computes residuals — those residuals are what the add-factor pipeline
#' consumes downstream.
#'
#' @param database A named list of `bimets::TIMESERIES` keyed by MARTIN
#'   variable name. Eventually produced by
#'   [sibyldata::to_martin_database()]; for now, by [read_fixture()] in tests.
#' @param variant Which model file to load. See [model_file_path()].
#' @param estimate Logical. If `TRUE` (default), call `bimets::ESTIMATE()`
#'   after loading data. Skip only for path-checking; the residual slots
#'   downstream code uses are populated by ESTIMATE.
#'
#' @return A loaded bimets model object.
#' @export
load_martin <- function(database,
                        variant  = c("af", "identity", "est"),
                        estimate = TRUE) {
  variant <- match.arg(variant)
  if (!is.list(database) || length(database) == 0L) {
    stop("`database` must be a non-empty named list of bimets TIMESERIES.",
         call. = FALSE)
  }
  if (is.null(names(database)) || any(!nzchar(names(database)))) {
    stop("`database` must be named; names are MARTIN variable codes.",
         call. = FALSE)
  }

  model_text <- paste(readLines(model_file_path(variant)), collapse = "\n")
  .suppress_bimets_version_warning({
    m <- bimets::LOAD_MODEL(modelText = model_text)
    m <- bimets::LOAD_MODEL_DATA(m, database)
    if (isTRUE(estimate)) {
      m <- bimets::ESTIMATE(m)
    }
  })
  m
}
