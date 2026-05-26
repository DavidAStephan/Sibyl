# DESIGN.md

Longer-form thinking on what SIBYL is, why it's shaped this way, and how the
four modules fit together. CLAUDE.md is the cheat sheet; this is the
discussion.

## Motivation

A central-bank forecast round consists of roughly:

1. Update the data — pull what's been released since last round, vintage it,
   reconcile against existing series.
2. Nowcast / nearcast — estimate Q+0 and Q+1 for the variables the macro model
   needs as a handover, since those quarters aren't fully observed.
3. Solve the macro model — feed the nowcasts and exogenous paths in, let the
   model extend the projection out to the medium term where cyclical gaps close
   and steady-state relationships dominate.
4. Apply judgemental adjustments — the model doesn't know about an oil shock, a
   fiscal package, a credit crunch, a new tariff. Analysts add "add-factors"
   to specific behavioural equations to nudge the model toward the world they
   actually see.
5. Iterate — re-solve, compare to baseline, discuss in committee, refine.
6. Write the round up — prose describing what changed and why.

Almost all of steps 1–3 and most of step 4 is mechanical. The judgement that
isn't mechanical — *why* the output gap should stay open longer this round, *how*
a fiscal announcement should propagate through the model — lives in human
conversation, and currently exits that conversation as add-factor numbers
typed into a spreadsheet. The translation from narrative to numbers, and from
solved numbers back to narrative, is exactly the part LLMs are good at.

SIBYL automates 1–3 and provides scaffolding for step 4 in which the LLM is
a translator and drafter, never a forecaster.

## The four modules

### `sibyldata` — the data pipeline

Wraps `readabs`, `readrba` (Matt Cowgill's package), `fredr`, and the `OECD`
package into a single `update_data()` function. Returns tidy panels with
**vintage tracking**: every row carries `(series_id, date, value, vintage,
source)` so a re-run on a fixed vintage produces identical output.

Storage is parquet via `arrow`, cached locally under `data/cache/`. Each
external source has its own subdirectory; pulls are content-addressed so
re-pulling a vintage is cheap.

The ABS / RBA / FRED series-ID → MARTIN-variable mapping is shipped as a
versioned tibble in `sibyldata` (lifted from the rename block in the legacy
[import_data.prg](references/MARTIN-master/Programs/import_data.prg)). A test
verifies every MARTIN variable required by `martin::solve_martin()` has a
mapping.

`sibyldata` subsumes the public-data parts of MARTIN-master's
`import_data.prg` and the public-data splicing/backcasting in
`modify_data.prg`. It does **not** read RBA workfiles or internal series.

### `nowcast` — bridge equations for Q+0 and Q+1

The variables MARTIN needs as a handover (real GDP, unemployment, inflation,
the cash rate, exchange rates, commodity prices) are not fully observed for
the current and next quarter. `nowcast` estimates them.

Deliberately simple: we want defensible, not state-of-the-art. Likely just
`fable` with a small set of bridge equations using monthly indicators (labour
force survey, retail trade, building approvals, business indicators).

Returns a tidy tibble of `(variable, quarter, central, lower, upper)` that
`martin::solve_martin()` consumes as starting values.

### `martin` — the macro model

Wraps the `bimets` implementation of MARTIN. The vendored model files live
in [packages/martin/inst/extdata/](packages/martin/inst/extdata/):

- `MARTINMOD_AF.txt` — default. Each equation is `BEHAVIORAL>` but with
  `RESTRICT> c1=1`, so it's mathematically an identity with frozen EViews
  coefficients. The `bimets` `ConstantAdjustment=` argument is the
  add-factor channel.
- `MARTINMOD.txt` — pure-identity equivalent (same coefficients, no
  behavioural shell).
- `MARTINMOD_EST.txt` — true behavioural form, for the day we re-estimate.

The default for v0 is `MARTINMOD_AF.txt` with frozen coefficients. Re-estimation
is gated behind a future flag.

The public surface is small:

```r
solve_martin(
  database,      # tidy tibble or named list of ts: starting values for all model vars
  adjustments,   # list of adjustment objects (judgement::adjustment_list)
  horizon,       # c(start_yyyyq, end_yyyyq)
  coefficients = c("frozen", "reestimated"),  # frozen for v0
  scenario      = "baseline"
) -> projection_tbl
```

`projection_tbl` is a long tidy tibble of `(variable, quarter, value,
scenario, projection_id)`, with attributes recording the database vintage,
the adjustment list applied, and the bimets convergence diagnostics.

A frozen MARTINDATA fixture is shipped in `inst/extdata/` so the regression
test (see below) is deterministic and does not need `sibyldata` to be live.

### `judgement` — the LLM layer

Two main public functions:

```r
propose_adjustments(
  narrative,        # character string from a human
  baseline,         # the baseline projection_tbl
  context,          # historical add-factor magnitudes, equation catalogue
  model = "claude-opus-4-7"
) -> adjustment_list

describe_projection(
  projection,       # projection_tbl from solve_martin()
  baseline,         # the baseline projection_tbl
  narrative,        # the narrative that produced the adjustments
  model = "claude-opus-4-7"
) -> character     # prose
```

Both use `ellmer` with structured outputs via `type_object()`. The
LLM never sees raw bimets output — it always sees tidy tibbles. Every
proposed adjustment is wrapped in the `adjustment` S3 class, validated, and
shown to the human as a table before any `solve_martin()` call.

The LLM is given:

- The **equation catalogue** ([packages/martin/inst/extdata/equation_catalogue.csv](packages/martin/inst/extdata/equation_catalogue.csv)) —
  the menu of MARTIN equations it's allowed to adjust, with plain-English
  descriptions, sector groupings, typical add-factor magnitudes, and
  transmission channels.
- **Historical add-factor context** — past rounds' adjustments and their
  rationales, so the LLM can calibrate magnitudes ("a 0.2 percentage-point
  add-factor on PTM is reasonable; a 2 percentage-point one is not, unless
  the narrative explicitly calls for an extreme shock").
- The **narrative** — the human's words.

## The add-factor schema

Add-factors are the **central data type** of SIBYL. They are the contract
between human language, the LLM, MARTIN, and the round report.

```r
adjustment(
  equation,        # character, MARTIN equation code (e.g. "PTM")
  horizon,         # tsibble or yearquarter vector
  value,           # numeric vector same length as horizon
  tail = c("decay_50", "carry", "zero"),  # how beyond-horizon cells are filled
  rationale,       # character — the why
  channel,         # character — the chain of downstream variables (e.g. "PTM → P → PC")
  expected_effect, # character — what the adjustment should do (for round-trip check)
  confidence = c("high", "medium", "low"),
  owner,           # who proposed it
  round_id,        # which round this belongs to
  source = c("human", "llm")   # was this proposed by a human or by the LLM
)
```

The `tail` field codifies the EViews `_a = _a(-1) * -0.5` convention from
[references/MARTIN-master/Programs/solve_model.prg](references/MARTIN-master/Programs/solve_model.prg):
`"decay_50"` reproduces that exact behaviour, `"carry"` holds the last value
forward, `"zero"` truncates.

`adjustment_list` is a list of `adjustment` objects. Numeric expansion onto
a continuous quarter range (applying each adjustment's horizon values and
tail rule, summing equation-wise collisions) happens in
`judgement::expand_adjustments()` — no bimets dependency. The thin
bimets-shape conversion `martin::to_constant_adjustment_list()` wraps the
expander's output in `bimets::TIMESERIES` objects, ready for
`bimets::SIMULATE(..., ConstantAdjustment = ...)`. The split keeps the
expansion logic testable in isolation and limits bimets coupling to one
package.

## The round-trip consistency check

This is the most important structural feature of SIBYL. The full path is:

1. Human writes a narrative.
2. LLM proposes `adjustment_list` (with rationales and `expected_effect`),
   informed by a pre-computed **sensitivity matrix** that shows the
   propagation of a standardised unit shock on each adjustable equation.
3. Human reviews the proposal as a table — accepts, edits, or rejects.
4. `martin::solve_martin()` produces a projection.
5. LLM reads the projection and (deliberately blind to the narrative)
   drafts a description of how the projection differs from baseline.
6. A second LLM step compares narrative against description; if any
   claim disagrees, an automated **refinement loop** re-prompts the
   LLM with the audit feedback, capped at three iterations.
7. A **diagnostic classifier** (`diagnose_audit()`) labels each
   disagree claim as either a `translation_gap` (wrong equation or
   magnitude — the loop should fix it) or a `model_response`
   (narrative is over-constrained against MARTIN's structure — the
   forecaster needs to accept the trade-off or add a cancelling AF).

The check is mechanical (compare expected_effect to actual change) and
narrative (does the LLM's description match the human's narrative). Both
are surfaced in the round report. **See [docs/llm_layer.md](docs/llm_layer.md)
for the full implementation walkthrough with a worked example.**

## Why public data only

- The reference repos demonstrate that MARTIN can be run on public sources
  (FRED, ABS, RBA's public tables, World Bank commodities, BoM). The data
  isn't perfect — some series use US proxies (see the
  [README of MARTIN-master](references/MARTIN-master/README.md)) — but it's
  sufficient to demonstrate the workflow.
- Internal-RBA series would lock SIBYL inside the RBA and make it useless as a
  research artefact.
- The LLM never sees internal information it shouldn't, by construction.

## What's explicitly out of scope

- A UI. Quarto reports are the output format.
- A replacement for the EA's judgement processes. SIBYL is an exploration
  artefact, not a production system.
- Internal-RBA data integration.
- Re-implementing the EViews state-space estimation of unobservables
  (NAIRU, RSTAR, PI_E) for v0. We'll lift the published values via the
  `_MARTIN` splice and revisit later.
- Re-estimating MARTIN coefficients for v0. We freeze the values shipped in
  `MARTINMOD_AF.txt` and revisit once the rest of the pipeline is stable.
- Probabilistic / stochastic projections. SIBYL produces a single solved path
  per scenario, not a fan chart.

## Relationship to the reference repos

`references/MARTIN-master/` and `references/bimets-main/` are kept in-tree as
read-only references.

- `MARTIN-master/` (EViews + R) is the **canonical source for the equations
  themselves, the data flow, and the splicing/backcasting recipes**. SIBYL
  does not lift any EViews code, but the data manipulation logic in
  [modify_data.prg](references/MARTIN-master/Programs/modify_data.prg) and the
  series-ID map in [import_data.prg](references/MARTIN-master/Programs/import_data.prg)
  are the templates for `sibyldata`. The English equation descriptions in
  [equations.prg](references/MARTIN-master/Programs/equations.prg) seed the
  equation catalogue the LLM sees.
- `bimets-main/` is the **R implementation that SIBYL's `martin` package is
  built on**. The model definition files (`MARTINMOD_AF.txt`, etc.) are
  vendored with attribution. The driver pattern
  ([BIMETS_MARTIN_LOAD.R](references/bimets-main/BIMETS_MARTIN_LOAD.R)) is the
  template for `solve_martin()`.

The regression test in
[packages/martin/tests/testthat/test-regression-against-bimets.R](packages/martin/tests/testthat/test-regression-against-bimets.R)
asserts SIBYL's `solve_martin()` produces the same outputs as the bimets
reference, given the bundled `MARTINDATA_XLSX` fixture and no adjustments.

## What's next (the work this scaffolding sets up)

In order:

1. ✅ Adjustment S3 class in `judgement` (constructor, validator, print,
   `expand_adjustments()`) with tests.
2. ✅ `martin::load_martin()`, `solve_martin()`, `read_fixture()`,
   `to_constant_adjustment_list()` against the bundled fixture; regression
   test computes the bimets reference inline so divergence is caught on every
   test run (`max |diff| = 0` against canonical bimets).
3. ✅ `sibyldata::series_catalogue` (105 rows covering ABS / RBA / FRED /
   World Bank / BoM with metadata + derivation formulas), parquet cache
   (`cache_read`/`cache_write` keyed by `(source, vintage)`), live
   fetchers for **FRED** (`fetch_fred`), **RBA** (`fetch_rba` via
   `readrba::read_rba`), **ABS** (`fetch_abs` via `readabs::read_abs`),
   **World Bank** (`fetch_worldbank` reading the bundled CMO xlsx), and
   **BoM** (`fetch_bom` parsing the SOI plaintext table).
   `update_data()` dispatcher routes through all five; `to_martin_database()`
   pivots the `direct` slice. Catalogue cross-checks against
   `martin::equation_catalogue()` so a gap in either side trips a test.
   The catalogue now carries an R-expression `formula` column for derived
   rows; `add_derived_series()` evaluates each formula in a fixed-point
   loop against the post-direct database, so PC, PG, PM, TOT, NHA, NHNW
   and ~20 other catalogue-derived variables materialise automatically.
   Cross-dependencies (HCOE needs PC; NHNW needs NHA needs NHNFA) resolve
   correctly. `to_martin_database()` reports the remaining skipped
   variables grouped by reason (`derived_no_inputs`,
   `derived_no_formula`, `other_transforms`). All catalogue `martin_var`
   values are upper-case to match bimets MARTIN's case-sensitive
   convention.
   **All transformation logic from
   `references/MARTIN-master/Programs/modify_data.prg` is now implemented**
   as handlers in
   [packages/sibyldata/R/transformations.R](packages/sibyldata/R/transformations.R):
   - `apply_level_from_pct()` — PTM, P cumulated from 1982Q1 bases
     (29.8345 and 100 respectively).
   - `apply_splices()` — NCR (backward via NCR_HIST), NBR (forward via
     NBR_SPLICE), PH (backward via PH_OLD) per a hardcoded registry.
   - `apply_chowlin()` — IBRE, NIBRE, KIBRE, KID, KTOT, KOTC from annual
     ABS via `tempdisagg::td()`, using quarterly indicators
     (IBRE_CAPEX, NIBRE_CAPEX) when available.
   - `apply_pim()` — KV (stocks level) from V via perpetual inventory
     from a 1980Q1 base of 134865.
   - Plus the `add_derived_series()` formula evaluator from the previous
     step, now with **49 derived formulas** including HDY, HOY, HNW, G,
     NG, DPFD, NDPFD, DFDX, RPH, NULC, RULC, RULCY, LF.
   The catalogue grew to **163 rows** including sub-component rows
   (XRE_*, XM_*, XO_*) sourced from ABS 5302 BoP tables.

   **Live integration verified:** [scripts/live_integration_smoke.R](scripts/live_integration_smoke.R)
   pulls live data from FRED + RBA + ABS + WorldBank + BoM, runs the
   full pipeline, and feeds the resulting hybrid (live + fixture for
   uncovered series) into `martin::solve_martin()`. End-to-end solve
   succeeds: 5460 rows, 156 vars, headline aggregates sensible (Y =
   AUD 584b at 2018Q3, LUR = 4.93 %). Live pipeline now covers 113 of
   the fixture's 205 MARTIN variables (55 %); remaining 92 are dummies
   (D_AFC*, D_GST*, etc. — deterministic from dates), IAD weights
   (scalars from IO tables), and state-space estimates (TDLLA, TDLLPOP,
   TDLLHPP, PI_E, TLUR, RSTAR — still spliced from `martin_public.wf1`).

   **Outstanding for sibyldata:** automated construction of dummy series
   from a date-rule registry (~20 vars); IO-weight scalars (from the
   bundled `io_calcs.prg`); state-space estimation port for the
   trend/NAIRU/r-star series (KFAS); `fetch_oecd` for trading-partner-
   weighted world variables (currently FRED-US-proxy).
4. ✅ `nowcast::nowcast_handover()` and `splice_handover()`. Univariate
   `fable::ARIMA()` / `ETS()` / `NAIVE()` per handover variable, with
   `bimets <-> tsibble` conversion helpers and ragged-edge handling
   (each variable forecasts h quarters past its own last observed value).
   `handover_variables()` curates the headline set. Full chop-and-recover
   evaluation against the bundled fixture: ARIMA, h=2, recovers 82% of 44
   handover variables within 5% mean relative error. **Outstanding:** monthly
   bridge equations using LFS / retail-trade / building-approvals as
   leading indicators (v0.1).
5. ✅ `judgement::propose_adjustments()` — ellmer + structured output via
   `type_object` + `type_array`. Returns a validated `adjustment_list`,
   with every adjustment cross-checked against
   `martin::equation_catalogue()` (rejects identities and unknown codes).
   `describe_projection()` drafts free-form prose grounded in a
   compact diff-from-baseline summary.
   `compare_narrative_to_description()` is the round-trip auditor —
   structured `(claim, status, note)` plus an `overall_match` attribute.
   `review_and_approve()` writes proposals to CSV, blocks for human edits,
   reads back, reconstructs adjustments (preserving non-editable metadata).
   Tests: 87 unit tests using a fake-chat fixture + 3 live tests against
   Anthropic Claude (`claude-haiku-4-5`, skip when `ANTHROPIC_API_KEY`
   unset).
6. ✅ End-to-end pipeline wired in [_targets.R](_targets.R) — 15 targets
   from data through report. Runs end-to-end in fixture mode without API
   keys: missing `ANTHROPIC_API_KEY` ⇒ empty adjustment list; missing
   Quarto CLI ⇒ soft-skip render. Round-report Quarto template at
   [reports/round.qmd](reports/round.qmd) consumes pipeline outputs via
   `tar_load()`, with the working directory pinned to the project root via
   `knitr::opts_knit` so the `_targets/` store resolves correctly. Manual
   render: `quarto render reports/round.qmd`; targets-driven render:
   `targets::tar_make(names = "round_report")` or `just pipeline`.
7. ✅ Future-horizon support — both halves now implemented:
   - **Residual decay** in `martin::extend_residual_with_decay()`:
     replay AFs extended forward via the EViews `_a = _a(-1) * -0.5`
     convention.
   - **Exogenous-path extension** in `sibyldata::extend_exogenous()`:
     forward-extends any variable in the database to a target quarter
     via `"carry"` / `"constant"` / `"linear"` modes. Composes cleanly
     with `solve_martin()` — verified by an integration test that
     extends the fixture forward and solves 8 future quarters.
