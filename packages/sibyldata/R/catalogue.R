#' The series catalogue
#'
#' The institutional knowledge for SIBYL: each row maps a MARTIN variable to
#' a source series ID plus the metadata needed to fetch and shape it. Lifted
#' and extended from
#' `references/MARTIN-master/Programs/import_data.prg`.
#'
#' Columns:
#'
#' - `martin_var` — the MARTIN variable name (uppercase for model endogenous
#'   variables; lowercase for raw imports that get transformed downstream).
#' - `source` — one of `abs`, `rba`, `fred`, `oecd`, `worldbank`, `bom`,
#'   `derived`.
#' - `source_id` — the source's series identifier (`A2304081W` for ABS,
#'   `GDPC1` for FRED, etc.). `NA` for derived series.
#' - `source_table` — catalogue / table reference where it helps (e.g.
#'   `"5206.0"` for ABS, `"F02"` for RBA). `NA` otherwise.
#' - `source_frequency` — `M`, `Q`, `A`, or `D` for monthly / quarterly /
#'   annual / daily.
#' - `aggregation` — how to convert to quarterly (`mean`, `sum`, `last`,
#'   `first`). `NA` when source is already quarterly.
#' - `transformation` — `direct` (just rename), `spliced` (needs
#'   backcasting / splicing), `chowlin` (Chow-Lin annual→quarterly),
#'   `level_from_pct` (cumulate from a base), `derived` (computed from other
#'   catalogue entries), `dummy` (deterministic calendar dummy / trend,
#'   spec in `inst/extdata/dummies.csv`), `scalar` (constant series,
#'   spec in `inst/extdata/scalars.csv`).
#' - `description` — plain English (consumed by the LLM and humans alike).
#' - `units` — free text.
#'
#' @return A tibble of the catalogue.
#' @export
series_catalogue <- function() {
  path <- system.file(
    "extdata", "series_catalogue.csv",
    package = "sibyldata", mustWork = FALSE
  )
  if (!nzchar(path) || !file.exists(path)) {
    path <- file.path("inst", "extdata", "series_catalogue.csv")
  }
  readr::read_csv(path, show_col_types = FALSE)
}
