# next_session.md

Orientation for the next session. Read [CLAUDE.md](CLAUDE.md) for the
architectural rules of engagement and [DESIGN.md](DESIGN.md) for the
longer story; this file is just the operating cheat-sheet and TODO list.

---

## Where we left off

**SIBYL is a working end-to-end pipeline.** Live data flows from
FRED + RBA + ABS + WorldBank + BoM into `sibyldata`, gets pivoted /
spliced / Chow-Lin'd / formula-derived into a MARTIN-shape database,
solved by `martin::solve_martin()` against the vendored bimets model,
optionally adjusted by an LLM via `judgement`, and rendered as a
Quarto report.

Status as of the last commit:

| Item | Status |
|---|---|
| Test suite | **365 pass, 0 fail, 15 skip** across the 4 packages |
| Pipeline `tar_make()` (live default) | 15/15 targets, ~6m 50s cold (live data fetch dominates) |
| Regression test (`solve_martin` vs canonical bimets pipeline) | bit-identical (max \|diff\| = 0) on headline aggregates |
| Live database vs fixture coverage | `raw_database` has 248 vars after merge; covers **100 %** of the fixture's 205 vars (live data + dummies/scalars + fixture fallback for the long-history series) |
| Round report | renders to `reports/round.html` |

The 15 skips are all intentional — live-API tests that require keys
(FRED_API_KEY, ANTHROPIC_API_KEY) that aren't required for CI.

---

## How to run things

From the project root:

```sh
# One-shot setup after fresh clone — bootstraps renv + installs deps
just init

# Run all package tests
just test

# Test just one package (faster)
just test-one sibyldata     # or martin / judgement / nowcast

# Run the full targets pipeline
just pipeline               # = Rscript -e 'targets::tar_make()'

# Render the report after the pipeline runs
just report

# Visualise the pipeline DAG
just pipeline-graph
```

Quick test from R:

```r
suppressPackageStartupMessages({
  for (p in c("judgement","martin","nowcast","sibyldata")) {
    pkgload::load_all(file.path("packages", p), quiet = TRUE)
  }
})
devtools::test("packages/sibyldata")
```

### Live-data smoke (5 min)

[scripts/live_integration_smoke.R](scripts/live_integration_smoke.R) is
the canonical end-to-end check against real ABS / RBA / FRED:

```sh
FRED_API_KEY=... Rscript scripts/live_integration_smoke.R
# Report lands at scripts/output/live_integration_report.txt
```

Most of the 5 minutes is ABS downloads (cached after the first hit per
vintage).

---

## API keys and environment

| Key | Used by | Required for |
|---|---|---|
| `FRED_API_KEY` | `sibyldata::fetch_fred()` | live FRED fetches + 2 sibyldata tests |
| `ANTHROPIC_API_KEY` | `judgement` LLM functions | live LLM round-trip + 3 judgement tests |
| `QUANDL_API_KEY` | (legacy, deprecated; readrba replaces it) | nothing — safe to leave unset |

Keys live in `.Renviron` (gitignored). See [.Renviron.example](.Renviron.example)
for the template. R reads `.Renviron` automatically at session start.

If you don't have keys, *everything still works* — affected tests skip,
and `propose_adjustments()` falls back to an empty `adjustment_list()`
in `_targets.R` so the pipeline still completes.

---

## Quarto

A portable Quarto 1.6.43 was installed under `~/.local/quarto/`
during the wiring session. Add to PATH for renders:

```sh
export PATH="$HOME/.local/quarto/bin:$PATH"
```

Or install system-wide with `brew install --cask quarto` (needs sudo).
The pipeline's `round_report` target soft-skips with a one-line message
if Quarto isn't on PATH.

---

## What's next — in priority order

These are the items left over from the last autonomous session,
ranked by leverage. Pick whichever you have appetite for; each is
independent.

### A. Live-data coverage push — DONE

The pipeline now defaults to `data_source = "live"` and solves
end-to-end. Done items:

1. ~~**Dummy series**~~ **DONE.** 41 dummy rows via
   [`apply_dummies()`](packages/sibyldata/R/dummies.R) +
   [dummies.csv](packages/sibyldata/inst/extdata/dummies.csv). Kinds
   covered: `pulse` (22), `tristate` (1, D_OLYX), `range_*` (5),
   `trend_carry` (5), `counter_carry` (8). Each bit-identical to
   the bundled fixture in
   [test-dummies.R](packages/sibyldata/tests/testthat/test-dummies.R).

2. ~~**Scalars**~~ **PARTIAL/DONE.** Only `PI_TARGET = 2.5` was
   actually needed — every other scalar in `modify_data.prg:694-713`
   is inlined as a literal in `MARTINMOD_AF.txt` (e.g. `2 * LURGAP`
   for the NCR Taylor Rule is `TR_LURGAP`) and not referenced by
   name.

3. ~~**Flipping the default to `data_source = "live"`**~~ **DONE.**
   `update_data()` now defaults to `sources = "all"` with
   `tolerate_failures = TRUE` (a flaky ABS run warns and continues
   rather than killing the pipeline). `_targets.R`'s live branch
   calls [`sibyldata::merge_with_fallback()`](packages/sibyldata/R/merge.R)
   against `martin::read_fixture()` so series with shorter live
   histories than MARTIN's behavioural-equation TSRANGEs get the
   fixture's long history.

Punted from this session — left as follow-ups below:

- **IAD weights** (`IAD_W_C/I/GI/GC/X`) — not scalars; they're
  time-varying annual series interpolated from input-output omega
  tables ([io_calcs.prg:315-740](references/MARTIN-master/Programs/io_calcs.prg)).
  Currently served from the fixture via `merge_with_fallback`.
  Proper port is ~½ session.
- **`IBCR` + chain** (RBR, IBNDRA, IBCTR, IBNDR) — IDENTITY in the
  model file ([MARTINMOD_AF.txt:655-656](references/bimets-main/MARTINMOD_AF.txt))
  with a chain of dependencies. Currently served from the fixture.
  Porting cleanly means adding the whole chain.

### B. State-space estimation port (~1 session)

The five unobserved trends (TDLLA, TDLLPOP, TDLLHPP, PI_E, TLUR,
RSTAR) come from EViews state-space models in
[references/MARTIN-master/Programs/](references/MARTIN-master/Programs/)
(`pistar.prg`, `nairu.prg`, `rstar.prg`). Until ported, sibyldata
splices them from `martin_public.wf1` (which we vendor in
`references/`). Port via the `KFAS` R package.

Until this lands, `_targets.R` and the live smoke both depend on
hybrid (live + fixture) databases for the trend variables.

### C. Nowcast monthly bridge equations (~½ session)

`nowcast::nowcast_handover()` is currently univariate ARIMA/ETS per
variable. The "deliberately simple" v0 recovers 82 % of headline
aggregates within 5 % mean relative error against the fixture. Real
improvement would come from monthly bridge equations using leading
indicators (LFS, retail trade, building approvals, business
indicators). The signature is already there:

```r
nowcast_handover(database, h = 2, method = "arima")
```

Add `method = "bridge"` that pulls monthly indicators from sibyldata
and regresses quarterly outcomes on contemporaneous monthly indicator
averages.

### D. Catalogue gap items

A handful of derived rows still can't materialise because their
inputs aren't in the catalogue:

- **`LURGAP`** — needs `TLUR` (NAIRU). Set formula to `LUR - TLUR`
  once TLUR is catalogued.
- **`NBRSP`** — needs `NBR` (which now comes from the splice handler;
  derived formula `NBR - NCR` should work but needs the row added).
- **`PAE`** — needs `LHPP` (hours per person). The legacy code
  computes LHPP as `hours / le * 3` then `lhpp = hours_hist / le_hist`
  backcast.

### E. `fetch_oecd`

For trading-partner-weighted world variables (WY, WP, WPX) instead
of the current FRED US proxies. Lowest priority — proxies work.

---

## File map — where to look

```
packages/
├── sibyldata/
│   ├── R/
│   │   ├── catalogue.R          ← series_catalogue() accessor
│   │   ├── update_data.R        ← top-level update_data() + to_martin_database()
│   │   ├── fetch_fred.R         ← live FRED via fredr
│   │   ├── fetch_rba.R          ← live RBA via readrba
│   │   ├── fetch_abs.R          ← live ABS via readabs
│   │   ├── fetch_worldbank.R    ← bundled CMO xlsx
│   │   ├── fetch_bom.R          ← live BoM SOI plaintext
│   │   ├── fetch_other.R        ← (empty file; markers for moved fns)
│   │   ├── transformations.R    ← apply_level_from_pct / splices / chowlin / PIM
│   │   ├── derived.R            ← evaluate_derived_formula / add_derived_series
│   │   ├── extend_exogenous.R   ← future-horizon exogenous extension
│   │   └── cache.R              ← parquet cache by (source, vintage)
│   └── inst/extdata/series_catalogue.csv   ← 163 rows / 49 formulas
│
├── martin/
│   ├── R/
│   │   ├── load_martin.R        ← LOAD_MODEL / LOAD_MODEL_DATA / ESTIMATE wrapper
│   │   ├── solve_martin.R       ← SIMULATE wrapper + residual-decay extension
│   │   ├── to_constant_adjustment_list.R  ← bridge to bimets ConstantAdjustment
│   │   ├── read_fixture.R       ← reads bundled MARTINDATA xlsx
│   │   ├── equation_catalogue.R ← LLM-facing equation menu
│   │   └── utils.R              ← extend_residual_with_decay, bimets warning muffler
│   └── inst/extdata/
│       ├── MARTINMOD_AF.txt              ← canonical model file (frozen coefficients)
│       ├── MARTINMOD.txt, MARTINMOD_EST.txt  ← alternative variants
│       ├── martin_data_fixture.xlsx      ← frozen MARTINDATA snapshot
│       └── equation_catalogue.csv        ← 70 equations, adjustable flag, plain English
│
├── judgement/
│   ├── R/
│   │   ├── adjustment.R         ← S3 class + validator + expand_adjustments
│   │   ├── quarter.R            ← yyyyQq parsing
│   │   ├── propose_adjustments.R ← LLM call + review_and_approve
│   │   ├── describe_projection.R ← LLM call + compare_narrative_to_description
│   │   └── llm_helpers.R        ← prompt construction, schemas
│
└── nowcast/
    └── R/
        ├── handover.R           ← curated handover_variables()
        ├── conversion.R         ← bimets ↔ tsibble helpers
        └── nowcast.R            ← fable-based univariate forecasts + splice

references/
├── MARTIN-master/   ← EViews / R legacy implementation (read-only)
└── bimets-main/     ← the bimets MARTIN port martin is built on

scripts/
├── _init.R                      ← renv + deps bootstrap
├── capture_bimets_reference.R   ← debugging aid for the regression test
└── live_integration_smoke.R     ← the live-data end-to-end smoke test

_targets.R                       ← end-to-end pipeline (15 targets)
reports/round.qmd                ← Quarto round report
DESIGN.md                        ← longer architectural story
CLAUDE.md                        ← context for sessions
```

---

## Gotchas

- **bimets is case-sensitive.** All `martin_var` values in the
  catalogue and all keys in the MARTIN database must be UPPERCASE.
  We had a bug for several sessions where legacy lowercase names
  (`rc`, `gi`, `ngi`) wouldn't have matched MARTIN's `RC`, `GI`,
  `NGI`. Fixed in the last autonomous session.

- **MARTINMOD_AF.txt warns "outdated BIMETS version".** Harmless —
  the vendored .txt was authored with an older bimets release and
  has no version stamp. Muffled surgically in `martin::utils.R`'s
  `.suppress_bimets_version_warning()`.

- **bimets warns "NaNs produced" during ESTIMATE.** Also harmless
  — comes from computing the SER on imposed-coefficient (`c1=1`)
  equations where the SSR is ≈ 0 to numerical precision. Don't
  blanket-suppress (it's a real bimets warning).

- **Live ABS / RBA series often have shorter history than the
  fixture.** When merging live + fixture for an integration solve,
  prefer the fixture for series with longer history — see
  `scripts/live_integration_smoke.R` for the merge logic. Otherwise
  the model's behavioural-equation TSRANGEs (some going back to
  1959) won't be satisfied.

- **The PH backward splice was a real find.** Live ABS housing
  prices only go back to ~2002, but the ID equation needs
  `RPH = PH / PTM` back to 1987. PH ← PH_OLD backward splice fixes
  it. Pattern: any series with a deprecated legacy companion in
  `references/MARTIN-master/Programs/modify_data.prg` probably
  needs a similar splice rule.

- **The `_targets/` directory is gitignored.** Pipeline state is
  per-machine. To re-run from scratch: `targets::tar_destroy()`.

- **Quarto must be on PATH** at `tar_make()` time, not just when
  the report target runs — `tar_quarto()` (and our `tar_target` shim)
  probe for it eagerly. The shim soft-skips if absent.

- **The hardcoded FRED key in scripts is from import_data.prg.**
  Both `scripts/capture_bimets_reference.R` and
  `scripts/live_integration_smoke.R` reference it via env var, never
  hardcode it. The legacy import_data.prg has a hardcoded
  `%FRED = "..."` — that's institutional history, not a current
  pattern.

---

## What was committed last

See `git log`. The initial commit was everything together (this was
a no-git project for many sessions until the wrap-up commit). The
follow-up commit adds:

- 41 dummy rows + 1 scalar row to the series catalogue
- `apply_dummies()` and `apply_scalars()` handlers wired into
  `to_martin_database()`
- 9 new test files asserting each dummy kind bit-matches the
  bundled fixture
- Description fix on the existing `D_OLY` row (the pulse is at
  2004Q4, not 2000Q4 as the original placeholder description said)
