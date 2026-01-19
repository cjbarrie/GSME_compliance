#!/usr/bin/env Rscript

# ============================================================
# 17_combine_all.R
#
# Combines all compliance check outputs into a single tidy CSV
# with one row per respondent.
#
# Reads from both baseline and endline:
#   - annotations_avg.csv / auto_annotations_avg.csv
#   - annotations_app.csv / auto_annotations_app.csv
#   - upload_times.csv
#   - trufor_report.csv
#   - web_detection_report.csv
#   - device_consistency.csv
#
# Outputs:
#   data/qualtrics/<TEAM_SLUG>/combined_compliance_report.csv
#
# Notes:
#   - Missing files are handled gracefully (columns will be NA)
#   - Annotations converted to binary: Yes=1, No=0, Unsure=NA
#   - Each respondent appears once with baseline (bl_) and endline (el_) columns
# ============================================================

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(tidyr)
})

# ----------------------------
# CONFIG (EDIT THESE)
# ----------------------------
TEAM_SLUG <- "team_example"

BASE_DIR <- file.path("data", "qualtrics", TEAM_SLUG)
OUT_CSV <- file.path(BASE_DIR, "combined_compliance_report.csv")

# ----------------------------
# Helpers
# ----------------------------

# Convert Yes/No/Unsure to 1/0/NA
response_to_binary <- function(x) {
  x <- tolower(trimws(as.character(x)))
  out <- rep(NA_integer_, length(x))
  out[x == "yes"] <- 1L
  out[x == "no"] <- 0L
  # "unsure" and anything else stays NA
  out
}

# Safely read CSV, return NULL if file doesn't exist
safe_read_csv <- function(path) {
  if (file.exists(path)) {
    read_csv(path, show_col_types = FALSE)
  } else {
    message("  File not found: ", path)
    NULL
  }
}

# Load annotations (human or AI) for one wave
load_annotations <- function(wave_dir, type = "avg", source = "human") {
  suffix <- if (source == "human") "" else "auto_"
  filename <- paste0(suffix, "annotations_", type, ".csv")
  path <- file.path(wave_dir, "results", filename)

  df <- safe_read_csv(path)
  if (is.null(df)) return(NULL)

  df %>%
    transmute(
      respondent_id,
      correct = response_to_binary(screenshot_correct),
      match = response_to_binary(numbers_match)
    )
}

# Load upload times for one wave
load_upload_times <- function(wave_dir) {
  path <- file.path(wave_dir, "results", "upload_times.csv")
  df <- safe_read_csv(path)
  if (is.null(df)) return(NULL)

  df %>%
    select(respondent_id, device, avg_upload_sec, app_upload_sec)
}

# Load trufor report for one wave/type
# Returns: respondent_id, flagged (1/0)
load_trufor <- function(wave_dir, type = "avg") {
  # Try type-specific file first, then fall back to combined file
  path <- file.path(wave_dir, "results", paste0("trufor_report_", type, ".csv"))
  df <- safe_read_csv(path)

  # Fallback to old naming convention (single trufor_report.csv)
  if (is.null(df)) {
    path <- file.path(wave_dir, "results", "trufor_report.csv")
    df <- safe_read_csv(path)
    if (is.null(df)) return(NULL)

    # Filter to the correct type (avg or app tasks)
    prefix <- paste0(type, "_")
    df <- df %>% filter(grepl(paste0("^", prefix), task_id))
  }

  if (nrow(df) == 0) return(NULL)

  # Extract respondent_id from task_id
  prefix <- paste0(type, "_")

  # For app tasks, there may be multiple images per respondent
  # Aggregate: flagged if ANY image is flagged
  df %>%
    mutate(
      respondent_id = sub(paste0("^", prefix, "(.+)_\\d+$"), "\\1", task_id),
      flagged = as.integer(status == "flagged")
    ) %>%
    group_by(respondent_id) %>%
    summarise(flagged = as.integer(any(flagged == 1, na.rm = TRUE)), .groups = "drop")
}

# Load web detection report for one wave/type
# Returns: respondent_id, web_match (1/0)
load_web_detection <- function(wave_dir, type = "avg") {
  # Try type-specific file first, then fall back to combined file
  path <- file.path(wave_dir, "results", paste0("web_detection_report_", type, ".csv"))
  df <- safe_read_csv(path)

  # Fallback to old naming convention (single web_detection_report.csv)
  if (is.null(df)) {
    path <- file.path(wave_dir, "results", "web_detection_report.csv")
    df <- safe_read_csv(path)
    if (is.null(df)) return(NULL)

    # Filter to the correct type
    prefix <- paste0(type, "_")
    df <- df %>% filter(grepl(paste0("^", prefix), task_id))
  }

  if (nrow(df) == 0) return(NULL)

  # Extract respondent_id from task_id
  prefix <- paste0(type, "_")

  # Aggregate: match if ANY image has a match
  df %>%
    mutate(
      respondent_id = sub(paste0("^", prefix, "(.+)_\\d+$"), "\\1", task_id),
      web_match = as.integer(status == "match")
    ) %>%
    group_by(respondent_id) %>%
    summarise(web_match = as.integer(any(web_match == 1, na.rm = TRUE)), .groups = "drop")
}

# Load device consistency (cross-wave, at team level)
# Returns: participant_id (for cross-wave join), device_changed
load_device_consistency <- function(base_dir) {
  path <- file.path(base_dir, "device_consistency.csv")
  df <- safe_read_csv(path)
  if (is.null(df)) return(NULL)

  # Expect columns: participant_id (preferred) or respondent_id/ID
  if ("participant_id" %in% names(df)) {
    id_col <- "participant_id"
  } else if ("respondent_id" %in% names(df)) {
    id_col <- "respondent_id"
  } else if ("ID" %in% names(df)) {
    id_col <- "ID"
  } else {
    id_col <- names(df)[1]
  }

  # Look for mismatch indicator column
  mismatch_cols <- grep("mismatch|changed|different", names(df), ignore.case = TRUE, value = TRUE)

  if (length(mismatch_cols) > 0) {
    df %>%
      transmute(
        participant_id = .data[[id_col]],
        device_changed = as.integer(.data[[mismatch_cols[1]]])
      )
  } else if ("os_match" %in% names(df)) {
    # Alternative: os_match column where FALSE means changed
    df %>%
      transmute(
        participant_id = .data[[id_col]],
        device_changed = as.integer(!os_match)
      )
  } else {
    # Can't determine structure, return with NAs
    df %>%
      transmute(
        participant_id = .data[[id_col]],
        device_changed = NA_integer_
      )
  }
}

# Get all respondents from sample files
# Returns: tibble with participant_id, respondent_id, device
get_all_respondents <- function(wave_dir) {
  avg_path <- file.path(wave_dir, "results", "sample_avg.csv")
  app_path <- file.path(wave_dir, "results", "sample_app.csv")

  respondents <- character(0)
  device_map <- list()
  participant_map <- list()

  avg_df <- safe_read_csv(avg_path)
  if (!is.null(avg_df)) {
    respondents <- unique(c(respondents, avg_df$respondent_id))
    for (i in seq_len(nrow(avg_df))) {
      rid <- avg_df$respondent_id[i]
      device_map[[rid]] <- avg_df$device[i]
      if ("participant_id" %in% names(avg_df)) {
        participant_map[[rid]] <- avg_df$participant_id[i]
      }
    }
  }

  app_df <- safe_read_csv(app_path)
  if (!is.null(app_df)) {
    respondents <- unique(c(respondents, app_df$respondent_id))
    for (i in seq_len(nrow(app_df))) {
      rid <- app_df$respondent_id[i]
      if (is.null(device_map[[rid]])) {
        device_map[[rid]] <- app_df$device[i]
      }
      if ("participant_id" %in% names(app_df) && is.null(participant_map[[rid]])) {
        participant_map[[rid]] <- app_df$participant_id[i]
      }
    }
  }

  if (length(respondents) == 0) return(NULL)

  tibble(
    respondent_id = respondents,
    participant_id = sapply(respondents, function(r) participant_map[[r]] %||% NA_character_),
    device = sapply(respondents, function(r) device_map[[r]] %||% NA_character_)
  )
}

# Combine one wave's data
combine_wave <- function(wave_dir, prefix) {
  message("Processing ", prefix, " wave from: ", wave_dir)

  # Get base respondent list
  base_df <- get_all_respondents(wave_dir)
  if (is.null(base_df)) {
    message("  No sample files found for this wave")
    return(NULL)
  }

  # Load all data sources
  avg_h <- load_annotations(wave_dir, "avg", "human")
  avg_ai <- load_annotations(wave_dir, "avg", "ai")
  app_h <- load_annotations(wave_dir, "app", "human")
  app_ai <- load_annotations(wave_dir, "app", "ai")
  upload <- load_upload_times(wave_dir)
  trufor_avg <- load_trufor(wave_dir, "avg")
  trufor_app <- load_trufor(wave_dir, "app")
  web_avg <- load_web_detection(wave_dir, "avg")
  web_app <- load_web_detection(wave_dir, "app")

  # Start building the result
  result <- base_df

  # Add annotations - average (human)
  if (!is.null(avg_h)) {
    avg_h <- avg_h %>% rename(!!paste0(prefix, "_avg_h_correct") := correct,
                               !!paste0(prefix, "_avg_h_match") := match)
    result <- result %>% left_join(avg_h, by = "respondent_id")
  } else {
    result[[paste0(prefix, "_avg_h_correct")]] <- NA_integer_
    result[[paste0(prefix, "_avg_h_match")]] <- NA_integer_
  }

  # Add annotations - average (AI)
  if (!is.null(avg_ai)) {
    avg_ai <- avg_ai %>% rename(!!paste0(prefix, "_avg_ai_correct") := correct,
                                 !!paste0(prefix, "_avg_ai_match") := match)
    result <- result %>% left_join(avg_ai, by = "respondent_id")
  } else {
    result[[paste0(prefix, "_avg_ai_correct")]] <- NA_integer_
    result[[paste0(prefix, "_avg_ai_match")]] <- NA_integer_
  }

  # Add annotations - app (human)
  if (!is.null(app_h)) {
    app_h <- app_h %>% rename(!!paste0(prefix, "_app_h_correct") := correct,
                               !!paste0(prefix, "_app_h_match") := match)
    result <- result %>% left_join(app_h, by = "respondent_id")
  } else {
    result[[paste0(prefix, "_app_h_correct")]] <- NA_integer_
    result[[paste0(prefix, "_app_h_match")]] <- NA_integer_
  }

  # Add annotations - app (AI)
  if (!is.null(app_ai)) {
    app_ai <- app_ai %>% rename(!!paste0(prefix, "_app_ai_correct") := correct,
                                 !!paste0(prefix, "_app_ai_match") := match)
    result <- result %>% left_join(app_ai, by = "respondent_id")
  } else {
    result[[paste0(prefix, "_app_ai_correct")]] <- NA_integer_
    result[[paste0(prefix, "_app_ai_match")]] <- NA_integer_
  }

  # Add upload times
  if (!is.null(upload)) {
    upload_renamed <- upload %>%
      select(respondent_id, avg_upload_sec, app_upload_sec) %>%
      rename(!!paste0(prefix, "_avg_upload_sec") := avg_upload_sec,
             !!paste0(prefix, "_app_upload_sec") := app_upload_sec)
    result <- result %>% left_join(upload_renamed, by = "respondent_id")
  } else {
    result[[paste0(prefix, "_avg_upload_sec")]] <- NA_real_
    result[[paste0(prefix, "_app_upload_sec")]] <- NA_real_
  }

  # Add trufor
  if (!is.null(trufor_avg)) {
    trufor_avg <- trufor_avg %>% rename(!!paste0(prefix, "_avg_trufor_flagged") := flagged)
    result <- result %>% left_join(trufor_avg, by = "respondent_id")
  } else {
    result[[paste0(prefix, "_avg_trufor_flagged")]] <- NA_integer_
  }

  if (!is.null(trufor_app)) {
    trufor_app <- trufor_app %>% rename(!!paste0(prefix, "_app_trufor_flagged") := flagged)
    result <- result %>% left_join(trufor_app, by = "respondent_id")
  } else {
    result[[paste0(prefix, "_app_trufor_flagged")]] <- NA_integer_
  }

  # Add web detection
  if (!is.null(web_avg)) {
    web_avg <- web_avg %>% rename(!!paste0(prefix, "_avg_web_match") := web_match)
    result <- result %>% left_join(web_avg, by = "respondent_id")
  } else {
    result[[paste0(prefix, "_avg_web_match")]] <- NA_integer_
  }

  if (!is.null(web_app)) {
    web_app <- web_app %>% rename(!!paste0(prefix, "_app_web_match") := web_match)
    result <- result %>% left_join(web_app, by = "respondent_id")
  } else {
    result[[paste0(prefix, "_app_web_match")]] <- NA_integer_
  }

  result
}

# ----------------------------
# Main
# ----------------------------
message("Combining compliance data for team: ", TEAM_SLUG)

# Process each wave
baseline_dir <- file.path(BASE_DIR, "baseline")
endline_dir <- file.path(BASE_DIR, "endline")

baseline_df <- combine_wave(baseline_dir, "bl")
endline_df <- combine_wave(endline_dir, "el")

# Combine waves
# Join on participant_id (stable across waves) not respondent_id (wave-specific)
if (!is.null(baseline_df) && !is.null(endline_df)) {
  # Rename respondent_id to wave-specific columns for reference
  baseline_df <- baseline_df %>% rename(bl_respondent_id = respondent_id)
  endline_df <- endline_df %>% rename(el_respondent_id = respondent_id)

  # Full outer join on participant_id
  combined <- baseline_df %>%
    full_join(
      endline_df %>% select(-device),  # device from baseline takes precedence
      by = "participant_id",
      suffix = c("", "_el")
    )

  # Fill device from endline if missing in baseline
  if ("device_el" %in% names(combined)) {
    combined <- combined %>%
      mutate(device = coalesce(device, device_el)) %>%
      select(-device_el)
  }
} else if (!is.null(baseline_df)) {
  combined <- baseline_df %>% rename(bl_respondent_id = respondent_id)
  combined$el_respondent_id <- NA_character_
  # Add empty endline columns
  el_cols <- c("el_avg_h_correct", "el_avg_h_match", "el_avg_ai_correct", "el_avg_ai_match",
               "el_app_h_correct", "el_app_h_match", "el_app_ai_correct", "el_app_ai_match",
               "el_avg_upload_sec", "el_app_upload_sec",
               "el_avg_trufor_flagged", "el_app_trufor_flagged",
               "el_avg_web_match", "el_app_web_match")
  for (col in el_cols) combined[[col]] <- NA
} else if (!is.null(endline_df)) {
  combined <- endline_df %>% rename(el_respondent_id = respondent_id)
  combined$bl_respondent_id <- NA_character_
  # Add empty baseline columns
  bl_cols <- c("bl_avg_h_correct", "bl_avg_h_match", "bl_avg_ai_correct", "bl_avg_ai_match",
               "bl_app_h_correct", "bl_app_h_match", "bl_app_ai_correct", "bl_app_ai_match",
               "bl_avg_upload_sec", "bl_app_upload_sec",
               "bl_avg_trufor_flagged", "bl_app_trufor_flagged",
               "bl_avg_web_match", "bl_app_web_match")
  for (col in bl_cols) combined[[col]] <- NA
} else {
  stop("No data found for either wave.", call. = FALSE)
}

# Add device consistency (cross-wave, joins on participant_id)
device_cons <- load_device_consistency(BASE_DIR)
if (!is.null(device_cons)) {
  combined <- combined %>% left_join(device_cons, by = "participant_id")
} else {
  combined$device_changed <- NA_integer_
}

# Reorder columns for readability
col_order <- c(
  "participant_id", "bl_respondent_id", "el_respondent_id", "device",
  # Baseline annotations
  "bl_avg_h_correct", "bl_avg_h_match", "bl_avg_ai_correct", "bl_avg_ai_match",
  "bl_app_h_correct", "bl_app_h_match", "bl_app_ai_correct", "bl_app_ai_match",
  # Endline annotations
  "el_avg_h_correct", "el_avg_h_match", "el_avg_ai_correct", "el_avg_ai_match",
  "el_app_h_correct", "el_app_h_match", "el_app_ai_correct", "el_app_ai_match",
  # Upload times
  "bl_avg_upload_sec", "bl_app_upload_sec", "el_avg_upload_sec", "el_app_upload_sec",
  # TruFor
  "bl_avg_trufor_flagged", "bl_app_trufor_flagged", "el_avg_trufor_flagged", "el_app_trufor_flagged",
  # Web detection
  "bl_avg_web_match", "bl_app_web_match", "el_avg_web_match", "el_app_web_match",
  # Device consistency
  "device_changed"
)

# Only include columns that exist
col_order <- intersect(col_order, names(combined))
combined <- combined %>% select(all_of(col_order))

# Write output
write_csv(combined, OUT_CSV)

message("\n", strrep("=", 60))
message("Combined compliance report written to:")
message("  ", OUT_CSV)
message("\nSummary:")
message("  Total respondents: ", nrow(combined))
message("  Columns: ", ncol(combined))
message("\nColumn key:")
message("  participant_id = stable ID across waves (for cross-wave matching)")
message("  bl_/el_respondent_id = wave-specific Qualtrics ResponseId")
message("  bl_/el_ = baseline/endline")
message("  avg/app = average screentime / app-level screenshots")
message("  h/ai = human / AI annotation")
message("  _correct = screenshot is correct type (1=Yes, 0=No)")
message("  _match = reported numbers match screenshot (1=Yes, 0=No)")
message("  _trufor_flagged = TruFor tamper detection flag (1=flagged)")
message("  _web_match = web detection found match (1=match found)")
message("  device_changed = device/browser changed between waves (1=changed)")
