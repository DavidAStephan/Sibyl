# The SIBYL dashboard

A small Shiny app at [`app/app.R`](../app/app.R) lets you type a
narrative, watch the LLM judgement layer turn it into add-factors,
solve MARTIN, and inspect the results in a browser.

For the architectural deep-dive on what the LLM is doing under the
hood see [docs/llm_layer.md](llm_layer.md). This doc is just the
runtime guide.

## Prerequisites

1. The pipeline must have been built once so the targets cache exists:
   ```sh
   just pipeline
   ```
   The dashboard reuses the cached `baseline`, `database_with_handover`,
   `sensitivity_matrix`, `horizon`, and `estimation_end` rather than
   re-running them per click. (Re-running would push every click to
   ~10 minutes; reusing pulls it to ~2-4 minutes.)

2. `ANTHROPIC_API_KEY` must be in `.Renviron`. Without it the "Run
   round" button shows an error.

## Launching

```sh
just dashboard
# equivalent to:
Rscript app/run.R
```

The app starts on `http://localhost:5151` and opens a browser
automatically. To run on a different port:

```sh
PORT=8080 just dashboard
```

To suppress the browser auto-launch (useful when forwarding through
ssh):

```sh
SIBYL_NO_LAUNCH_BROWSER=1 just dashboard
```

## Layout

```
┌─────────────────────┬────────────────────────────────────────────┐
│ SIDEBAR             │ MAIN AREA  (tabs)                          │
│                     │                                            │
│ [Narrative textbox] │ [ Chart ] [ Adjustments ] [ Description ]  │
│                     │ [ Audit ] [ Iteration history ]            │
│ Refinement iters    │                                            │
│ Propose model       │ ... contents of the selected tab ...       │
│                     │                                            │
│ [Run round]         │                                            │
│ status line         │                                            │
└─────────────────────┴────────────────────────────────────────────┘
```

### Sidebar inputs

- **Narrative textbox** — paste or type the forecast story. Defaults
  to the canonical sticky-services-inflation example. The LLM uses
  this verbatim as the narrative passed to `propose_adjustments()`.

- **Refinement iterations** — `max_iters` for the agentic loop
  (default 3 = one propose + up to two refinements). Set to 1 for
  the cheapest "propose-only" mode.

- **Propose model** — Sonnet 4.6 (default) or Haiku 4.5. Sonnet is
  more decisive at calibrating magnitudes and figuring out cancelling
  AFs; Haiku is ~5x cheaper and ~3x faster. Describe + audit always
  run on Haiku because they're cheap text tasks.

- **Run round** — fires the propose / solve / describe / audit /
  refine pipeline. A progress widget appears; the button doesn't
  disable but a second click while running is harmless (Shiny
  serialises observers).

### Tabs

- **Chart** — Plotly facet of the seven headline aggregates
  (Y, RC, GNE, LUR, PTM, P, NCR), baseline (grey) vs scenario
  (blue), zoomed to 2018+. Hover for exact values. Below the
  chart, a small table shows the diff at horizon end on each
  variable.

- **Proposed adjustments** — the structured add-factors the LLM
  produced. Columns: `equation`, `quarter`, `value`, `tail`,
  `confidence`, `rationale`, `source`. The `source` field shows
  `llm` for an initial proposal and `llm-refined` if the
  refinement loop revised it.

- **Projection description** — the LLM's prose description of the
  solved projection. Note: this LLM call is *blind* to your
  narrative by design — otherwise the round-trip audit becomes
  trivially satisfied. The describer only sees a diff-vs-baseline
  summary.

- **Round-trip audit** — the claim-by-claim verdict
  (agree / disagree / not_addressed). Below it, the diagnostics
  table from `judgement::diagnose_audit()` classifies each
  disagreement as either:
  - `translation_gap` — LLM didn't deliver a claim's target.
    The refinement loop should fix it.
  - `model_response` — narrative said "no change" but MARTIN's
    structure responded (Taylor Rule, Phillips curve, ...). The
    forecaster needs to accept the trade-off or add a cancelling
    AF on the responding equation.
  - `not_addressed` — the describer didn't restate this claim
    (often a causal/structural framing that doesn't appear in a
    numerical description).

- **Iteration history** — one row per orchestrator iteration,
  showing which equations were touched at each pass and the audit
  verdict at each step. The row marked `*` is the iteration the
  orchestrator picked as best (highest audit verdict, earliest on
  ties).

## What the run costs

Per click:

| Step | Model | Approx tokens | Approx cost |
|---|---|---|---|
| Propose | Sonnet 4.6 | 9k in / 1k out | ~$0.03 |
| Describe (per iter) | Haiku 4.5 | 1k / 0.3k | ~$0.002 |
| Audit (per iter) | Haiku 4.5 | 1k / 0.3k | ~$0.002 |
| Refine (per iter ≥ 2) | Sonnet 4.6 | 9k / 1k | ~$0.03 |

A typical 3-iteration round is ~$0.05-0.10 and takes ~2-4 minutes
of wall clock.

## Demo narratives to try

These all produce coherent rounds; the audit verdicts vary by how
internally consistent the narrative is in MARTIN's framework.

**Sticky services inflation (audit usually agrees):**

> Services inflation has been persistently sticky in our latest
> data. We think trimmed-mean inflation stays roughly 0.1
> percentage points higher than baseline through 2025Q2, fading
> thereafter as labour-market slack opens up. No change to our
> view on the cash-rate path.

**Labour-market structural shift (audit usually says "partial" or
"disagree" because the LUR shock forces Taylor Rule + Phillips
curve responses):**

> Employment growth has been persistently stronger than the model
> predicts since the post-COVID reopening — possibly reflecting
> structural changes in labour-force attachment (long-COVID exits,
> care-economy growth, immigration composition). We expect this
> to persist, lowering the unemployment rate by roughly 1.5
> percentage points below baseline through 2025Q4. No change to
> our view on the cash-rate path or inflation.

**Capex slowdown with consistent monetary response:**

> Business investment intentions have softened materially in the
> latest NAB capex survey. We expect non-mining business
> investment to run roughly 4% below baseline through 2025Q4,
> with knock-on weakness for real GDP and labour demand. The RBA
> is expected to respond by cutting the cash rate ~50bp lower
> than baseline by end-2025.

## Failure modes

- **"Run round" returns instantly with an error.** Either
  `ANTHROPIC_API_KEY` is unset or the targets cache is incomplete.
  Both errors appear in the status line at the bottom of the sidebar.

- **The LLM produces an empty adjustment list.** The narrative is
  too qualitative ("we're worried about the economy" with no
  numbers). The `Adjustments` tab will say "no adjustments";
  re-write the narrative with at least one quantitative claim and
  re-run.

- **The audit says "disagree" on every claim.** Often the narrative
  is over-constrained against MARTIN — see the `Audit` tab's
  diagnostics. `model_response` flags mean MARTIN is correctly
  responding to the AFs you accepted; the audit is doing its job.

- **The chart looks unchanged from baseline.** The LLM proposed
  near-zero values, or the audit picked iter 1 which was the
  initial (cleanest) proposal. Inspect the `Iteration history` tab.

## Limitations vs the full pipeline

The dashboard runs a one-shot LLM round. It does NOT:

- Re-fetch data (uses the cached `database_with_handover`).
- Re-build the sensitivity matrix (uses the cached one).
- Re-solve the baseline (uses the cached one).
- Apply a human-in-the-loop approval step (the
  `review_and_approve()` gate is bypassed — what the LLM proposes
  is what gets solved).

For a full production round (fresh data + interactive approval +
report rendering), use `just pipeline` followed by `just report`.
