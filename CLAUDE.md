# CLAUDE.md — context for sessions

This file is loaded automatically by Claude Code. Keep it current as the
project evolves.

## What SIBYL is, in one paragraph

SIBYL automates a central-bank-style forecast round using public data only.
The LLM layer is strictly a **translator and drafter**, not a forecaster. It
converts narrative statements into proposed add-factors on specific MARTIN
equations (each with a rationale), and it drafts prose explaining solved
projections. Humans always see and approve numerical adjustments before they
enter a solve. The models produce the numbers; the LLM handles the impedance
mismatch between human language and model inputs.

## Architecture

Four R packages under [packages/](packages/), each independent and properly
namespaced:

| Package | Role |
|---|---|
| [sibyldata](packages/sibyldata/) | Wraps `readabs`, `readrba`, `fredr`, OECD; returns tidy panels with vintage tracking; storage as parquet via `arrow`. |
| [nowcast](packages/nowcast/) | Bridge equations + simple models (likely `fable`) producing Q+0 and Q+1 for the variables MARTIN needs as handover. Deliberately simple. |
| [martin](packages/martin/) | Wraps the `bimets` implementation of MARTIN. Takes (a) starting database, (b) exogenous paths, (c) a list of add-factors keyed by equation and horizon. Returns a solved projection as a tidy data frame. |
| [judgement](packages/judgement/) | LLM-facing. `propose_adjustments(narrative, baseline)` returns structured add-factor proposals with rationales; `describe_projection(projection, baseline)` drafts prose explaining differences from baseline. Uses `ellmer` with structured outputs via `type_object()`. |

Pipeline orchestration lives in [_targets.R](_targets.R). Reports are Quarto
documents under [reports/](reports/).

The full LLM-layer architecture (propose / describe / audit / refine, the
sensitivity matrix, the diagnostic classifier, worked examples) is
documented in detail at [docs/llm_layer.md](docs/llm_layer.md).

## Design principles to enforce

1. **The LLM does not forecast.** Anything that looks like the model
   substituting its own judgement for a numerical model is a bug.
2. **Add-factors are first-class objects with metadata**, not bare numbers.
   The `adjustment` S3 class in [packages/judgement/R/adjustment.R](packages/judgement/R/adjustment.R)
   carries `{equation, horizon, value, rationale, channel, expected_effect,
   confidence, owner, round_id}` plus tail behaviour (carry / decay / zero).
3. **Round-trip consistency check.** After the human accepts adjustments and
   MARTIN solves, the LLM reads the solved projection and describes it. If the
   description doesn't match the input narrative, we've caught a translation
   error.
4. **Human-in-the-loop is structural.** Any path from narrative → solved
   forecast must pass through an explicit approval step where proposed
   add-factors are shown as a table with rationales before MARTIN sees them.
5. **Targets-based orchestration from day one.** Use `targets` even though it
   feels heavy.
6. **Reproducibility against the reference repos.** `martin` ships a frozen
   fixture (`packages/martin/inst/extdata/martin_data_fixture.xlsx`) copied
   from `references/bimets-main/MARTINDATA_XLSX.xlsx`. The regression test in
   [packages/martin/tests/testthat/test-regression-against-bimets.R](packages/martin/tests/testthat/test-regression-against-bimets.R)
   asserts SIBYL's `solve_martin()` with no adjustments matches the bimets
   reference solve.
7. **No UI yet.** Quarto reports as output, function calls as input.
8. **Public data only.** No internal-RBA data, no replacement of EA judgement
   processes.

## Where things live: MARTIN_EVIEWS vs MARTIN_BIMETS vs SIBYL

- **[references/MARTIN-master/](references/MARTIN-master/)** — the EViews / R
  implementation. The **canonical reference** for what MARTIN's equations are
  and how its data flow works. Read it when:
  - You need the plain-English description of an equation (the `'comments`
    in [equations.prg](references/MARTIN-master/Programs/equations.prg)
    drive [equation_catalogue.csv](packages/martin/inst/extdata/equation_catalogue.csv)).
  - You need to understand a splicing / backcasting recipe
    ([modify_data.prg](references/MARTIN-master/Programs/modify_data.prg)).
  - You need to understand how add-factors are constructed and decayed
    ([solve_model.prg](references/MARTIN-master/Programs/solve_model.prg)).
  - You need the ABS / RBA / FRED series-ID → MARTIN-variable map
    ([import_data.prg](references/MARTIN-master/Programs/import_data.prg)).

- **[references/bimets-main/](references/bimets-main/)** — the R / `bimets`
  port. SIBYL's `martin` package is built on this. Read it when:
  - You need the model file SIBYL actually uses
    ([MARTINMOD_AF.txt](references/bimets-main/MARTINMOD_AF.txt) — also
    vendored to `packages/martin/inst/extdata/`).
  - You need to see the canonical `ConstantAdjustment` add-factor pipeline
    ([BIMETS_MARTIN_LOAD.R](references/bimets-main/BIMETS_MARTIN_LOAD.R)).

- **[packages/martin/](packages/martin/)** — SIBYL's own MARTIN wrapper. The
  bimets `.txt` files are vendored (copied with attribution) into
  [packages/martin/inst/extdata/](packages/martin/inst/extdata/). The default
  is `MARTINMOD_AF.txt` with **frozen coefficients** for v0; re-estimation
  via `MARTINMOD_EST.txt` is a future flag.

## Conventions

- R native. Tidyverse, `targets`, `ellmer`, `fable`, `bimets`, `arrow`,
  `testthat`, `quarto`.
- snake_case for code, UPPERCASE for MARTIN variable names (bimets is
  case-sensitive; we follow MARTINMOD_AF.txt).
- Explicit namespacing in package code (`dplyr::filter()`, not `filter()`).
- Tidyverse style guide.
- No emojis in code, files, or commits.
- API keys via [.Renviron](.Renviron.example) — never in source.
- Binary EViews `.wf1` files are not committed.
- The local parquet cache lives at `data/cache/` and is gitignored.

## How to work in this repo

- `just test` — run all package tests (`testthat`).
- `just check` — `R CMD check` each package.
- `just pipeline` — run the full `targets` pipeline.
- `just report` — render the round report.

## What you do NOT do without asking

- Re-estimate MARTIN coefficients (default is the published EViews values).
- Add an opinion to the LLM's output beyond what the input narrative says.
- Skip the human-approval step on add-factors.
- Commit `.Renviron`, API keys, or `.wf1` files.
- Move files out of `references/` — those are read-only history.
