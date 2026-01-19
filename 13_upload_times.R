#!/usr/bin/env Rscript

# ============================================================
# 13_upload_times.R
#
# Extracts screenshot upload times (seconds) from raw survey data.
# ============================================================

library(readr)
library(dplyr)

# ----------------------------
# CONFIG
# ----------------------------
TEAM_SLUG <- "team_example"
WAVE <- "baseline"  # "baseline" or "endline"

ROOT_DIR <- file.path("data", "qualtrics", TEAM_SLUG, WAVE)
RESPONSES_PATH <- file.path(ROOT_DIR, "responses.csv")
OUTPUT_PATH <- file.path(ROOT_DIR, "results", "upload_times.csv")

# ----------------------------
# Wave-specific column mappings
# ----------------------------
WAVE_CONFIG <- list(
  baseline = list(
    device_col = "iPhoneorAndroid2",
    ios_avg_timer = "SSiPhonetimer2_Page Submit",
    ios_app_timer = "SSiPhoneTimer22_Page Submit",
    android_ss_id_suffix = "_AndroidSS12_Id",
    android_avg_timer_suffix = "_SSAndroidtimer2_Page Submit",
    android_app_timer_suffix = "_SSAndroidTimer22_Page Submit"
  ),
  endline = list(
    device_col = "iPhoneorAndroid3",
    ios_avg_timer = "SSiPhonetimer3_Page Submit",
    ios_app_timer = "SSiPhoneTimer23_Page Submit",
    android_ss_id_suffix = "_AndroidLastWeekSS13_Id",
    android_avg_timer_suffix = "_SSAndroidtimer3_Page Submit",
    android_app_timer_suffix = "_SSAndroidTimer23_Page Submit"
  )
)

# Validate and get config
if (!WAVE %in% c("baseline", "endline")) stop("WAVE must be 'baseline' or 'endline'.", call. = FALSE)
cfg <- WAVE_CONFIG[[WAVE]]

# ----------------------------
# Load data
# ----------------------------
responses <- read_csv(RESPONSES_PATH, show_col_types = FALSE)
message(sprintf("Loaded %d responses", nrow(responses)))

# ----------------------------
# Process each respondent
# ----------------------------
results <- list()

for (i in seq_len(nrow(responses))) {
  row <- responses[i, ]
  resp_id <- row$ResponseId
  device_raw <- row[[cfg$device_col]]

  # Determine device (1 = iOS, 2 = Android)
  if (is.na(device_raw)) {
    next
  } else if (device_raw == 1 || tolower(as.character(device_raw)) %in% c("iphone", "ios")) {
    device <- "iOS"
  } else if (device_raw == 2 || tolower(as.character(device_raw)) == "android") {
    device <- "Android"
  } else {
    next
  }

  # Get timer column names based on device
  if (device == "iOS") {
    avg_col <- cfg$ios_avg_timer
    app_col <- cfg$ios_app_timer
  } else {
    # Android: find which day prefix (1-7) has data
    prefix <- NA
    for (p in 1:7) {
      id_col <- paste0(p, cfg$android_ss_id_suffix)
      if (id_col %in% names(row) && !is.na(row[[id_col]]) && row[[id_col]] != "") {
        prefix <- p
        break
      }
    }
    if (is.na(prefix)) next

    avg_col <- paste0(prefix, cfg$android_avg_timer_suffix)
    app_col <- paste0(prefix, cfg$android_app_timer_suffix)
  }

  # Extract times
  avg_time <- as.numeric(row[[avg_col]])
  app_time <- as.numeric(row[[app_col]])

  # Validate
  if (!is.na(avg_time) && avg_time < 0) {
    stop(sprintf("Invalid avg_time for %s: %s", resp_id, avg_time))
  }
  if (!is.na(app_time) && app_time < 0) {
    stop(sprintf("Invalid app_time for %s: %s", resp_id, app_time))
  }

  results[[length(results) + 1]] <- tibble(
    respondent_id = resp_id,
    device = device,
    avg_upload_sec = avg_time,
    app_upload_sec = app_time
  )
}

upload_times <- bind_rows(results)
message(sprintf("Extracted times for %d respondents\n", nrow(upload_times)))

# ----------------------------
# Summary
# ----------------------------
summarize_times <- function(x, label) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return()
  message(sprintf("%s (n=%d): median=%.0fs, mean=%.0fs, range=[%.0f-%.0f]",
                  label, length(x), median(x), mean(x), min(x), max(x)))
}

summarize_times(upload_times$avg_upload_sec, "Avg screenshot")
summarize_times(upload_times$app_upload_sec, "App screenshots")

for (dev in c("iOS", "Android")) {
  subset <- filter(upload_times, device == dev)
  if (nrow(subset) == 0) next
  message(sprintf("\n%s:", dev))
  summarize_times(subset$avg_upload_sec, "  Avg screenshot")
  summarize_times(subset$app_upload_sec, "  App screenshots")
}

# ----------------------------
# Save
# ----------------------------
dir.create(dirname(OUTPUT_PATH), recursive = TRUE, showWarnings = FALSE)
write_csv(upload_times, OUTPUT_PATH)
wave_label <- tools::toTitleCase(WAVE)
message(sprintf("\n%s upload times saved: %s", wave_label, OUTPUT_PATH))
