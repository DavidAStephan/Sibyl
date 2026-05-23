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

## What's in the box right now

This repo is **scaffolding only**. Modules contain stubs, not implementations.
The first session to follow will:

1. Build out the add-factor S3 class in `judgement` (constructor + validator + tests).
2. Wire `martin::solve_martin()` against the bundled `MARTINDATA_XLSX` fixture in
   `packages/martin/inst/extdata/` and pass a regression test that solves with no
   adjustments and matches the bimets reference.
3. Then `sibyldata`, then `nowcast`, then `judgement` proper.

See [DESIGN.md](DESIGN.md) for the longer architectural story and
[CLAUDE.md](CLAUDE.md) for context to load into a coding session.

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
