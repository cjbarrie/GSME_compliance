#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(shiny)
  library(readr)
  library(dplyr)
  library(stringr)
  library(tidyr)
  library(tibble)
})

# ----------------------------
# CONFIG (EDIT THESE)
# ----------------------------
TEAM_SLUG <- "team_example"
WAVE <- "baseline"   # "baseline" or "endline"

ROOT_DIR <- file.path("data", "qualtrics", TEAM_SLUG, WAVE)

AVG_IN <- file.path(ROOT_DIR, "derived", "average_screentime_for_annotation.csv")
APP_IN <- file.path(ROOT_DIR, "derived", "app_screentime_for_annotation.csv")

RESULTS_DIR <- file.path(ROOT_DIR, "results")
dir.create(RESULTS_DIR, recursive = TRUE, showWarnings = FALSE)

SEED  <- suppressWarnings(as.integer(Sys.getenv("ANNOT_SEED", "12345")))
N_AVG <- suppressWarnings(as.integer(Sys.getenv("ANNOT_N_AVG", "100")))
N_APP <- suppressWarnings(as.integer(Sys.getenv("ANNOT_N_APP", "100")))

SAMPLE_AVG_PATH <- file.path(RESULTS_DIR, "sample_avg.csv")
SAMPLE_APP_PATH <- file.path(RESULTS_DIR, "sample_app.csv")
ANN_AVG_PATH    <- file.path(RESULTS_DIR, "annotations_avg.csv")
ANN_APP_PATH    <- file.path(RESULTS_DIR, "annotations_app.csv")

# ----------------------------
# Helpers
# ----------------------------
safe_read <- function(path) readr::read_csv(path, show_col_types = FALSE)

file_ok_vec <- function(p) {
  p1 <- vapply(p, function(x) {
    if (is.null(x)) return(NA_character_)
    if (is.list(x)) x <- unlist(x, use.names = FALSE)
    x <- as.character(x)
    if (length(x) == 0) return(NA_character_)
    if (length(x) > 1) x <- x[[1]]
    x
  }, character(1))
  ok <- !is.na(p1) & nzchar(p1)
  ok[ok] <- file.exists(p1[ok])
  ok
}

file_ok1 <- function(p) {
  if (is.null(p)) return(FALSE)
  if (is.list(p)) p <- unlist(p, use.names = FALSE)
  p <- as.character(p)
  if (length(p) == 0) return(FALSE)
  if (length(p) > 1) p <- p[[1]]
  !is.na(p) && nzchar(p) && file.exists(p)
}

guess_content_type <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext %in% c("jpg", "jpeg")) return("image/jpeg")
  if (ext %in% c("png")) return("image/png")
  if (ext %in% c("webp")) return("image/webp")
  "application/octet-stream"
}

ensure_cols2 <- function(df, cols, fill = NA) {
  for (nm in cols) if (!nm %in% names(df)) df[[nm]] <- fill
  df
}

make_task_id <- function(prefix, respondent_id, i) {
  sprintf("%s_%s_%04d", prefix, as.character(respondent_id), i)
}

standardize_annotations <- function(df) {
  df <- ensure_cols2(
    df,
    c("task_id","respondent_id","reviewer","screenshot_correct","numbers_match","notes","annotated_at"),
    fill = NA
  )
  df %>%
    mutate(
      task_id = as.character(task_id),
      respondent_id = as.character(respondent_id),
      reviewer = as.character(reviewer),
      screenshot_correct = as.character(screenshot_correct),
      numbers_match = as.character(numbers_match),
      notes = as.character(notes),
      annotated_at = as.character(annotated_at)
    )
}

load_annotations <- function(path) {
  if (!file.exists(path)) return(standardize_annotations(tibble()))
  df <- tryCatch(safe_read(path), error = function(e) tibble())
  standardize_annotations(df)
}

save_annotations <- function(path, df) write_csv(standardize_annotations(df), path)

build_or_load_sample <- function(type = c("avg", "app"), df, n, seed) {
  type <- match.arg(type)
  
  if (type == "avg" && file.exists(SAMPLE_AVG_PATH)) return(safe_read(SAMPLE_AVG_PATH))
  if (type == "app" && file.exists(SAMPLE_APP_PATH)) return(safe_read(SAMPLE_APP_PATH))
  
  set.seed(seed)
  
  if (type == "avg") {
    df <- ensure_cols2(df, c("respondent_id","total_screenshot_path","total_hours","total_minutes","device","screenshot_day"))
    df <- df %>%
      mutate(total_screenshot_path = as.character(total_screenshot_path)) %>%
      filter(file_ok_vec(total_screenshot_path))
    
    if (nrow(df) == 0) stop("No usable avg screenshots found on disk.", call. = FALSE)
    if (nrow(df) < n) n <- nrow(df)
    
    samp <- df %>% slice_sample(n = n) %>%
      mutate(task_id = make_task_id("avg", respondent_id, row_number()))
    
    write_csv(samp, SAMPLE_AVG_PATH)
    return(samp)
  }
  
  df <- ensure_cols2(df, c(
    "respondent_id","device","screenshot_day",
    "instagram_hours","instagram_minutes",
    "facebook_hours","facebook_minutes",
    "tiktok_hours","tiktok_minutes",
    "twitter_hours","twitter_minutes",
    "app_screenshot1_path","app_screenshot2_path","app_screenshot3_path"
  ))
  
  df <- df %>%
    mutate(across(starts_with("app_screenshot"), as.character)) %>%
    filter(
      file_ok_vec(app_screenshot1_path) |
        file_ok_vec(app_screenshot2_path) |
        file_ok_vec(app_screenshot3_path)
    )
  
  if (nrow(df) == 0) stop("No usable app screenshots found on disk.", call. = FALSE)
  if (nrow(df) < n) n <- nrow(df)
  
  samp <- df %>% slice_sample(n = n) %>%
    mutate(task_id = make_task_id("app", respondent_id, row_number()))
  
  write_csv(samp, SAMPLE_APP_PATH)
  samp
}

# ----------------------------
# Load data + create samples
# ----------------------------
if (!file.exists(AVG_IN)) stop("Missing avg input CSV: ", AVG_IN, call. = FALSE)
if (!file.exists(APP_IN)) stop("Missing app input CSV: ", APP_IN, call. = FALSE)

avg_raw <- safe_read(AVG_IN)
app_raw <- safe_read(APP_IN)

avg_tasks <- build_or_load_sample("avg", avg_raw, n = N_AVG, seed = SEED)
app_tasks <- build_or_load_sample("app", app_raw, n = N_APP, seed = SEED)

ann_avg <- load_annotations(ANN_AVG_PATH)
ann_app <- load_annotations(ANN_APP_PATH)

# ----------------------------
# UI
# ----------------------------
ui <- fluidPage(
  tags$head(tags$style(HTML("
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif; }
    .muted { color: #666; }
    .big { font-size: 18px; }
    .panel { padding: 12px; border: 1px solid #ddd; border-radius: 10px; background: #fff; }
    .screenshot-wrap {
      max-height: 55vh;
      overflow: auto;
      border: 1px solid #eee;
      border-radius: 10px;
      padding: 6px;
      background: #fafafa;
    }
    .screenshot-wrap img {
      max-width: 100%;
      height: auto;
      object-fit: contain;
      display: block;
      margin: 0 auto;
    }
    .tight-table td, .tight-table th { padding: 6px !important; }
  "))),
  titlePanel(paste0("Manual Screenshot Annotation (", TEAM_SLUG, " / ", WAVE, ")")),
  
  sidebarLayout(
    sidebarPanel(
      width = 4,
      div(class = "panel",
          div(class="muted", paste0("Seed: ", SEED, " | Sample sizes: avg=", nrow(avg_tasks), ", app=", nrow(app_tasks))),
          div(class="muted", paste0("Saving results in: ", RESULTS_DIR)),
          hr(),
          textInput("reviewer", "Reviewer name", ""),
          hr(),
          # No task type selector anymore — forced Avg then App
          uiOutput("phase_label"),
          hr(),
          actionButton("prev_btn", "← Prev", class="big"),
          actionButton("next_btn", "Next →", class="big"),
          numericInput("jump", "Jump to index", value = 1, min = 1, step = 1),
          actionButton("go_btn", "Go"),
          hr(),
          uiOutput("progress"),
          hr(),
          radioButtons("screenshot_correct", "Correct screenshot?", choices = c("Yes","No","Unsure")),
          radioButtons("numbers_match", "Numbers match screenshot?", choices = c("Yes","No","Unsure")),
          textAreaInput("notes", "Notes (optional)", value = "", rows = 4),
          div(class="muted", "Auto-saves on Next/Prev/Go.")
      )
    ),
    mainPanel(
      width = 8,
      uiOutput("header"),
      br(),
      uiOutput("numbers_panel"),
      br(),
      uiOutput("images_panel"),
      br(),
      uiOutput("done_panel")
    )
  )
)

# ----------------------------
# Server
# ----------------------------
server <- function(input, output, session) {
  
  # phase: "avg" then "app" then "done"
  state <- reactiveValues(phase = "avg", i_avg = 1L, i_app = 1L)
  
  anns <- reactiveValues(avg = ann_avg, app = ann_app)
  
  tasks <- reactive({
    if (state$phase == "avg") return(avg_tasks)
    if (state$phase == "app") return(app_tasks)
    tibble()
  })
  
  idx <- reactive({
    if (state$phase == "avg") return(state$i_avg)
    if (state$phase == "app") return(state$i_app)
    1L
  })
  
  set_idx <- function(v) {
    df <- tasks()
    if (nrow(df) == 0) return()
    v <- max(1L, min(as.integer(v), nrow(df)))
    if (state$phase == "avg") state$i_avg <- v
    if (state$phase == "app") state$i_app <- v
  }
  
  current <- reactive({
    df <- tasks()
    if (nrow(df) == 0) return(NULL)
    i <- idx()
    i <- max(1L, min(i, nrow(df)))
    df[i, , drop = FALSE]
  })
  
  # Prefill saved values when task changes
  observeEvent(list(state$phase, state$i_avg, state$i_app), {
    r <- current()
    if (is.null(r)) return()
    
    type <- state$phase
    cur  <- standardize_annotations(anns[[type]])
    hit  <- cur %>% filter(task_id == as.character(r$task_id[[1]]))
    
    if (nrow(hit) >= 1) {
      updateRadioButtons(session, "screenshot_correct", selected = hit$screenshot_correct[[1]])
      updateRadioButtons(session, "numbers_match", selected = hit$numbers_match[[1]])
      updateTextAreaInput(session, "notes", value = ifelse(is.na(hit$notes[[1]]), "", hit$notes[[1]]))
      if (!is.na(hit$reviewer[[1]]) && nzchar(hit$reviewer[[1]])) {
        updateTextInput(session, "reviewer", value = hit$reviewer[[1]])
      }
    } else {
      updateRadioButtons(session, "screenshot_correct", selected = character(0))
      updateRadioButtons(session, "numbers_match", selected = character(0))
      updateTextAreaInput(session, "notes", value = "")
    }
    
    updateNumericInput(session, "jump", value = idx(), min = 1, max = nrow(tasks()))
  }, ignoreInit = TRUE)
  
  # Save current response (called on Next/Prev/Go)
  do_save <- function() {
    r <- current()
    if (is.null(r)) return()
    type <- state$phase
    if (!type %in% c("avg","app")) return()
    
    rec <- tibble(
      task_id = as.character(r$task_id[[1]]),
      respondent_id = as.character(r$respondent_id[[1]]),
      reviewer = as.character(input$reviewer),
      screenshot_correct = as.character(input$screenshot_correct),
      numbers_match = as.character(input$numbers_match),
      notes = as.character(input$notes),
      annotated_at = as.character(Sys.time())
    ) %>% standardize_annotations()
    
    cur <- standardize_annotations(anns[[type]])
    cur2 <- cur %>%
      filter(is.na(task_id) | task_id != rec$task_id[[1]]) %>%
      bind_rows(rec) %>%
      standardize_annotations()
    
    anns[[type]] <- cur2
    if (type == "avg") save_annotations(ANN_AVG_PATH, cur2) else save_annotations(ANN_APP_PATH, cur2)
  }
  
  # Auto-advance: if finishing avg, switch to app; if finishing app, done.
  advance_phase_if_needed <- function() {
    if (state$phase == "avg") {
      if (state$i_avg > nrow(avg_tasks)) {
        state$phase <- "app"
        state$i_avg <- nrow(avg_tasks) # clamp
        state$i_app <- max(1L, state$i_app)
      }
    } else if (state$phase == "app") {
      if (state$i_app > nrow(app_tasks)) {
        state$phase <- "done"
        state$i_app <- nrow(app_tasks)
      }
    }
  }
  
  observeEvent(input$next_btn, {
    do_save()
    if (state$phase == "avg") {
      state$i_avg <- state$i_avg + 1L
    } else if (state$phase == "app") {
      state$i_app <- state$i_app + 1L
    }
    advance_phase_if_needed()
  })
  
  observeEvent(input$prev_btn, {
    do_save()
    if (state$phase == "avg") {
      state$i_avg <- max(1L, state$i_avg - 1L)
    } else if (state$phase == "app") {
      state$i_app <- max(1L, state$i_app - 1L)
    }
  })
  
  observeEvent(input$go_btn, {
    do_save()
    set_idx(input$jump)
  })
  
  output$phase_label <- renderUI({
    if (state$phase == "avg") tags$div(class="big", "Phase: Average screenshots")
    else if (state$phase == "app") tags$div(class="big", "Phase: App-level screenshots")
    else tags$div(class="big", "Phase: Done")
  })
  
  output$progress <- renderUI({
    if (state$phase == "done") {
      return(tags$div(
        tags$div(class="big", "All tasks complete ✅"),
        tags$div(class="muted", "You can close this window.")
      ))
    }
    
    df <- tasks()
    type <- state$phase
    done <- if (nrow(anns[[type]]) == 0) 0 else n_distinct(anns[[type]]$task_id)
    
    tags$div(
      tags$div(class="big", paste0("Task ", idx(), " / ", nrow(df))),
      tags$div(class="muted", paste0("Completed: ", done, " / ", nrow(df)))
    )
  })
  
  output$header <- renderUI({
    if (state$phase == "done") return(NULL)
    r <- current(); if (is.null(r)) return(NULL)
    
    day_txt <- if ("screenshot_day" %in% names(r) && !is.na(r$screenshot_day[[1]]) && nzchar(r$screenshot_day[[1]])) {
      paste0(" | Day: ", r$screenshot_day[[1]])
    } else ""
    
    tags$div(
      tags$h3(paste0("Task: ", r$task_id[[1]])),
      tags$div(class="muted",
               paste0("Respondent: ", r$respondent_id[[1]],
                      " | Device: ", if ("device" %in% names(r)) r$device[[1]] else "NA",
                      day_txt))
    )
  })
  
  output$numbers_panel <- renderUI({
    if (state$phase == "done") return(NULL)
    r <- current(); if (is.null(r)) return(NULL)
    
    if (state$phase == "avg") {
      tags$div(class="panel",
               tags$h4("Reported total screen time"),
               tags$p(class="big", paste0("Hours: ", r$total_hours[[1]], "   Minutes: ", r$total_minutes[[1]]))
      )
    } else {
      getv <- function(nm) if (nm %in% names(r)) r[[nm]][[1]] else NA
      tags$div(class="panel",
               tags$h4("Reported app screen time"),
               tags$table(
                 class="table table-striped tight-table",
                 tags$thead(tags$tr(tags$th("App"), tags$th("Hours"), tags$th("Minutes"))),
                 tags$tbody(
                   tags$tr(tags$td("Instagram"), tags$td(getv("instagram_hours")), tags$td(getv("instagram_minutes"))),
                   tags$tr(tags$td("Facebook"),  tags$td(getv("facebook_hours")),  tags$td(getv("facebook_minutes"))),
                   tags$tr(tags$td("TikTok"),    tags$td(getv("tiktok_hours")),    tags$td(getv("tiktok_minutes"))),
                   tags$tr(tags$td("Twitter"),   tags$td(getv("twitter_hours")),   tags$td(getv("twitter_minutes")))
                 )
               )
      )
    }
  })
  
  output$img_avg <- renderImage({
    if (state$phase != "avg") return(NULL)
    r <- current(); if (is.null(r)) return(NULL)
    p <- as.character(r$total_screenshot_path[[1]])
    if (!file_ok1(p)) return(NULL)
    list(src = p, contentType = guess_content_type(p), alt = "screenshot")
  }, deleteFile = FALSE)
  
  output$img_app1 <- renderImage({
    if (state$phase != "app") return(NULL)
    r <- current(); if (is.null(r)) return(NULL)
    p <- as.character(r$app_screenshot1_path[[1]])
    if (!file_ok1(p)) return(NULL)
    list(src = p, contentType = guess_content_type(p), alt = "screenshot 1")
  }, deleteFile = FALSE)
  
  output$img_app2 <- renderImage({
    if (state$phase != "app") return(NULL)
    r <- current(); if (is.null(r)) return(NULL)
    p <- as.character(r$app_screenshot2_path[[1]])
    if (!file_ok1(p)) return(NULL)
    list(src = p, contentType = guess_content_type(p), alt = "screenshot 2")
  }, deleteFile = FALSE)
  
  output$img_app3 <- renderImage({
    if (state$phase != "app") return(NULL)
    r <- current(); if (is.null(r)) return(NULL)
    p <- as.character(r$app_screenshot3_path[[1]])
    if (!file_ok1(p)) return(NULL)
    list(src = p, contentType = guess_content_type(p), alt = "screenshot 3")
  }, deleteFile = FALSE)
  
  output$images_panel <- renderUI({
    if (state$phase == "done") return(NULL)
    r <- current(); if (is.null(r)) return(NULL)
    
    if (state$phase == "avg") {
      tags$div(class="panel",
               tags$h4("Screenshot"),
               tags$div(class="screenshot-wrap", imageOutput("img_avg"))
      )
    } else {
      has1 <- file_ok1(as.character(r$app_screenshot1_path[[1]]))
      has2 <- file_ok1(as.character(r$app_screenshot2_path[[1]]))
      has3 <- file_ok1(as.character(r$app_screenshot3_path[[1]]))
      
      tags$div(class="panel",
               tags$h4("Screenshot(s)"),
               if (has1) tags$div(class="screenshot-wrap", imageOutput("img_app1")),
               if (has2) tags$div(class="screenshot-wrap", imageOutput("img_app2")),
               if (has3) tags$div(class="screenshot-wrap", imageOutput("img_app3")),
               if (!(has1 || has2 || has3)) tags$p("No image files found for this task.")
      )
    }
  })
  
  output$done_panel <- renderUI({
    if (state$phase != "done") return(NULL)
    tags$div(class="panel",
             tags$h3("All annotation tasks complete ✅"),
             tags$p("Your files have been saved automatically:"),
             tags$ul(
               tags$li(tags$code(ANN_AVG_PATH)),
               tags$li(tags$code(ANN_APP_PATH))
             ),
             tags$p(class="muted", "You can now close this window and send the results back.")
    )
  })
}

message("Launching Shiny app…")
shiny::runApp(shinyApp(ui, server), launch.browser = TRUE)
