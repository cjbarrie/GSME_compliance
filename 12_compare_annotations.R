#!/usr/bin/env Rscript

# ============================================================
# 12_compare_annotations.R
#
# Compares human annotations with AI annotations.
# Reports simple percentage agreement.
#
# Expects all responses to be "Yes" or "No" only.
# ============================================================

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
})

# ----------------------------
# CONFIG (EDIT THESE)
# ----------------------------
TEAM_SLUG <- "team_example"
WAVE <- "endline"

ROOT_DIR <- file.path("data", "qualtrics", TEAM_SLUG, WAVE)
RESULTS_DIR <- file.path(ROOT_DIR, "results")

HUMAN_AVG_PATH <- file.path(RESULTS_DIR, "annotations_avg.csv")
HUMAN_APP_PATH <- file.path(RESULTS_DIR, "annotations_app.csv")
AI_AVG_PATH <- file.path(RESULTS_DIR, "auto_annotations_avg.csv")
AI_APP_PATH <- file.path(RESULTS_DIR, "auto_annotations_app.csv")

# ----------------------------
# Helpers
# ----------------------------
load_annotations <- function(path, source) {
  if (!file.exists(path)) {
    stop(sprintf("Missing file: %s", path), call. = FALSE)
  }
  df <- read_csv(path, show_col_types = FALSE)
  required <- c("task_id", "screenshot_correct", "numbers_match")
  missing <- setdiff(required, names(df))
  if (length(missing) > 0) {
    stop(sprintf("%s missing columns: %s", source, paste(missing, collapse = ", ")), call. = FALSE)
  }
  df
}

validate_yes_no <- function(vals, source, col_name) {
  normalized <- tolower(trimws(as.character(vals)))
  invalid <- normalized[!normalized %in% c("yes", "no")]
  if (length(invalid) > 0) {
    stop(sprintf("Invalid responses in %s column '%s': %s\nOnly 'Yes' or 'No' allowed.",
                 source, col_name, paste(unique(invalid), collapse = ", ")), call. = FALSE)
  }
  normalized
}

calc_agreement <- function(human_vals, ai_vals) {
  matches <- sum(human_vals == ai_vals)
  total <- length(human_vals)
  round(matches / total * 100, 1)
}

# ----------------------------
# Main
# ----------------------------
message(sprintf("\nComparing annotations: %s / %s\n", TEAM_SLUG, WAVE))

human_avg <- load_annotations(HUMAN_AVG_PATH, "human avg")
human_app <- load_annotations(HUMAN_APP_PATH, "human app")
ai_avg <- load_annotations(AI_AVG_PATH, "AI avg")
ai_app <- load_annotations(AI_APP_PATH, "AI app")

# Merge and validate AVG
avg <- inner_join(human_avg, ai_avg, by = "task_id", suffix = c("_human", "_ai"))
if (nrow(avg) == 0) stop("No matching task_ids for AVG annotations")

avg$sc_human <- validate_yes_no(avg$screenshot_correct_human, "human avg", "screenshot_correct")
avg$sc_ai <- validate_yes_no(avg$screenshot_correct_ai, "AI avg", "screenshot_correct")
avg$nm_human <- validate_yes_no(avg$numbers_match_human, "human avg", "numbers_match")
avg$nm_ai <- validate_yes_no(avg$numbers_match_ai, "AI avg", "numbers_match")

# Merge and validate APP
app <- inner_join(human_app, ai_app, by = "task_id", suffix = c("_human", "_ai"))
if (nrow(app) == 0) stop("No matching task_ids for APP annotations")

app$sc_human <- validate_yes_no(app$screenshot_correct_human, "human app", "screenshot_correct")
app$sc_ai <- validate_yes_no(app$screenshot_correct_ai, "AI app", "screenshot_correct")
app$nm_human <- validate_yes_no(app$numbers_match_human, "human app", "numbers_match")
app$nm_ai <- validate_yes_no(app$numbers_match_ai, "AI app", "numbers_match")

# Calculate agreement
avg_sc_agree <- calc_agreement(avg$sc_human, avg$sc_ai)
avg_nm_agree <- calc_agreement(avg$nm_human, avg$nm_ai)
app_sc_agree <- calc_agreement(app$sc_human, app$sc_ai)
app_nm_agree <- calc_agreement(app$nm_human, app$nm_ai)

# Report
message("AVERAGE SCREENTIME TASKS (n=", nrow(avg), ")")
message("  Screenshot correct: ", avg_sc_agree, "% agreement")
message("  Numbers match:      ", avg_nm_agree, "% agreement")

message("\nAPP-LEVEL TASKS (n=", nrow(app), ")")
message("  Screenshot correct: ", app_sc_agree, "% agreement")
message("  Numbers match:      ", app_nm_agree, "% agreement")

message("\nDone.")
