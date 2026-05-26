# SIBYL dashboard - narrative-to-projection.
#
# Single-file Shiny app. Loads pre-built pipeline state (baseline,
# database_with_handover, sensitivity_matrix, horizon, estimation_end)
# from the targets cache, then runs the LLM refinement loop and shows
# the result.
#
# Run:  Rscript app/run.R   (or: just dashboard)

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(plotly)
  library(ggplot2)
})

# ---- Startup: project root, packages, cache --------------------------------

project_root <- if (dir.exists("packages") && dir.exists("_targets")) {
  getwd()
} else if (dir.exists("../packages") && dir.exists("../_targets")) {
  normalizePath("..")
} else if (dir.exists("../../packages") && dir.exists("../../_targets")) {
  normalizePath("../..")
} else {
  stop("Could not locate the SIBYL project root from getwd()=",
       getwd(), ". Run from the project root or via `just dashboard`.")
}

for (pkg in c("sibyldata", "martin", "nowcast", "judgement")) {
  pkgload::load_all(file.path(project_root, "packages", pkg), quiet = TRUE)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

target_store <- file.path(project_root, "_targets")
required <- c("baseline", "database_with_handover", "horizon",
              "estimation_end", "sensitivity_matrix", "round_id")
missing <- setdiff(required, targets::tar_objects(store = target_store))
if (length(missing)) {
  stop("Targets cache missing: ", paste(missing, collapse = ", "),
       ". Run `just pipeline` first (from ", project_root, ").")
}
targets::tar_load(c(baseline, database_with_handover, horizon,
                    estimation_end, sensitivity_matrix, round_id),
                  store = target_store)

api_key_set <- nzchar(Sys.getenv("ANTHROPIC_API_KEY"))

# ---- Domain constants -------------------------------------------------------

HEADLINE <- c("Y", "RC", "GNE", "LUR", "PTM", "P", "NCR")

HEADLINE_LABELS <- c(
  Y   = "Real GDP",
  RC  = "Real consumption",
  GNE = "Real gross national expenditure",
  LUR = "Unemployment rate",
  PTM = "Trimmed-mean CPI",
  P   = "Headline CPI",
  NCR = "Nominal cash rate"
)

# Whether each headline variable is a rate (we show pp-diff in YoY mode)
# or a level/index (% growth). NCR is always rendered as a level regardless
# of the toggle.
HEADLINE_KIND <- c(
  Y   = "level",
  RC  = "level",
  GNE = "level",
  LUR = "rate",
  PTM = "level",
  P   = "level",
  NCR = "rate-locked"  # always shown as level
)

DEFAULT_NARRATIVE <- paste(
  "Services inflation has been persistently sticky in our latest data.",
  "We think trimmed-mean inflation stays roughly 0.1 percentage points",
  "higher than baseline through 2025Q2, fading thereafter as labour-",
  "market slack opens up. No change to our view on the cash-rate path."
)

# Brand palette - inspired by FT/BBG/RBA chart conventions.
COL_INK       <- "#0e1e2c"   # deep ink for text + axes
COL_PAPER     <- "#fbf9f6"   # warm off-white background
COL_RULE      <- "#dcd6cc"   # subtle horizontal rules
COL_MUTED     <- "#5e6b78"
COL_BASELINE  <- "#9aa6b1"
COL_SCENARIO  <- "#0b6a8a"   # deep teal
COL_ACCENT    <- "#c2884a"   # warm tan accent
COL_AGREE     <- "#1d7a3a"
COL_PARTIAL   <- "#b07a00"
COL_DISAGREE  <- "#a33a2a"

# ---- Theme + custom CSS -----------------------------------------------------

sibyl_theme <- bs_theme(
  version = 5,
  bg = COL_PAPER,
  fg = COL_INK,
  primary = COL_SCENARIO,
  secondary = COL_MUTED,
  success = COL_AGREE,
  info = COL_SCENARIO,
  warning = COL_PARTIAL,
  danger = COL_DISAGREE,
  base_font = font_collection(
    "ui-sans-serif", "system-ui", "-apple-system",
    "BlinkMacSystemFont", "Segoe UI", "Roboto",
    "Helvetica Neue", "Arial", "sans-serif"
  ),
  heading_font = font_collection(
    "ui-sans-serif", "system-ui", "-apple-system",
    "BlinkMacSystemFont", "Segoe UI", "Roboto",
    "Helvetica Neue", "Arial", "sans-serif"
  ),
  code_font = font_collection(
    "ui-monospace", "SFMono-Regular", "Menlo", "Monaco",
    "Consolas", "monospace"
  ),
  font_scale = 0.95
)

custom_css <- HTML(sprintf("
:root {
  --sibyl-ink:      %s;
  --sibyl-paper:    %s;
  --sibyl-rule:     %s;
  --sibyl-muted:    %s;
  --sibyl-baseline: %s;
  --sibyl-scenario: %s;
  --sibyl-accent:   %s;
  --sibyl-agree:    %s;
  --sibyl-partial:  %s;
  --sibyl-disagree: %s;
}
body, .navbar, .sidebar { background: var(--sibyl-paper) !important; }
.sibyl-app-header {
  background: var(--sibyl-ink);
  color: #fff;
  padding: 14px 28px 12px 28px;
  display: flex;
  align-items: baseline;
  gap: 18px;
  border-bottom: 3px solid var(--sibyl-accent);
}
.sibyl-app-title {
  font-size: 1.45rem;
  font-weight: 600;
  letter-spacing: 0.02em;
}
.sibyl-app-subtitle {
  font-size: 0.92rem;
  opacity: 0.78;
  font-weight: 400;
  letter-spacing: 0.01em;
}
.sibyl-app-meta {
  margin-left: auto;
  font-size: 0.78rem;
  opacity: 0.65;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}
.sibyl-sidebar-section {
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--sibyl-muted);
  margin: 14px 0 6px 0;
  font-weight: 600;
}
.sibyl-status {
  font-size: 0.84rem;
  color: var(--sibyl-muted);
  border-left: 3px solid var(--sibyl-rule);
  padding: 8px 10px;
  background: rgba(0,0,0,0.02);
  border-radius: 0 4px 4px 0;
  min-height: 56px;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  line-height: 1.4;
}
.sibyl-status-running {
  border-left-color: var(--sibyl-scenario);
  background: rgba(11,106,138,0.06);
  color: var(--sibyl-ink);
}
.sibyl-status-done {
  border-left-color: var(--sibyl-agree);
  background: rgba(29,122,58,0.06);
  color: var(--sibyl-ink);
}
.sibyl-status-error {
  border-left-color: var(--sibyl-disagree);
  background: rgba(163,58,42,0.08);
  color: var(--sibyl-ink);
}
.sibyl-cache-info {
  font-size: 0.76rem;
  color: var(--sibyl-muted);
  margin-top: 8px;
  line-height: 1.45;
  border-top: 1px dashed var(--sibyl-rule);
  padding-top: 10px;
}
.sibyl-cache-info b { color: var(--sibyl-ink); font-weight: 600; }
.sibyl-badge {
  display: inline-block;
  font-size: 0.72rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  padding: 3px 10px;
  border-radius: 20px;
  border: 1px solid;
}
.sibyl-badge-agree    { color: var(--sibyl-agree);    border-color: var(--sibyl-agree);    background: rgba(29,122,58,0.08); }
.sibyl-badge-partial  { color: var(--sibyl-partial);  border-color: var(--sibyl-partial);  background: rgba(176,122,0,0.10); }
.sibyl-badge-disagree { color: var(--sibyl-disagree); border-color: var(--sibyl-disagree); background: rgba(163,58,42,0.08); }
.sibyl-badge-neutral  { color: var(--sibyl-muted);    border-color: var(--sibyl-rule);    background: rgba(0,0,0,0.03); }
.sibyl-headline-row {
  display: flex;
  gap: 18px;
  flex-wrap: wrap;
  padding: 6px 0 14px 0;
  margin-bottom: 12px;
  border-bottom: 1px solid var(--sibyl-rule);
}
.sibyl-headline-card {
  flex: 1 1 130px;
  min-width: 130px;
  padding: 6px 0;
}
.sibyl-headline-label {
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--sibyl-muted);
  font-weight: 600;
}
.sibyl-headline-value {
  font-size: 1.4rem;
  font-weight: 600;
  color: var(--sibyl-ink);
  line-height: 1.15;
  margin-top: 2px;
  font-variant-numeric: tabular-nums;
}
.sibyl-headline-delta {
  font-size: 0.82rem;
  margin-top: 1px;
  font-variant-numeric: tabular-nums;
}
.sibyl-delta-up   { color: var(--sibyl-disagree); }
.sibyl-delta-down { color: var(--sibyl-agree); }
.sibyl-delta-flat { color: var(--sibyl-muted); }
.sibyl-section-title {
  font-size: 0.95rem;
  font-weight: 600;
  color: var(--sibyl-ink);
  margin: 16px 0 8px 0;
}
.sibyl-help-text {
  font-size: 0.84rem;
  color: var(--sibyl-muted);
  line-height: 1.55;
  margin-bottom: 10px;
}
.sibyl-help-text code {
  background: rgba(0,0,0,0.05);
  padding: 1px 5px;
  border-radius: 3px;
  font-size: 0.92em;
  color: var(--sibyl-ink);
}
.sibyl-description {
  font-family: Georgia, 'Times New Roman', serif;
  font-size: 1.05rem;
  line-height: 1.7;
  color: var(--sibyl-ink);
  background: #fff;
  padding: 24px 30px;
  border-left: 4px solid var(--sibyl-scenario);
  border-radius: 0 6px 6px 0;
  box-shadow: 0 1px 3px rgba(0,0,0,0.04);
}
.sibyl-narrative-quote {
  font-style: italic;
  color: var(--sibyl-muted);
  border-left: 3px solid var(--sibyl-rule);
  padding: 4px 12px;
  margin: 8px 0 14px 0;
  font-size: 0.9rem;
  line-height: 1.5;
}
.sibyl-tab-content { padding: 18px 4px 4px 4px; }
.nav-tabs .nav-link {
  color: var(--sibyl-muted);
  font-weight: 500;
  border: none;
  border-bottom: 2px solid transparent;
  padding: 10px 16px;
}
.nav-tabs .nav-link:hover { color: var(--sibyl-ink); }
.nav-tabs .nav-link.active {
  color: var(--sibyl-scenario) !important;
  background: transparent !important;
  border-bottom: 2px solid var(--sibyl-scenario) !important;
  font-weight: 600;
}
.card { box-shadow: 0 1px 4px rgba(0,0,0,0.04); border: 1px solid var(--sibyl-rule); }
table.dataframe, .sibyl-table { width: 100%%; }
.sibyl-table {
  font-size: 0.88rem;
  border-collapse: collapse;
}
.sibyl-table th {
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--sibyl-muted);
  font-weight: 600;
  border-bottom: 2px solid var(--sibyl-rule);
  padding: 8px 12px 6px 12px;
  text-align: left;
}
.sibyl-table td {
  padding: 8px 12px;
  border-bottom: 1px solid var(--sibyl-rule);
  vertical-align: top;
  font-variant-numeric: tabular-nums;
}
.sibyl-table td.text { font-variant-numeric: normal; }
.sibyl-table tr:hover td { background: rgba(11,106,138,0.04); }
.sibyl-table td.num-pos { color: var(--sibyl-disagree); }
.sibyl-table td.num-neg { color: var(--sibyl-agree); }
.sibyl-empty {
  text-align: center;
  padding: 60px 20px;
  color: var(--sibyl-muted);
  font-size: 1rem;
  font-style: italic;
}
.shiny-input-container > label { font-weight: 500; color: var(--sibyl-ink); }
.btn-primary {
  background: var(--sibyl-scenario);
  border-color: var(--sibyl-scenario);
  font-weight: 600;
  letter-spacing: 0.02em;
  padding: 10px 16px;
}
.btn-primary:hover, .btn-primary:focus {
  background: #095878;
  border-color: #095878;
}
.btn-primary:disabled { opacity: 0.55; }
textarea.form-control { font-family: inherit; font-size: 0.93rem; }
",
COL_INK, COL_PAPER, COL_RULE, COL_MUTED, COL_BASELINE,
COL_SCENARIO, COL_ACCENT, COL_AGREE, COL_PARTIAL, COL_DISAGREE
))

# ---- Helpers ----------------------------------------------------------------

quarter_to_date <- function(q) {
  year <- as.integer(substr(q, 1, 4))
  qnum <- as.integer(substr(q, 6, 6))
  as.Date(sprintf("%04d-%02d-15", year, (qnum - 1) * 3 + 2))
}

# Apply the user-selected view transform to a (variable, quarter, value)
# tibble. `transform`: one of "level" or "yoy".
#   yoy + variable is "rate":         x_t - x_{t-4}          (in pp)
#   yoy + variable is "level":        (x_t/x_{t-4} - 1) * 100 (in %)
#   yoy + variable is "rate-locked":  raw level
#   level + anything:                 raw level
apply_view <- function(df, transform) {
  df <- dplyr::arrange(df, variable, series, quarter)
  out <- df |> dplyr::group_by(variable, series) |>
    dplyr::mutate(
      kind = HEADLINE_KIND[variable],
      value_view = dplyr::case_when(
        transform == "level" | kind == "rate-locked" ~ value,
        kind == "level"                              ~ 100 *
          (value / dplyr::lag(value, 4) - 1),
        kind == "rate"                               ~ value -
          dplyr::lag(value, 4),
        TRUE                                          ~ value
      ),
      unit_view = dplyr::case_when(
        transform == "level" | kind == "rate-locked" ~ "level",
        kind == "level"                              ~ "% YoY",
        kind == "rate"                               ~ "pp YoY",
        TRUE                                          ~ "level"
      )
    ) |>
    dplyr::ungroup()
  out
}

audit_badge_html <- function(verdict) {
  cls <- switch(verdict %||% "neutral",
    "agree"    = "sibyl-badge-agree",
    "partial"  = "sibyl-badge-partial",
    "disagree" = "sibyl-badge-disagree",
    "sibyl-badge-neutral")
  label <- if (is.null(verdict) || !nzchar(verdict)) "Pending" else
    toupper(verdict)
  sprintf('<span class="sibyl-badge %s">%s</span>', cls, label)
}

# ---- UI: header --------------------------------------------------------------

baseline_end_quarter <- horizon[2]
n_equations <- length(unique(sensitivity_matrix$equation))
baseline_scenario <- attr(baseline, "scenario") %||% "baseline"

app_header <- tags$div(
  class = "sibyl-app-header",
  tags$div(class = "sibyl-app-title", "SIBYL"),
  tags$div(class = "sibyl-app-subtitle",
           "Narrative-to-projection workbench  -  MARTIN solve with LLM judgement"),
  tags$div(class = "sibyl-app-meta",
           sprintf("horizon %s -> %s  -  re-est %s  -  %d adj. eqs",
                   horizon[1], horizon[2],
                   estimation_end %||% "frozen",
                   n_equations))
)

# ---- UI: sidebar ------------------------------------------------------------

sidebar_ui <- sidebar(
  width = 400,
  open = "always",
  tags$div(class = "sibyl-sidebar-section", "Forecast narrative"),
  textAreaInput(
    inputId = "narrative", label = NULL,
    value = DEFAULT_NARRATIVE,
    width = "100%", height = "210px",
    placeholder = "Write a forecast narrative..."
  ),
  tags$div(class = "sibyl-help-text",
    "Describe the economic story in plain English. The LLM converts it",
    " into add-factors on specific MARTIN equations and audits the",
    " resulting projection against your claims."),
  tags$div(class = "sibyl-sidebar-section", "Round configuration"),
  fluidRow(
    column(6,
      selectInput("max_iters", label = "Iterations",
                  choices = c("1 - fast" = 1L,
                              "2 - balanced" = 2L,
                              "3 - full refinement" = 3L),
                  selected = 1L)
    ),
    column(6,
      selectInput("propose_model", label = "Propose model",
                  choices = c("Sonnet 4.6" = "claude-sonnet-4-6",
                              "Haiku 4.5"  = "claude-haiku-4-5"),
                  selected = "claude-sonnet-4-6")
    )
  ),
  tags$div(class = "sibyl-help-text",
    "Start with ", tags$b("Iterations = 1"), " for a fast round (~60s).",
    " Bump to 3 once you want the refinement loop to auto-correct ",
    "any disagreed claims."),
  actionButton("run", label = tagList("Run round", tags$span("→")),
               class = "btn-primary btn-lg", width = "100%"),
  tags$div(class = "sibyl-sidebar-section", "Status"),
  uiOutput("status_ui"),
  tags$div(class = "sibyl-cache-info",
    tags$b("Pipeline cache:"), " baseline solved through ",
    tags$b(baseline_end_quarter),
    ". Sensitivity matrix covers ", tags$b(n_equations), " equations.",
    if (!api_key_set) tagList(tags$br(),
      tags$span(style = "color: var(--sibyl-disagree); font-weight: 600;",
                "ANTHROPIC_API_KEY not set."))
    else NULL
  )
)

# ---- UI: main content -------------------------------------------------------

chart_tab <- nav_panel(
  title = "Chart",
  div(class = "sibyl-tab-content",
    # Headline KPI cards
    uiOutput("kpi_strip"),
    # View controls
    fluidRow(
      column(8,
        radioButtons("chart_view", label = NULL,
                     choices = c("Year-on-year change" = "yoy",
                                 "Levels"              = "level"),
                     selected = "yoy", inline = TRUE)
      ),
      column(4,
        div(style = "text-align: right;",
            tags$span(class = "sibyl-help-text",
              tags$em("NCR always shown as level (rate, not change)."))
        )
      )
    ),
    plotlyOutput("headline_plot", height = "520px"),
    div(class = "sibyl-section-title", "Diffs at horizon end (",
        baseline_end_quarter, ")"),
    uiOutput("diff_table_ui")
  )
)

adjustments_tab <- nav_panel(
  title = "Adjustments",
  div(class = "sibyl-tab-content",
    div(class = "sibyl-help-text",
      "The structured add-factors the LLM produced from your narrative.",
      " Source: ", tags$code("llm"), " for an initial proposal,",
      " ", tags$code("llm-refined"), " for revisions after audit feedback."),
    uiOutput("adjustments_ui")
  )
)

description_tab <- nav_panel(
  title = "Description",
  div(class = "sibyl-tab-content",
    div(class = "sibyl-help-text",
      "The LLM's prose description of the solved projection.",
      tags$strong("The describer is blind to your narrative by design"),
      "- it sees only the diff-vs-baseline. If it had access to the",
      " narrative the round-trip audit would be trivially self-satisfied."),
    uiOutput("description_ui")
  )
)

audit_tab <- nav_panel(
  title = "Audit",
  div(class = "sibyl-tab-content",
    uiOutput("audit_header_ui"),
    div(class = "sibyl-section-title", "Claim-by-claim verdict"),
    uiOutput("audit_table_ui"),
    div(class = "sibyl-section-title", "Diagnostics"),
    div(class = "sibyl-help-text",
      tags$ul(
        tags$li(tags$b("translation_gap"), " - the LLM did not deliver a quantified claim. Iterate or revise."),
        tags$li(tags$b("model_response"), " - the narrative asserted no change to a variable that MARTIN endogenously moved (Taylor Rule, Phillips curve, etc.). Add a cancelling AF or accept the trade-off."),
        tags$li(tags$b("not_addressed"), " - the describer did not engage with the claim, often because it's a structural/causal framing absent from a numerical description.")
      )
    ),
    uiOutput("diagnostics_ui")
  )
)

history_tab <- nav_panel(
  title = "History",
  div(class = "sibyl-tab-content",
    div(class = "sibyl-help-text",
      "One row per orchestrator iteration. ",
      tags$b("Best iter"), " marked with a star - selected by audit verdict",
      " (agree > partial > disagree), ties broken by earliest pass."),
    uiOutput("history_ui")
  )
)

ui <- tagList(
  tags$head(tags$style(custom_css)),
  page_fillable(
    theme = sibyl_theme,
    padding = 0,
    fillable_mobile = TRUE,
    app_header,
    layout_sidebar(
      sidebar = sidebar_ui,
      fillable = TRUE,
      navset_card_tab(
        id = "tabs",
        chart_tab,
        adjustments_tab,
        description_tab,
        audit_tab,
        history_tab
      )
    )
  )
)

# ---- Server -----------------------------------------------------------------

server <- function(input, output, session) {
  state <- reactiveValues(
    result = NULL,
    status_message = "Ready. Edit the narrative and click Run round.",
    status_class = "",
    last_narrative = NULL
  )

  output$status_ui <- renderUI({
    div(class = paste("sibyl-status", state$status_class),
        state$status_message)
  })

  # ----- Run action -----
  observeEvent(input$run, {
    narrative_text <- trimws(input$narrative)
    if (!nzchar(narrative_text)) {
      state$status_message <- "Please enter a narrative first."
      state$status_class <- "sibyl-status-error"
      return()
    }
    if (!api_key_set) {
      state$status_message <- paste(
        "ANTHROPIC_API_KEY is not set in .Renviron.",
        "Add it and restart the dashboard.")
      state$status_class <- "sibyl-status-error"
      return()
    }

    state$status_message <- paste(
      "Running:", input$propose_model, "propose +",
      "Haiku describe/audit + MARTIN solve.",
      "Allow ~60s per iteration."
    )
    state$status_class <- "sibyl-status-running"

    progress <- shiny::Progress$new(session, min = 0, max = 1)
    on.exit(progress$close())
    progress$set(value = 0.05,
                 message = "Running SIBYL round",
                 detail = "Propose -> solve -> describe -> audit")

    solve_fn <- function(adj) {
      martin::solve_martin(
        database       = database_with_handover,
        adjustments    = adj,
        horizon        = horizon,
        coefficients   = if (is.null(estimation_end)) "frozen"
                         else "reestimated",
        estimation_end = estimation_end,
        scenario       = "dashboard-run"
      )
    }

    t0 <- Sys.time()
    result <- tryCatch(
      judgement::propose_with_refinement(
        narrative          = narrative_text,
        baseline           = baseline,
        solve_fn           = solve_fn,
        max_iters          = as.integer(input$max_iters),
        round_id           = paste0("dash-",
                                    format(Sys.time(), "%Y%m%d-%H%M%S")),
        sensitivity_matrix = sensitivity_matrix,
        model              = "claude-haiku-4-5",
        model_propose      = input$propose_model
      ),
      error = function(e) {
        state$status_message <- paste("Run failed:", conditionMessage(e))
        state$status_class <- "sibyl-status-error"
        NULL
      }
    )
    dt <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
    progress$set(value = 1)

    if (is.null(result)) return()

    state$result <- result
    state$last_narrative <- narrative_text
    state$status_message <- sprintf(
      "Done in %.0fs. Best iter: %d of %d. Audit: %s.",
      dt, result$best_iter, length(result$history),
      attr(result$audit, "overall_match") %||% "n/a"
    )
    state$status_class <- "sibyl-status-done"
  })

  # ----- KPI strip -----
  output$kpi_strip <- renderUI({
    res <- state$result
    if (is.null(res) || is.null(res$projection)) return(NULL)
    df <- dplyr::inner_join(
      baseline       |> dplyr::select(variable, quarter, baseline = value),
      res$projection |> dplyr::select(variable, quarter, scenario = value),
      by = c("variable", "quarter")
    ) |>
      dplyr::filter(variable %in% HEADLINE,
                    quarter == baseline_end_quarter) |>
      dplyr::mutate(
        diff_abs = scenario - baseline,
        diff_pct = 100 * diff_abs / pmax(abs(baseline), 1e-9),
        label    = HEADLINE_LABELS[variable]
      )
    cards <- lapply(HEADLINE, function(v) {
      row <- df[df$variable == v, ]
      if (nrow(row) == 0L) return(NULL)
      kind <- HEADLINE_KIND[v]
      if (kind %in% c("rate", "rate-locked")) {
        value_str <- sprintf("%.2f%%", row$scenario)
        delta_str <- sprintf("%+.2f pp", row$diff_abs)
      } else {
        big <- abs(row$scenario) >= 1000
        value_str <- if (big) format(round(row$scenario), big.mark = ",")
                     else sprintf("%.2f", row$scenario)
        delta_str <- sprintf("%+.2f%% vs baseline", row$diff_pct)
      }
      sign_class <- if (row$diff_abs > 1e-6) "sibyl-delta-up"
                    else if (row$diff_abs < -1e-6) "sibyl-delta-down"
                    else "sibyl-delta-flat"
      div(class = "sibyl-headline-card",
          div(class = "sibyl-headline-label", row$label),
          div(class = "sibyl-headline-value", value_str),
          div(class = paste("sibyl-headline-delta", sign_class), delta_str))
    })
    div(class = "sibyl-headline-row", cards)
  })

  # ----- Chart -----
  output$headline_plot <- renderPlotly({
    res <- state$result
    if (is.null(res) || is.null(res$projection)) {
      p <- ggplot() +
        annotate("text", x = 1, y = 1,
                 label = "Run a round to see the chart.",
                 size = 5, colour = COL_MUTED) +
        theme_void() +
        theme(plot.background = element_rect(fill = COL_PAPER,
                                              colour = NA))
      return(ggplotly(p) |>
               plotly::layout(paper_bgcolor = COL_PAPER,
                              plot_bgcolor  = COL_PAPER))
    }
    df_raw <- dplyr::bind_rows(
      baseline       |> dplyr::mutate(series = "baseline"),
      res$projection |> dplyr::mutate(series = "scenario")
    ) |>
      dplyr::filter(variable %in% HEADLINE)
    df <- apply_view(df_raw, input$chart_view)
    df <- df |>
      dplyr::mutate(qdate = quarter_to_date(quarter),
                    label = HEADLINE_LABELS[variable]) |>
      dplyr::filter(qdate >= as.Date("2018-01-01"))

    if (input$chart_view == "yoy") {
      subtitle <- "Year-on-year change (% for levels, pp for rates; NCR shown as level)"
    } else {
      subtitle <- "Quarterly levels"
    }

    df$tooltip <- sprintf(
      "%s<br>%s: %.3f %s<br>series: %s",
      df$quarter, df$label, df$value_view, df$unit_view, df$series
    )

    p <- ggplot(df, aes(x = qdate, y = value_view, colour = series,
                        group = series, text = tooltip)) +
      geom_line(linewidth = 0.7) +
      facet_wrap(~ label, scales = "free_y", ncol = 4) +
      scale_colour_manual(values = c(baseline = COL_BASELINE,
                                     scenario = COL_SCENARIO),
                          labels = c(baseline = "Baseline",
                                     scenario = "Scenario")) +
      scale_x_date(date_breaks = "2 years", date_labels = "'%y") +
      labs(x = NULL, y = NULL, colour = NULL,
           subtitle = subtitle) +
      theme_minimal(base_size = 11) +
      theme(
        plot.background    = element_rect(fill = COL_PAPER, colour = NA),
        panel.background   = element_rect(fill = COL_PAPER, colour = NA),
        panel.grid.major.x = element_blank(),
        panel.grid.minor   = element_blank(),
        panel.grid.major.y = element_line(colour = COL_RULE, linewidth = 0.3),
        strip.text         = element_text(face = "bold", colour = COL_INK,
                                           size = 10, hjust = 0),
        strip.background   = element_blank(),
        axis.text          = element_text(colour = COL_MUTED, size = 9),
        legend.position    = "bottom",
        plot.subtitle      = element_text(colour = COL_MUTED, size = 10,
                                           margin = margin(b = 8))
      )

    suppressWarnings(
      ggplotly(p, tooltip = "text") |>
        plotly::layout(paper_bgcolor = COL_PAPER,
                       plot_bgcolor  = COL_PAPER,
                       margin = list(t = 36, b = 30, l = 24, r = 10),
                       legend = list(orientation = "h", x = 0.5, y = -0.12,
                                     xanchor = "center"))
    )
  })

  # ----- Diff table -----
  output$diff_table_ui <- renderUI({
    res <- state$result
    if (is.null(res) || is.null(res$projection)) {
      return(div(class = "sibyl-empty", "No round yet."))
    }
    df <- dplyr::inner_join(
      baseline       |> dplyr::select(variable, quarter, baseline = value),
      res$projection |> dplyr::select(variable, quarter, scenario = value),
      by = c("variable", "quarter")
    ) |>
      dplyr::filter(variable %in% HEADLINE,
                    quarter == baseline_end_quarter) |>
      dplyr::mutate(
        diff_abs = scenario - baseline,
        diff_pct = 100 * diff_abs / pmax(abs(baseline), 1e-9),
        label    = HEADLINE_LABELS[variable]
      ) |>
      dplyr::arrange(match(variable, HEADLINE))
    rows <- lapply(seq_len(nrow(df)), function(i) {
      r <- df[i, ]
      kind <- HEADLINE_KIND[r$variable]
      base_fmt <- if (kind %in% c("rate", "rate-locked"))
                    sprintf("%.2f%%", r$baseline)
                  else if (abs(r$baseline) >= 1000)
                    format(round(r$baseline), big.mark = ",")
                  else sprintf("%.2f", r$baseline)
      scen_fmt <- if (kind %in% c("rate", "rate-locked"))
                    sprintf("%.2f%%", r$scenario)
                  else if (abs(r$scenario) >= 1000)
                    format(round(r$scenario), big.mark = ",")
                  else sprintf("%.2f", r$scenario)
      diff_unit <- if (kind %in% c("rate", "rate-locked")) "pp" else
                   sprintf("(%+.2f%%)", r$diff_pct)
      diff_fmt <- sprintf("%+.3f %s", r$diff_abs, diff_unit)
      cls <- if (r$diff_abs > 1e-6) "num-pos"
             else if (r$diff_abs < -1e-6) "num-neg" else ""
      tags$tr(
        tags$td(class = "text", r$label),
        tags$td(class = "text", style = "color: var(--sibyl-muted);",
                r$variable),
        tags$td(base_fmt),
        tags$td(scen_fmt),
        tags$td(class = cls, diff_fmt)
      )
    })
    tags$table(class = "sibyl-table",
      tags$thead(tags$tr(
        tags$th("Variable"), tags$th("Code"),
        tags$th("Baseline"), tags$th("Scenario"),
        tags$th("Difference")
      )),
      tags$tbody(rows)
    )
  })

  # ----- Adjustments -----
  output$adjustments_ui <- renderUI({
    res <- state$result
    if (is.null(res)) {
      return(div(class = "sibyl-empty", "Run a round to see proposed adjustments."))
    }
    if (length(res$adjustments) == 0L) {
      return(div(class = "sibyl-empty",
        "The LLM proposed no quantitative adjustments for this narrative."))
    }
    tbl <- judgement::as_tibble_adjustments(res$adjustments) |>
      dplyr::select(equation, quarter, value, tail, confidence,
                    rationale, source) |>
      dplyr::arrange(equation, quarter)
    rows <- lapply(seq_len(nrow(tbl)), function(i) {
      r <- tbl[i, ]
      val_cls <- if (r$value > 1e-9) "num-pos"
                 else if (r$value < -1e-9) "num-neg" else ""
      tags$tr(
        tags$td(class = "text", tags$b(r$equation)),
        tags$td(r$quarter),
        tags$td(class = val_cls, sprintf("%+.4f", r$value)),
        tags$td(class = "text", r$tail),
        tags$td(class = "text", r$confidence),
        tags$td(class = "text",
                style = "max-width: 480px; white-space: normal;",
                r$rationale),
        tags$td(class = "text",
                tags$code(r$source))
      )
    })
    tags$table(class = "sibyl-table",
      tags$thead(tags$tr(
        tags$th("Equation"), tags$th("Quarter"), tags$th("Value"),
        tags$th("Tail"), tags$th("Confidence"),
        tags$th("Rationale"), tags$th("Source")
      )),
      tags$tbody(rows)
    )
  })

  # ----- Description -----
  output$description_ui <- renderUI({
    res <- state$result
    if (is.null(res) || is.null(res$description)) {
      return(div(class = "sibyl-empty",
        "Run a round to see the LLM's projection description."))
    }
    desc_html <- gsub("\n", "<br/>", res$description, fixed = TRUE)
    tagList(
      if (!is.null(state$last_narrative))
        tagList(
          div(class = "sibyl-section-title", "Original narrative"),
          div(class = "sibyl-narrative-quote", state$last_narrative))
      else NULL,
      div(class = "sibyl-section-title", "LLM description of the solved projection"),
      div(class = "sibyl-description", HTML(desc_html))
    )
  })

  # ----- Audit -----
  output$audit_header_ui <- renderUI({
    res <- state$result
    if (is.null(res) || is.null(res$audit)) return(NULL)
    verdict <- attr(res$audit, "overall_match")
    div(style = "display: flex; gap: 12px; align-items: center; margin-bottom: 8px;",
        tags$span(style = "font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--sibyl-muted); font-weight: 600;",
                  "Overall match:"),
        HTML(audit_badge_html(verdict))
    )
  })

  output$audit_table_ui <- renderUI({
    res <- state$result
    if (is.null(res) || is.null(res$audit)) {
      return(div(class = "sibyl-empty", "No audit yet."))
    }
    aud <- res$audit
    rows <- lapply(seq_len(nrow(aud)), function(i) {
      verdict <- aud$status[i]
      tags$tr(
        tags$td(HTML(audit_badge_html(verdict))),
        tags$td(class = "text", style = "max-width: 520px; white-space: normal;",
                aud$claim[i]),
        tags$td(class = "text", style = "max-width: 320px; white-space: normal; color: var(--sibyl-muted);",
                aud$note[i])
      )
    })
    tags$table(class = "sibyl-table",
      tags$thead(tags$tr(
        tags$th("Verdict"), tags$th("Claim"), tags$th("Audit note")
      )),
      tags$tbody(rows)
    )
  })

  output$diagnostics_ui <- renderUI({
    res <- state$result
    if (is.null(res) || is.null(res$audit) || is.null(res$projection)) {
      return(div(class = "sibyl-empty", "No diagnostics yet."))
    }
    diag <- judgement::diagnose_audit(res$audit, res$projection, baseline)
    cat_palette <- c(
      agree              = "sibyl-badge-agree",
      not_addressed      = "sibyl-badge-neutral",
      translation_gap    = "sibyl-badge-disagree",
      model_response     = "sibyl-badge-partial",
      unclassified       = "sibyl-badge-neutral",
      narrative_conflict = "sibyl-badge-partial"
    )
    rows <- lapply(seq_len(nrow(diag)), function(i) {
      r <- diag[i, ]
      cat <- as.character(r$category)
      cls <- cat_palette[[cat]] %||% "sibyl-badge-neutral"
      badge <- sprintf('<span class="sibyl-badge %s">%s</span>',
                       cls, gsub("_", " ", cat))
      tags$tr(
        tags$td(HTML(badge)),
        tags$td(class = "text",
                if (is.na(r$variable)) tags$em("—") else tags$b(r$variable)),
        tags$td(if (is.na(r$diff_at_end)) tags$em("—")
                else sprintf("%+.3f", r$diff_at_end)),
        tags$td(class = "text", style = "max-width: 540px; white-space: normal;",
                r$explanation)
      )
    })
    tags$table(class = "sibyl-table",
      tags$thead(tags$tr(
        tags$th("Category"), tags$th("Variable"),
        tags$th("Diff @ horizon"), tags$th("Explanation")
      )),
      tags$tbody(rows)
    )
  })

  # ----- History -----
  output$history_ui <- renderUI({
    res <- state$result
    if (is.null(res) || length(res$history) == 0L) {
      return(div(class = "sibyl-empty", "Run a round to see iteration history."))
    }
    best_i <- res$best_iter %||% NA
    rows <- lapply(seq_along(res$history), function(i) {
      it <- res$history[[i]]
      adj_tbl <- if (length(it$adjustments) > 0L) {
        judgement::as_tibble_adjustments(it$adjustments)
      } else NULL
      eqs <- if (!is.null(adj_tbl))
        paste(unique(adj_tbl$equation), collapse = ", ") else ""
      n_afs <- if (!is.null(adj_tbl)) length(adj_tbl$equation) else 0L
      verdict <- attr(it$audit, "overall_match")
      tags$tr(
        tags$td(class = "text",
                tags$b(paste0("Iteration ", it$iteration))),
        tags$td(class = "text", eqs),
        tags$td(n_afs),
        tags$td(HTML(audit_badge_html(verdict))),
        tags$td(class = "text",
                if (identical(i, best_i))
                  tags$span(class = "sibyl-badge sibyl-badge-agree",
                            style = "padding: 2px 8px; font-size: 0.65rem;",
                            "BEST")
                else "")
      )
    })
    tags$table(class = "sibyl-table",
      tags$thead(tags$tr(
        tags$th("Iter"), tags$th("Equations"),
        tags$th("# AFs"), tags$th("Audit"), tags$th("")
      )),
      tags$tbody(rows)
    )
  })
}

shinyApp(ui, server)
