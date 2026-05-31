# next_session.md

Orientation for the next session. Read [CLAUDE.md](CLAUDE.md) for the
architectural rules of engagement and [DESIGN.md](DESIGN.md) for the
longer story; this file is the operating cheat-sheet plus the active
TODO list.

---

## Where we left off

**SIBYL is a working end-to-end pipeline with a fully agentic LLM round.**
Live data flows from FRED + RBA + ABS + WorldBank + BoM into `sibyldata`,
gets pivoted / spliced / Chow-Lin'd / formula-derived into a MARTIN-shape
database, solved by `martin::solve_martin()` against the vendored bimets
model, adjusted by the LLM judgement layer with a pre-computed
sensitivity matrix + iterative refinement loop + round-trip audit, and
rendered as a Quarto report.

Status as of the last commit:

| Item | Status |
|---|---|
| Test suite | 553 pass, 0 fail (~11 skip; live-API tests that need keys) |
| Pipeline `tar_make()` (live default) | 21/21 targets, ~8m cold (live data fetch + sensitivity matrix dominate) |
| Regression test (`solve_martin` vs canonical bimets pipeline) | bit-identical (max \|diff\| = 0) on headline aggregates |
| Live database vs fixture coverage | every fixture var is populated, but via a mix of source classes — read the provenance manifest (`database_provenance(db)`: `live` / `fixture_fallback` / `vendored_wf1` / `proxy` / `dummy` / `derived`), not a single "100%" headline. Live path supplies ~113 of 205; the rest are dummies/scalars/state-space-wf1/proxy/fixture-fallback. "vintage" is a fetch-date stamp, not point-in-time. |
| Nowcast handover | bridge_monthly default on growth rates (RC←RT, Y←HOURS, LE←LE); ARIMA fallback for unmapped targets. Committed backtest: bridge MAPE 9.8% / 82% within 5% on the fixture (`packages/nowcast/inst/eval/handover_backtest.md`) |
| End-to-end LLM round (with `ANTHROPIC_API_KEY`) | Sensitivity matrix → propose (Sonnet 4.6) → solve → describe (Haiku) → audit (Haiku) → refine if disagree, repeat; best-iter selection. `diagnose_audit()` separates translation gaps from inevitable MARTIN endogenous responses. Multi-narrative coherence test confirms distinct equations per narrative. |
| Round report | renders to `reports/round.html` including "narrative coherence diagnostics" |

---

## How to run things

From the project root:

```sh
just init                       # one-shot bootstrap after fresh clone
just test                       # all package tests
just test-one judgement         # one package
just pipeline                   # tar_make()
just report                     # render reports/round.qmd
just pipeline-graph             # DAG visualisation
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

Live-data smoke (5 min):

```sh
FRED_API_KEY=... Rscript scripts/live_integration_smoke.R
# Report at scripts/output/live_integration_report.txt
```

---

## API keys and environment

| Key | Used by | Required for |
|---|---|---|
| `FRED_API_KEY` | `sibyldata::fetch_fred()` | live FRED fetches + 2 sibyldata tests |
| `ANTHROPIC_API_KEY` | `judgement` LLM functions | live LLM round + 3 judgement tests |

Keys live in `.Renviron` (gitignored). See `.Renviron.example`. If you
don't have keys, *everything still works* — affected tests skip, and
`propose_with_refinement()` falls back to an empty `adjustment_list()`
in `_targets.R` so the pipeline still completes.

Quarto 1.6.43 was installed under `~/.local/quarto/`. Add to PATH:

```sh
export PATH="$HOME/.local/quarto/bin:$PATH"
```

Or `brew install --cask quarto`. The `round_report` target soft-skips
if Quarto isn't on PATH.

---

## What to pick up next

Ranked by leverage. Each item is independent — pick whichever you have
appetite for.

### 1. Joint MLE for state-space trends (~1 session)

The previous session's six work items took out HP-filter initial
states + the stronger Okun coefficient on `fit_rstar_kfas_full`. The
remaining lever — and the biggest expected accuracy win — is **joint
MLE**: a custom `optim()` likelihood that varies *both* structural
parameters and variances together.

Current state of accuracy vs fixture:

| Estimator | cor | bias | notes |
|---|---|---|---|
| `fit_rstar_kfas` (simple smoother) | 0.97 | small | default; only RSTAR exposed |
| `fit_rstar_kfas_full` | 0.33 | mediocre | exposes YGAP/YPOT/G/Z but smoothed nrate poor |
| `fit_pie_kfas` (faithful 2-state) | 0.93 | -0.32pp | strong; bias likely OK |
| `fit_nairu_kfas` (faithful) | 0.73 | +1.10pp | weaker; bias is the main gap |

For each, the OLS-pre-est step pins the structural params; only
variances enter `fitSSM`. Joint MLE would let `optim()` co-optimize
the most economically meaningful structural params (alpha_1, alpha_3,
beta_1 for RSTAR; gamma_1, gamma_2 for PI_E/TLUR) with the variances,
which previously gave the biggest fidelity gains in rstar.prg's own
EViews implementation.

Tricky bits to handle:

- KFAS's `update_fn` mutates `model` per iteration. Modifying T_arr
  in place (for time-varying structural T) is fine; modifying the
  Z matrix takes a single assignment.
- Bounded params need a logit-style transform so optim() can roam
  unconstrained: e.g. `alpha_1 = 1.5 * plogis(p)` to keep it in [0, 1.5].
- 11+ free params is identifiability-risky on quarterly data;
  consider 5-7 (variances + 2-3 most sensitive structural params).

### 2. TPW: extend to WY (real GDP) and WPX (export price) — ~½ session

`compute_tpw()` + `build_tpw_cpi()` shipped this session — WP is a
working trading-partner-weighted CPI via OECD's monthly prices
dataflow. WY (real GDP) and WPX (export price) need their own OECD
dataflow keys figured out:

- WY: OECD QNA dataflow (`OECD.SDD.NAD,DSD_NAMAIN1@DF_QNA,1.0/...`)
  uses a 13-position SDMX key. The CSV endpoint works (curl confirmed),
  just need to find the right combination of (REF_AREA, FREQ, MEASURE,
  UNIT_MEASURE, ...) for "quarterly real GDP chained volume". OECD's
  SDMX dataflow-structure endpoint lists the dimensions per dataflow:
  ```
  curl 'https://sdmx.oecd.org/public/rest/dataflow/OECD.SDD.NAD/DSD_NAMAIN1@DF_QNA/1.0'
  ```
- WPX: similar story for export price deflators. Probably lives in
  the same QNA dataflow under a different MEASURE.

Once both keys are known, parallel `build_tpw_real_gdp()` and
`build_tpw_export_price()` are one-paste-each from `build_tpw_cpi()`.

After all three TPW series are buildable, the catalogue rows for
WY / WP / WPX can flip `source = "fred"` -> `source = "oecd"` with
a derived-formula layer that does the partner-weighting. The current
hardcoded weights in `tpw_partner_weights()` can also be refreshed
from live ABS 5368.0 data (rolling 3-year average is closer to the
RBA convention than a fixed 2022-24 average).

### 3. Joint-MLE-RSTAR variant validation (~¼ session)

Once joint MLE lands (item 1), confirm the full-port RSTAR's auxiliary
states (YGAP, YPOT, G, Z) are also better-tracked, not just RSTAR
itself. Re-run `scripts/lur_gap_walkthrough.R` and the multi-narrative
test — if YGAP is more stable, the AF channels through more cleanly.

---

## File map — where to look

```
packages/
├── sibyldata/
│   ├── R/
│   │   ├── catalogue.R          ← series_catalogue() accessor
│   │   ├── update_data.R        ← update_data() + to_martin_database()
│   │   ├── fetch_*.R            ← live FRED / RBA / ABS / OECD / WB / BoM
│   │   ├── transformations.R    ← level_from_pct / splices / chowlin / PIM
│   │   ├── derived.R            ← evaluate_derived_formula
│   │   ├── identities.R         ← apply_ibctr() / apply_ibndr_annual()
│   │   ├── monthly_indicators.R ← nowcast_monthly_indicators() for bridges
│   │   ├── state_space.R        ← KFAS ports of PI_E, TLUR, RSTAR + hp_filter
│   │   ├── extend_exogenous.R   ← future-horizon exogenous extension
│   │   └── cache.R              ← parquet cache by (source, vintage)
│   └── inst/extdata/
│       ├── series_catalogue.csv ← 163 rows / 49 formulas
│       ├── iad_weights.csv      ← vendored IO-tables IAD weights
│       └── dummies.csv          ← 41 dummy series definitions
│
├── martin/
│   ├── R/
│   │   ├── load_martin.R        ← LOAD / ESTIMATE / TSRANGE rewriter
│   │   ├── solve_martin.R       ← SIMULATE wrapper + residual decay
│   │   ├── sensitivity_matrix.R ← pre-shock + propagation tibble
│   │   ├── to_constant_adjustment_list.R
│   │   ├── read_fixture.R
│   │   ├── equation_catalogue.R ← LLM-facing equation menu
│   │   └── utils.R
│   └── inst/extdata/
│       ├── MARTINMOD_AF.txt        ← canonical model file
│       ├── martin_data_fixture.xlsx
│       └── equation_catalogue.csv  ← 70 equations, adjustable flag
│
├── judgement/
│   ├── R/
│   │   ├── adjustment.R         ← S3 class + validator
│   │   ├── quarter.R
│   │   ├── propose_adjustments.R ← propose / refine / orchestrator
│   │   ├── describe_projection.R ← blind describer + round-trip audit
│   │   └── llm_helpers.R        ← prompts, schemas, format_sensitivity_text
│
└── nowcast/
    └── R/
        ├── handover.R           ← handover_variables() + bridge_monthly
        ├── conversion.R
        └── nowcast.R

references/
├── MARTIN-master/   ← EViews / R legacy (read-only)
└── bimets-main/     ← the bimets MARTIN port we wrap

scripts/
├── _init.R
├── capture_bimets_reference.R   ← regression-test capture
├── live_integration_smoke.R     ← end-to-end live-data smoke
├── lur_gap_walkthrough.R        ← manual AF demo (LUR -1.6pp closes the gap)
├── end_to_end_round_walkthrough.R  ← manual round demo
├── monthly_bridge_demo.R        ← bridge vs ARIMA comparison
└── multi_narrative_coherence_check.R  ← 3-narrative LLM coherence probe

_targets.R                       ← end-to-end pipeline (21 targets)
reports/round.qmd                ← Quarto round report
app/app.R                        ← Shiny dashboard (just dashboard)
docs/llm_layer.md                ← LLM-judgement walkthrough
docs/dashboard.md                ← dashboard runtime guide
DESIGN.md                        ← longer architectural story
CLAUDE.md                        ← context for sessions
```

---

## Gotchas

- **bimets is case-sensitive.** `martin_var` values + database keys
  must be UPPERCASE.

- **MARTINMOD_AF.txt warns "outdated BIMETS version".** Harmless;
  muffled in `martin::utils.R`'s `.suppress_bimets_version_warning()`.

- **`bimets::ESTIMATE` runs on every `load_martin()`.** MARTINMOD_AF.txt
  has 95 `BEHAVIORAL>` equations; only ~51 carry `RESTRICT> c1=1`, the rest
  impose real cross-coefficient restrictions (`c4+c5+c6+c7=1`, `c4=0.5`, ...)
  with free coefficients that get re-fit. "Frozen" = keep the file's embedded
  2019Q3 `TSRANGE` so the re-fit reproduces the published values; it is NOT
  "load published EViews numbers, skip estimation". `coefficients =
  "reestimated"` + `estimation_end` rewrites that TSRANGE.

- **bimets warns "NaNs produced" during ESTIMATE.** Harmless — comes from
  computing SER on the `c1=1`-restricted equations (the ~51 with that
  restriction) where SSR ≈ 0. Don't blanket-suppress.

- **Live ABS / RBA series often have shorter history than the fixture.**
  `merge_with_fallback()` prefers whichever source has more history.
  Otherwise behavioural-equation TSRANGEs (some back to 1959) fail.

- **The PH backward splice.** Live ABS housing prices only go back to
  ~2002, but the ID equation needs `RPH = PH / PTM` back to 1987.
  Pattern: any series with a deprecated legacy companion in
  `modify_data.prg` probably needs a similar splice rule.

- **`_targets/` is gitignored.** Per-machine state. To restart clean:
  `targets::tar_destroy()`.

- **Quarto must be on PATH** at `tar_make()` time, not just when
  the report target runs. The shim soft-skips if absent.

- **`typical_af_sd` is unreliable for log_diff equations.** It's set
  to 0.1 for PTM's log_diff residual, which means +10pp/quarter
  inflation — catastrophic if the LLM ever interprets it literally.
  The sensitivity matrix uses fixed per-unit-type calibration shocks
  (log_diff=0.001, level=0.05, percent=0.10) and the system prompt
  teaches the LLM to scale those linearly.

- **The describer must NOT see the narrative.** `describe_projection()`
  has a deprecation warning if `narrative` is passed. Otherwise the
  round-trip audit becomes trivially self-satisfied (the describer
  mirrors the narrative regardless of what the projection says).

- **Trend AFs (TLUR, RSTAR) pass through to cyclical variables at
  ~25-40% of their level shift over typical projection windows.** The
  sensitivity matrix now teaches this to the LLM directly; the
  walkthrough script `scripts/lur_gap_walkthrough.R` is the original
  finding.

- **The LLM is non-deterministic on equation choice.** Even with the
  sensitivity matrix, different runs can pick LUR vs TLUR for the
  same narrative. The matrix substantially narrows the gap but
  doesn't eliminate it. The over-correction guard in
  `pick_best_iteration()` is what catches the worst case.

---

## What's been done (active code surface)

For canonical history use `git log`. Major landed workstreams:

- **LLM judgement layer (most recent work):**
  - Sensitivity matrix + threading into propose/refine prompts.
  - Iterative refinement loop with best-iter selection
    (`propose_with_refinement()`).
  - Per-step model overrides (`model_propose` / `model_describe` /
    `model_audit`) — pipeline default is Sonnet 4.6 for propose +
    Haiku for the rest.
  - `diagnose_audit()` classifies disagree claims as `translation_gap`
    vs `model_response` vs `not_addressed`; surfaced in the round
    report's "Narrative coherence diagnostics" section.
  - Few-shot worked examples + variable glossary in the propose prompt.
  - Blind describer + clearer rate-vs-level units in `diff_text`.
  - ellmer shape/factor handling fixes (tibble vs list, factors).
  - Round-trip audit catches narrative-vs-model inconsistencies.
  - `mechanical_audit()` — LLM-independent fidelity gate: checks each
    adjustment's declared `target_variable` / `expected_direction` against the
    realised projection-minus-baseline diff. Run alongside `diagnose_audit()`.
  - Default `adjustment()` tail is **`decay_50`**. Add-factors land on
    equation residuals, and most MARTIN equations are growth-rate /
    first-difference, so a sustained `carry` shock makes the LEVEL diverge
    (a live round with `carry` on LUR drove modelled unemployment negative).
    `decay_50` tapers the shock so a sustained level target CONVERGES; it also
    mirrors the EViews `_a(-1)*-0.5` historical-residual handover rule. `carry`
    remains available for level-residual equations (e.g. the TLUR trend).
  - Add-factor guardrails: `validate_adjustment_bounds()` caps `|value|` per
    unit (`log_diff<=0.02`, `level<=1.0`, `percent<=5.0`/qtr) and horizon
    `<=60` qtrs; override via `options(sibyl.af_ceiling=)` /
    `options(sibyl.af_horizon_ceiling=)`.
  - Human gate restored (design principle #4): `review_and_approve()` defaults
    `interactive = base::interactive()`, writes a review CSV with a hidden
    stable `adjustment_id`, and round-trips the `exogenize` list through a
    sidecar (`paste0(csv_path, ".exogenize")`) so it survives a human edit.

- **Live data + database construction:**
  - Live default (`data_source = "live"` in `_targets.R`); every fixture var
    is populated via `merge_with_fallback()`, but through a mix of source
    classes — see the provenance manifest (`database_provenance(db)`:
    `live` / `fixture_fallback` / `vendored_wf1` / `proxy` / `dummy` /
    `derived`), not a single "100%" number.
  - `to_martin_database()` attaches `attr(db, "provenance")`;
    `classify_provenance()` maps variable names to source classes.
  - 41 dummy series via `apply_dummies()`.
  - IBCR identity chain (IBCTR/IBNDR/IBNDRA/RBR/IBCR) + IAD weights
    vendored from io_calcs output.
  - Backward splices (PH ← PH_OLD; NBR ← F05_FILRLBWAV).
  - `extend_exogenous()` carries exogenous variables past the
    fixture's 2019Q3 cutoff so the horizon can run to 2025Q4.

- **State-space trends (PI_E, TLUR, RSTAR, TDLLA, TDLLPOP, TDLLHPP):**
  - V0 KFAS ports of pistar.prg / nairu.prg / rstar.prg / supply_side.prg.
  - Faithful restorations: PI_E 2-state with AR(1) DL4PTM + GST dummies;
    TLUR with beta/phi/alpha cross-equation terms.
  - `fit_rstar_kfas_full` and `fit_nairu_kfas` use HP-filter
    (lambda=1600) initial-state seeds; `fit_rstar_kfas_full` uses
    Okun beta_1 = -0.5.
  - `fit_rstar_kfas_full` accuracy remains modest (cor 0.33 vs
    fixture's smoothed RSTAR); joint MLE is the next-tier improvement
    (item 1 above).

- **MARTIN solve / re-estimation:**
  - `solve_martin()` with frozen + reestimated coefficient paths
    (TSRANGE rewriter for arbitrary `estimation_end`). Default is **frozen**
    (`estimation_end = NULL`): keep the file's 2019Q3 sample so the re-fit
    reproduces published coefficients. `"reestimated"` is an explicit opt-in.
  - `coefficients = "reestimated"` + `estimation_end = "2025Q2"` re-fits
    across the COVID break (closes the post-COVID gap on NCR/PTM/Y) — opt-in
    only, because it re-estimates over a non-published sample.
  - `solve_martin()` attaches `attr(out, "convergence")` (a NaN/Inf-in-TSRANGE
    guard); `solve_martin_stochastic()` adds opt-in Monte-Carlo bands.
  - `martin::sensitivity_matrix()` pre-solves a per-unit-type
    calibration shock per equation and feeds the result to the LLM
    propose prompt; with `probe_curvature = TRUE` (default) it also solves at
    3x to emit `deviation_3x` / `curvature_ratio` / `linearity_ok` (+ a
    `converged` flag) so deviations aren't scaled linearly through MARTIN's
    non-linearity.
  - Regression test bit-identical to the canonical bimets pipeline (frozen,
    no-adjustment path).

- **Nowcast handover:**
  - ARIMA/ETS default + monthly bridge equations
    (`method = "bridge_monthly"`), all working on **growth rates**, not a
    levels-on-levels regression.
  - Pipeline default is now `bridge_monthly` with the indicator map
    `RC ← RT`, `Y ← HOURS`, `LE ← LE`; ARIMA fallback for unmapped
    targets and fixture-mode runs.
  - `splice_handover(..., overwrite = FALSE)` default fills only NA / newly
    extended forecast cells, protecting observed history.
  - Committed chop-and-recover backtest
    (`packages/nowcast/inst/eval/handover_backtest.R` → `.md`): bridge MAPE
    9.8% (best of bridge/arima/naive), 82% within 5%, 89% within 10% on the
    pre-COVID fixture. Single frozen, in-sample-vintage, short-horizon
    smoke-test, not a forecast benchmark.

- **Data layer:**
  - `fetch_oecd()` single-series SDMX fetcher (CPI confirmed working;
    QNA / export-price keys still TBD — item 2 above).
  - `compute_tpw()` pure-math weighted aggregate + `build_tpw_cpi()`
    opt-in trading-partner-weighted WP build (live OECD round-trip
    verified). `tpw_partner_weights()` returns the canonical CN/JP/
    KOR/USA/IND/NZL/GBR/DEU + OECD_OTHER weight vector.
  - Catalogue derived rows for PAE, NBRSP, LURGAP have proper
    formulas (`NHCOE / (LHPP * LE)`, `NBR - NCR`, `LUR - TLUR`).

- **Documentation:**
  - [docs/llm_layer.md](docs/llm_layer.md) — 500+ line walkthrough of
    the propose / describe / audit / refine loop, the sensitivity
    matrix, `diagnose_audit()`, and a worked example from the live
    pipeline. Read this before touching anything in `judgement/`.
  - [docs/dashboard.md](docs/dashboard.md) — runtime guide for the
    Shiny dashboard (`just dashboard`).
  - Docs truth-up pass: corrected the false "frozen / RESTRICT c1=1 / frozen
    EViews coefficients" description (95 behaviorals, ~51 c1=1, `ESTIMATE`
    re-fits every load, "frozen" = embedded 2019Q3 sample); recorded the
    frozen-by-default coefficient path, the restored human-approval gate, the
    `carry` tail default, the real nowcast backtest number (bridge MAPE 9.8%),
    the provenance-manifest coverage framing, `renv.lock` committed, and the
    new guardrails / linearity probe / `solve_martin_stochastic` /
    `mechanical_audit` / exogenize-round-trip capabilities.

- **Interactive UI:**
  - [`app/app.R`](app/app.R) is a Shiny dashboard for typing a
    narrative and watching the round run. Reuses the cached
    baseline + sensitivity matrix so each click pays only the
    ~2-4 min LLM+solve cost. Five tabs: Chart (plotly facets),
    Adjustments, Description, Audit + diagnostics, Iteration
    history. Launch via `just dashboard`.
