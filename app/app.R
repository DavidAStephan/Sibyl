# SIBYL dashboard — narrative-to-projection.
#
# Single-file Shiny app. Loads pre-built pipeline state (baseline,
# database_with_handover, sensitivity_matrix, horizon, estimation_end)
# from the targets cache, then runs the LLM refinement loop and shows
# the result.
#
# Run:
#   Rscript app/run.R          # or: just dashboard
#
# Requires ANTHROPIC_API_KEY in .Renviron and a built targets cache
# (run `just pipeline` first).

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(plotly)
  library(ggplot2)
})

# ---- startup: load packages + targets cache ----------------------------------

# Locate the SIBYL project root. The app may be launched from either
# the project root (just dashboard / Rscript app/run.R) or from the app
# directory itself when Shiny's appDir argument forces it.
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
  pkgload::load_all(file.path(project_root, "packages", pkg),
                    quiet = TRUE)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# Pipeline state. Targets stores its cache under `_targets/` at the
# project root; pass the absolute path so we don't depend on cwd.
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

if (Sys.getenv("ANTHROPIC_API_KEY") == "") {
  warning("ANTHROPIC_API_KEY not set. The 'Run' button will fail. ",
          "Add the key to .Renviron and restart.")
}

# Headline aggregates the chart and diff table focus on.
HEADLINE <- c("Y", "RC", "GNE", "LUR", "PTM", "P", "NCR")
HEADLINE_LABELS <- c(
  Y   = "Real GDP",
  RC  = "Real consumption",
  GNE = "Real GNE",
  LUR = "Unemployment rate (%)",
  PTM = "Trimmed-mean CPI",
  P   = "Headline CPI",
  NCR = "Nominal cash rate (%)"
)

DEFAULT_NARRATIVE <- paste(
  "Services inflation has been persistently sticky in our latest data.",
  "We think trimmed-mean inflation stays roughly 0.1 percentage points",
  "higher than baseline through 2025Q2, fading thereafter as labour-",
  "market slack opens up. No change to our view on the cash-rate path."
)

# ---- UI ---------------------------------------------------------------------

ui <- page_sidebar(
  title = "SIBYL  —  narrative-to-projection",
  theme = bs_theme(version = 5, bootswatch = "flatly"),

  sidebar = sidebar(
    width = 380,
    h4("Narrative"),
    textAreaInput(
      "narrative", label = NULL,
      value = DEFAULT_NARRATIVE,
      width = "100%", height = "220px",
      placeholder = "Write a forecast narrative..."
    ),
    div(style = "font-size: 0.85em; color: #555;",
        "The LLM converts this into add-factors on MARTIN equations,",
        "solves, and audits the result against your narrative."),
    hr(),
    fluidRow(
      column(7,
        selectInput("max_iters", "Refinement iterations",
                    choices = c("1 (no refine)" = 1L,
                                "2" = 2L, "3 (default)" = 3L),
                    selected = 3L)),
      column(5,
        selectInput("propose_model", "Propose model",
                    choices = c("Sonnet 4.6" = "claude-sonnet-4-6",
                                "Haiku 4.5"  = "claude-haiku-4-5"),
                    selected = "claude-sonnet-4-6"))
    ),
    actionButton("run", "Run round", class = "btn-primary btn-lg",
                 width = "100%"),
    hr(),
    div(id = "status", style = "font-size: 0.9em;",
        textOutput("status_text")),
    hr(),
    div(style = "font-size: 0.8em; color: #777;",
        "Pipeline cache: baseline solved through ",
        textOutput("baseline_end", inline = TRUE), ". ",
        "Sensitivity matrix has ",
        textOutput("sm_eqs", inline = TRUE),
        " equations.")
  ),

  navset_card_tab(
    id = "tabs",
    nav_panel(
      "Chart",
      div(style = "padding: 8px;",
          plotlyOutput("headline_plot", height = "560px"),
          br(),
          h5("Diffs at horizon end"),
          tableOutput("diff_table"))
    ),
    nav_panel(
      "Proposed adjustments",
      div(style = "padding: 8px;",
          p(em("The structured add-factors the LLM produced from your narrative. ",
               "Source: 'llm' for initial, 'llm-refined' for refinement passes.")),
          tableOutput("adjustments_table"))
    ),
    nav_panel(
      "Projection description",
      div(style = "padding: 8px;",
          p(em("The LLM's prose description of the solved projection. ",
               "The describer is blind to your narrative by design ",
               "(otherwise the round-trip audit becomes trivial).")),
          uiOutput("description_html"))
    ),
    nav_panel(
      "Round-trip audit",
      div(style = "padding: 8px;",
          h5("Audit verdict"),
          tableOutput("audit_table"),
          h5("Diagnostics"),
          p(em("translation_gap = LLM didn't deliver a claim's target. ",
               "model_response = narrative said 'no change' but MARTIN's ",
               "structure responded anyway (Taylor Rule, Phillips curve, ...). ",
               "not_addressed = the describer didn't restate this claim.")),
          tableOutput("diagnostics_table"))
    ),
    nav_panel(
      "Iteration history",
      div(style = "padding: 8px;",
          p(em("Each row is one iteration of the propose -> solve -> ",
               "audit -> refine loop. ",
               strong("best_iter"), " is the row the orchestrator picked ",
               "(highest audit verdict, earliest on ties).")),
          tableOutput("history_table"))
    )
  )
)

# ---- Server -----------------------------------------------------------------

server <- function(input, output, session) {

  output$baseline_end <- renderText(horizon[2])
  output$sm_eqs <- renderText(length(unique(sensitivity_matrix$equation)))

  state <- reactiveValues(
    result    = NULL,
    error     = NULL,
    status    = "Ready. Enter a narrative and click 'Run round'.",
    last_ran  = NULL
  )
  output$status_text <- renderText(state$status)

  # ---- main "run" action ----
  observeEvent(input$run, {
    narrative_text <- trimws(input$narrative)
    if (!nzchar(narrative_text)) {
      state$status <- "Please enter a narrative first."
      return()
    }
    if (Sys.getenv("ANTHROPIC_API_KEY") == "") {
      state$status <- "ANTHROPIC_API_KEY not set. Add to .Renviron and restart."
      return()
    }

    state$status <- "Running... (typically ~2-4 minutes; LLM + solver)"
    state$error  <- NULL

    progress <- shiny::Progress$new(session, min = 0, max = 1)
    on.exit(progress$close())
    progress$set(value = 0.05, message = "Calling propose_with_refinement",
                 detail = "Sonnet propose + Haiku describe/audit + MARTIN solve")

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
        state$error <- conditionMessage(e)
        NULL
      }
    )
    dt <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
    progress$set(value = 1)

    if (is.null(result)) {
      state$status <- sprintf("Failed after %.0fs: %s", dt,
                              state$error %||% "(unknown)")
      return()
    }
    state$result <- result
    state$last_ran <- Sys.time()
    state$status <- sprintf(
      "Done in %.0fs. Best iter: %d of %d. Audit: %s.",
      dt, result$best_iter, length(result$history),
      attr(result$audit, "overall_match") %||% "n/a"
    )
  })

  # ---- Chart ----
  output$headline_plot <- renderPlotly({
    res <- state$result
    if (is.null(res) || is.null(res$projection)) {
      p <- ggplot() +
        annotate("text", x = 1, y = 1,
                 label = "Run a round to see the chart.",
                 size = 5, colour = "grey50") +
        theme_void()
      return(ggplotly(p))
    }
    df <- dplyr::bind_rows(
      baseline      |> dplyr::mutate(series = "baseline"),
      res$projection |> dplyr::mutate(series = "scenario")
    ) |>
      dplyr::filter(variable %in% HEADLINE) |>
      dplyr::mutate(
        year  = as.integer(substr(quarter, 1, 4)),
        qnum  = as.integer(substr(quarter, 6, 6)),
        qdate = as.Date(sprintf("%04d-%02d-15", year,
                                (qnum - 1) * 3 + 2)),
        label = HEADLINE_LABELS[variable]
      ) |>
      dplyr::filter(year >= 2018)  # zoom to the projection-relevant window

    p <- ggplot(df, aes(qdate, value, colour = series,
                        text = paste0(label, " (", quarter, "): ",
                                      round(value, 3)))) +
      geom_line(aes(group = series), linewidth = 0.5) +
      facet_wrap(~ label, scales = "free_y", ncol = 4) +
      scale_colour_manual(values = c(baseline = "grey50",
                                     scenario = "#1f77b4")) +
      scale_x_date(date_breaks = "2 years", date_labels = "%Y") +
      labs(x = NULL, y = NULL, colour = NULL) +
      theme_minimal(base_size = 11) +
      theme(legend.position = "bottom",
            panel.grid.minor = element_blank())
    suppressWarnings(ggplotly(p, tooltip = "text"))
  })

  # ---- Diff table at horizon end ----
  output$diff_table <- renderTable({
    res <- state$result
    if (is.null(res) || is.null(res$projection)) return(NULL)
    diff_df <- dplyr::inner_join(
      baseline       |> dplyr::select(variable, quarter, baseline = value),
      res$projection |> dplyr::select(variable, quarter, scenario = value),
      by = c("variable", "quarter")
    ) |>
      dplyr::filter(variable %in% HEADLINE) |>
      dplyr::mutate(diff = scenario - baseline,
                    diff_pct = 100 * diff / pmax(abs(baseline), 1e-9)) |>
      dplyr::group_by(variable) |>
      dplyr::summarise(
        end_quarter   = dplyr::last(quarter),
        baseline_end  = dplyr::last(baseline),
        scenario_end  = dplyr::last(scenario),
        diff_at_end   = dplyr::last(diff),
        pct_at_end    = dplyr::last(diff_pct),
        .groups = "drop"
      ) |>
      dplyr::mutate(
        label = HEADLINE_LABELS[variable],
        .before = 1
      ) |>
      dplyr::select(label, baseline_end, scenario_end, diff_at_end, pct_at_end)
    diff_df
  }, digits = 3, striped = TRUE, hover = TRUE)

  # ---- Adjustments table ----
  output$adjustments_table <- renderTable({
    res <- state$result
    if (is.null(res) || length(res$adjustments) == 0L) return(NULL)
    tbl <- judgement::as_tibble_adjustments(res$adjustments)
    tbl |>
      dplyr::select(equation, quarter, value, tail, confidence,
                    rationale, source) |>
      dplyr::arrange(equation, quarter)
  }, digits = 4, striped = TRUE, hover = TRUE)

  # ---- Description ----
  output$description_html <- renderUI({
    res <- state$result
    if (is.null(res) || is.null(res$description)) {
      return(em("Run a round to see the description."))
    }
    HTML(paste0("<div style='font-family: Georgia, serif; ",
                "font-size: 1.05em; line-height: 1.6;'>",
                gsub("\n", "<br/>", res$description, fixed = TRUE),
                "</div>"))
  })

  # ---- Audit + diagnostics ----
  output$audit_table <- renderTable({
    res <- state$result
    if (is.null(res) || is.null(res$audit)) return(NULL)
    res$audit
  }, striped = TRUE, hover = TRUE)

  output$diagnostics_table <- renderTable({
    res <- state$result
    if (is.null(res) || is.null(res$audit) || is.null(res$projection)) {
      return(NULL)
    }
    diag <- judgement::diagnose_audit(res$audit, res$projection, baseline)
    diag |>
      dplyr::select(category, variable, diff_at_end, claim, explanation)
  }, digits = 3, striped = TRUE, hover = TRUE)

  # ---- Iteration history ----
  output$history_table <- renderTable({
    res <- state$result
    if (is.null(res) || length(res$history) == 0L) return(NULL)
    hist_rows <- lapply(res$history, function(it) {
      adj_tbl <- if (length(it$adjustments) > 0L) {
        judgement::as_tibble_adjustments(it$adjustments)
      } else NULL
      eqs <- if (!is.null(adj_tbl)) paste(unique(adj_tbl$equation), collapse = ", ")
             else ""
      n_afs <- if (!is.null(adj_tbl)) length(unique(paste(adj_tbl$equation,
                                                          adj_tbl$source)))
               else 0L
      data.frame(
        iter         = it$iteration,
        equations    = eqs,
        n_AFs        = n_afs,
        audit        = attr(it$audit, "overall_match") %||% "—",
        best         = if (identical(it$iteration, res$best_iter)) "*" else "",
        stringsAsFactors = FALSE
      )
    })
    do.call(rbind, hist_rows)
  }, striped = TRUE, hover = TRUE)
}

shinyApp(ui, server)
