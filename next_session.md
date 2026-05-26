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
| Test suite | 458 pass, 0 fail (~16 skip; live-API tests that need keys) |
| Pipeline `tar_make()` (live default) | 19/19 targets, ~6m 50s cold (live data fetch dominates) |
| Regression test (`solve_martin` vs canonical bimets pipeline) | bit-identical (max \|diff\| = 0) on headline aggregates |
| Live database vs fixture coverage | 100 % of the fixture's 205 vars (live data + dummies/scalars + fixture fallback for long-history series) |
| End-to-end LLM round (with `ANTHROPIC_API_KEY`) | Pipeline includes (a) sensitivity matrix per equation, (b) iterative-refinement loop, (c) best-iter selection. LUR narrative hits magnitude target on iter 1 (LUR -1.28pp realised vs -1.5pp narrative). ~1m32s wall clock cold; ~30s of that is the sensitivity matrix build |
| Round report | renders to `reports/round.html` |

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

### 1. Sensitivity-matrix follow-ups (~½ session)

The matrix is shipping and the LUR narrative converges on iter 1, but
three follow-ups would harden it:

**a) Upgrade propose-step from Haiku → Sonnet 4.6.** Haiku is observed
to occasionally ignore the matrix's "linear scaling" hint and still
guess magnitudes. Sonnet is plausibly more decisive at the same cost
class. One test round to confirm. Change in `_targets.R` →
`refined_round` → `propose_with_refinement(model = "claude-sonnet-4-6")`.

**b) Dynamic shock window.** `sensitivity_matrix()` currently fixes
`shock_start = "2020Q1"` so h+16 lands at 2024Q1 — fine for our
horizon ending 2025Q4. If `estimation_end` ever pushes the horizon
later, h+16 falls outside the projection window and entries get
dropped. Compute `shock_start` dynamically as `horizon[2] - 17 quarters`
so the longest offset always fits.

**c) Distinguish "narrative inconsistent" from "translation error" in
the report.** The LUR narrative's audit flags `disagree` on the
cash-rate / inflation claims, but those are unavoidable MARTIN
responses to a 1.5pp labour-market shock — not translation errors.
Add a "narrative coherence" section to `reports/round.qmd` that
highlights claims marked disagree where the projection effect is in
the expected direction (Taylor Rule cut after looser labour market).
This requires the report to *interpret* the audit, not just print it.

### 2. RSTAR full-port accuracy (~½–1 session)

`fit_rstar_kfas_full` is **stable** on live data (fixed-prior
structural params via `RSTAR_FULL_PARAMS` produce live values in the
plausible [-0.004, 4.805] range), but **accuracy** vs fixture is
mediocre (cor ~ 0.30) — the smoothed nrate state doesn't track the
fixture's RSTAR closely. The simple smoother (`fit_rstar_kfas`,
cor ~ 0.96) remains the default.

Paths to improve full-port accuracy:

- **Joint MLE**: custom `optim()` likelihood that estimates structural
  + variance params jointly (currently the two-step OLS-pre-est +
  fitSSM-on-variances structure leaves structural params at OLS values
  that don't co-optimize with the smoother).
- **Better initial states**: replace the centred-MA proxies with
  actual HP filter (lambda=1600). KFAS's `SSMtrend(degree=2)` with
  the right Q reproduces HP exactly.
- **Stronger Okun coefficient**: beta_1 = -0.3 may be too weak; try
  beta_1 = -0.5 to disentangle ygap from NAIRU more sharply.

Opt-in via `SIBYL_RSTAR_FULL_PORT=TRUE`. Useful right now for the
auxiliary states (YGAP, YPOT, G, Z) that the simple smoother doesn't
expose.

### 3. Faithful state-space accuracy across PI_E / TLUR / RSTAR (~1 session)

The faithful PI_E and TLUR ports trade a few correlation points
against the fixture for closer structural fidelity (PI_E cor ~ 0.8,
TLUR cor ~ 0.8 vs the v0's simpler structures at ~0.9). If accuracy
is the priority, the OLS-pre-est step can be replaced with
EViews-published parameter values (when available) or with joint MLE
across all three trends.

### 4. Nowcast bridges into the pipeline default (~¼ session)

`nowcast::nowcast_handover(method = "bridge_monthly", ...)` works and
the live demo (`scripts/monthly_bridge_demo.R`) shows it lifts
consumption nowcasts +7.4% and GDP +4-5% above ARIMA. But `_targets.R`
still uses the ARIMA default. Switch the handover target to bridge
when monthly indicators are fresher than quarterly ones (or just
always — bridge falls back to ARIMA gracefully when no indicator data
is mapped).

### 5. Catalogue gap items (~¼ session)

A handful of derived rows still can't materialise because their
inputs aren't in the catalogue:

- **`LURGAP`** — needs `TLUR` catalogued (it's currently produced by
  the state-space layer but isn't a catalogue row). Set formula
  `LUR - TLUR` once `TLUR` is in.
- **`NBRSP`** — needs `NBR` (now coming from the splice handler).
  Derived formula `NBR - NCR` should work; just add the catalogue row.
- **`PAE`** — needs `LHPP` (hours per person). Legacy code computes
  `hours / le * 3` then `lhpp_hist = hours_hist / le_hist` backcast.

### 6. `fetch_oecd` for trading-partner-weighted world variables (~½ session)

WY / WP / WPX currently use FRED US proxies. Real OECD trading-partner
weights would be cleaner. Lowest priority — proxies work.

### 7. Multi-round narrative coherence test (~¼ session)

Run three different narratives back-to-back through the pipeline
(sticky inflation, labour-market gap, capex slowdown) and confirm that
(a) the LLM picks distinct equations per narrative, (b) the round
reports are visually distinguishable, (c) the round-trip audits don't
falsely cross-contaminate. Confidence-building rather than feature work.

---

## File map — where to look

```
packages/
├── sibyldata/
│   ├── R/
│   │   ├── catalogue.R          ← series_catalogue() accessor
│   │   ├── update_data.R        ← update_data() + to_martin_database()
│   │   ├── fetch_*.R            ← live FRED / RBA / ABS / WB / BoM
│   │   ├── transformations.R    ← level_from_pct / splices / chowlin / PIM
│   │   ├── derived.R            ← evaluate_derived_formula
│   │   ├── identities.R         ← apply_ibctr() / apply_ibndr_annual()
│   │   ├── state_space.R        ← KFAS ports of PI_E, TLUR, RSTAR, TDLLA, ...
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
└── monthly_bridge_demo.R        ← bridge vs ARIMA comparison

_targets.R                       ← end-to-end pipeline (19 targets)
reports/round.qmd                ← Quarto round report
DESIGN.md                        ← longer architectural story
CLAUDE.md                        ← context for sessions
```

---

## Gotchas

- **bimets is case-sensitive.** `martin_var` values + database keys
  must be UPPERCASE.

- **MARTINMOD_AF.txt warns "outdated BIMETS version".** Harmless;
  muffled in `martin::utils.R`'s `.suppress_bimets_version_warning()`.

- **bimets warns "NaNs produced" during ESTIMATE.** Also harmless —
  comes from computing SER on imposed-coefficient (`c1=1`) equations
  where SSR ≈ 0. Don't blanket-suppress.

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
  - Few-shot worked examples + variable glossary in the propose prompt.
  - Blind describer + clearer rate-vs-level units in `diff_text`.
  - ellmer shape/factor handling fixes (tibble vs list, factors).
  - Round-trip audit catches narrative-vs-model inconsistencies.

- **Live data + database construction:**
  - Live default (`data_source = "live"` in `_targets.R`); 100 %
    fixture-coverage via `merge_with_fallback()`.
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
  - `fit_rstar_kfas_full` stable but accuracy-improvement opportunity
    (item 2 above).

- **MARTIN solve / re-estimation:**
  - `solve_martin()` with frozen + reestimated coefficient paths
    (TSRANGE rewriter for arbitrary `estimation_end`).
  - 2025Q2 re-estimation closes the post-COVID gap on NCR/PTM/Y.
  - Regression test bit-identical to the canonical bimets pipeline.

- **Nowcast handover:**
  - ARIMA/ETS default + monthly bridge equations
    (`method = "bridge_monthly"`).
  - Bridge improves consumption/GDP nowcasts vs ARIMA (item 4 above
    is the wiring into the default).
