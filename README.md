# SIBYL

**Structured Inference, Bayesian Yarns, and Likelihoods.**

SIBYL automates a central-bank-style forecast round using public data only, and
explores whether LLMs can shift forecaster time away from mechanical
number-tweaking and toward narrative and judgement.

A forecast round usually goes: update data → nowcast / nearcast the current and
next quarter → hand off to a macro model (MARTIN) that extends the projection
into the medium term → apply judgemental adjustments ("add-factors") to reflect
things the model cannot see. Most of that work is mechanical. SIBYL automates
the mechanical parts and uses an LLM strictly as a translator and drafter:

- it converts narrative statements like "we think the output gap stays open
  longer than last round" into proposed add-factors on specific MARTIN
  equations, with rationales;
- it drafts prose descriptions of solved projections so a human can sanity-check
  that the numbers say what the narrative implied.

**The LLM does not forecast.** The macro model and the nowcasts produce
numbers. The LLM handles the impedance mismatch between human language and
model inputs, and every proposed numerical adjustment is shown to a human as a
table with rationales before MARTIN sees it.

The name nods to the classical Sibyls, who interpreted rather than pronounced.

---

## Repository layout

```
Sibyl/
├── packages/
│   ├── sibyldata/      data: readabs / readrba / fredr / OECD → tidy panels (parquet)
│   ├── nowcast/        bridge equations + simple models (fable) for Q+0, Q+1
│   ├── martin/         MARTIN wrapped around bimets; solves baseline + add-factors
│   └── judgement/      LLM-facing: propose_adjustments() and describe_projection()
├── references/
│   ├── MARTIN-master/  the EViews / R implementation (canonical equations + data flow)
│   └── bimets-main/    the bimets implementation that martin/ is built on
├── _targets.R          end-to-end pipeline: data → nowcast → martin → judgement → report
├── reports/            Quarto outputs of a round
├── data/cache/         local parquet cache (gitignored)
├── scripts/            ad-hoc / setup scripts
├── DESIGN.md           longer-form thinking on the four modules
├── CLAUDE.md           context for Claude Code sessions
└── justfile            common commands (test, check, pipeline, report)
```

Each package under `packages/` is a proper R package with `DESCRIPTION`,
`NAMESPACE`, `R/`, and `tests/testthat/`.

## Quick start

```sh
# 1. Clone, then copy the env example and fill in your API keys
cp .Renviron.example .Renviron
$EDITOR .Renviron

# 2. Bootstrap renv and install core dependencies
Rscript scripts/_init.R

# 3. Run the test suite for every package
just test

# 4. Run the end-to-end targets pipeline (data → nowcast → martin → judgement → report)
just pipeline
```

You'll need R ≥ 4.3, a recent Quarto, and the API keys listed in
[.Renviron.example](.Renviron.example) (FRED is required; Anthropic is required
for the judgement module).

## What's in the box

The pipeline runs end-to-end. A round goes:

1. **Data** — `sibyldata::update_data()` pulls live ABS, RBA, FRED, OECD,
   World Bank, and BoM panels, splices them onto MARTIN's variable schema,
   and applies derived formulas + identity chains + state-space-smoothed
   trends (PI_E, TLUR, RSTAR).
2. **Nowcast** — `nowcast::nowcast_handover()` bridges the ragged edge
   between the last quarterly observation and the projection start using
   monthly indicators (`bridge_monthly`) with ARIMA fallback.
3. **Baseline solve** — `martin::solve_martin()` runs `bimets::SIMULATE`
   against MARTIN with no add-factors, optionally re-estimating
   coefficients through a user-specified quarter.
4. **Sensitivity pre-compute** — `martin::sensitivity_matrix()`
   simulates a standardised unit shock on each of the 56 adjustable
   equations once, recording propagation onto headline aggregates.
5. **LLM round** — `judgement::propose_with_refinement()` does the
   agentic loop: propose add-factors against the narrative + sensitivity
   matrix, solve, describe (blind), audit, refine if needed, pick the
   best iteration.
6. **Report** — `reports/round.qmd` renders the full round with
   narrative coherence diagnostics.

The LLM-layer architecture is documented in
[docs/llm_layer.md](docs/llm_layer.md) with a worked example. For
interactive use, the Shiny dashboard at
[`app/app.R`](app/app.R) takes a narrative and runs the round
end-to-end with a live chart of the result — see
[docs/dashboard.md](docs/dashboard.md). Launch with `just dashboard`.

See [DESIGN.md](DESIGN.md) for the longer architectural story and
[CLAUDE.md](CLAUDE.md) for context to load into a coding session.
[next_session.md](next_session.md) is the live TODO list.

## Relationship to the reference repos

`references/MARTIN-master/` and `references/bimets-main/` are previous
implementations of MARTIN (the RBA's macroeconometric model of Australia) on
public data. They are kept in-tree as **read-only references** — the canonical
source for what MARTIN's equations are, what add-factors look like in practice,
and how the data flow has historically been organised. SIBYL's `martin` package
ships the bimets model definition files copied from `bimets-main/` (with
attribution); the EViews `.prg` files are not lifted but inform how `sibyldata`
and `martin` are structured.

## License

TBD. The reference repos are MIT (bimets) and unspecified (MARTIN-master);
SIBYL's own code will be released under a permissive open-source license to
match.
