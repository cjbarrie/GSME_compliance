#!/usr/bin/env Rscript

# ============================================================
# 14_device_consistency.R
#
# Compares OS and browser between baseline and endline waves.
# Uses wrangled files to get participant_id for cross-wave matching.
# ============================================================

library(readr)
library(dplyr)

# ----------------------------
# CONFIG
# ----------------------------
TEAM_SLUG <- "team_example"

# Paths to wrangled files (contain participant_id for cross-wave matching)
BASELINE_AVG <- file.path("data", "qualtrics", TEAM_SLUG, "baseline", "derived", "average_screentime_for_annotation.csv")
ENDLINE_AVG <- file.path("data", "qualtrics", TEAM_SLUG, "endline", "derived", "average_screentime_for_annotation.csv")

# Paths to raw responses (contain OS/browser info)
BASELINE_RESPONSES <- file.path("data", "qualtrics", TEAM_SLUG, "baseline", "responses.csv")
ENDLINE_RESPONSES <- file.path("data", "qualtrics", TEAM_SLUG, "endline", "responses.csv")

OUTPUT_PATH <- file.path("data", "qualtrics", TEAM_SLUG, "device_consistency.csv")

# ----------------------------
# Load wrangled data (for participant_id mapping)
# ----------------------------
baseline_wrangled <- read_csv(BASELINE_AVG, show_col_types = FALSE)
endline_wrangled <- read_csv(ENDLINE_AVG, show_col_types = FALSE)

message(sprintf("Baseline: %d respondents", nrow(baseline_wrangled)))
message(sprintf("Endline: %d respondents", nrow(endline_wrangled)))

# Check for participant_id column
if (!"participant_id" %in% names(baseline_wrangled) || !"participant_id" %in% names(endline_wrangled)) {
  stop("participant_id column not found. Re-run 02_wrangle.R to generate it.", call. = FALSE)
}

# ----------------------------
# Load raw responses (for OS/browser info)
# ----------------------------
baseline_raw <- read_csv(BASELINE_RESPONSES, show_col_types = FALSE)
endline_raw <- read_csv(ENDLINE_RESPONSES, show_col_types = FALSE)

# ----------------------------
# Extract device info with participant_id
# ----------------------------
baseline_devices <- baseline_wrangled %>%
  select(respondent_id, participant_id, device) %>%
  left_join(
    baseline_raw %>%
      transmute(
        respondent_id = ResponseId,
        os_baseline = `OSInfo2_Operating System`,
        browser_baseline = OSInfo2_Browser
      ),
    by = "respondent_id"
  ) %>%
  select(participant_id, device_baseline = device, os_baseline, browser_baseline)

endline_devices <- endline_wrangled %>%
  select(respondent_id, participant_id, device) %>%
  left_join(
    endline_raw %>%
      transmute(
        respondent_id = ResponseId,
        os_endline = `OSInfo3_Operating System`,
        browser_endline = OSInfo3_Browser
      ),
    by = "respondent_id"
  ) %>%
  select(participant_id, device_endline = device, os_endline, browser_endline)

# ----------------------------
# Match and compare by participant_id
# ----------------------------
matched <- inner_join(baseline_devices, endline_devices, by = "participant_id")
message(sprintf("Matched: %d participants\n", nrow(matched)))

if (nrow(matched) == 0) {
  message("No matching participants found between waves.")
  message("This may be expected for test data without common participant IDs.")
  # Create empty output
  matched <- tibble(
    participant_id = character(),
    device_baseline = character(),
    os_baseline = character(),
    browser_baseline = character(),
    device_endline = character(),
    os_endline = character(),
    browser_endline = character(),
    os_match = logical(),
    browser_match = logical(),
    device_match = logical()
  )
} else {
  matched$os_match <- matched$os_baseline == matched$os_endline
  matched$browser_match <- matched$browser_baseline == matched$browser_endline
  matched$device_match <- matched$device_baseline == matched$device_endline

  # ----------------------------
  # Report
  # ----------------------------
  message(sprintf("Device match: %d/%d (%.1f%%)",
                  sum(matched$device_match, na.rm = TRUE), nrow(matched),
                  100 * mean(matched$device_match, na.rm = TRUE)))
  message(sprintf("OS match:     %d/%d (%.1f%%)",
                  sum(matched$os_match, na.rm = TRUE), nrow(matched),
                  100 * mean(matched$os_match, na.rm = TRUE)))
  message(sprintf("Browser match: %d/%d (%.1f%%)",
                  sum(matched$browser_match, na.rm = TRUE), nrow(matched),
                  100 * mean(matched$browser_match, na.rm = TRUE)))

  # Show mismatches
  mismatches <- matched[!matched$device_match | !matched$os_match | !matched$browser_match, ]
  if (nrow(mismatches) > 0) {
    message(sprintf("\n--- MISMATCHES (%d) ---", nrow(mismatches)))
    for (i in seq_len(min(nrow(mismatches), 10))) {  # Show first 10
      row <- mismatches[i, ]
      message(sprintf("\n%s:", row$participant_id))
      message(sprintf("  Baseline: %s / %s / %s", row$device_baseline, row$os_baseline, row$browser_baseline))
      message(sprintf("  Endline:  %s / %s / %s", row$device_endline, row$os_endline, row$browser_endline))
    }
    if (nrow(mismatches) > 10) {
      message(sprintf("\n... and %d more mismatches", nrow(mismatches) - 10))
    }
  }
}

# ----------------------------
# Save
# ----------------------------
dir.create(dirname(OUTPUT_PATH), recursive = TRUE, showWarnings = FALSE)
write_csv(matched, OUTPUT_PATH)
message(sprintf("\nSaved: %s", OUTPUT_PATH))
