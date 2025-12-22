#!/usr/bin/env Rscript

# ============================================================
# 02b_wrangle_endline.R
#
# Reads:
#   data/qualtrics/<TEAM_SLUG>/endline/responses.csv
#   data/qualtrics/<TEAM_SLUG>/endline/uploaded_files_manifest.csv
#
# Writes:
#   data/qualtrics/<TEAM_SLUG>/endline/derived/average_screentime_for_annotation.csv
#   data/qualtrics/<TEAM_SLUG>/endline/derived/app_screentime_for_annotation.csv
#
# Notes:
# - Android prefix 1..7 is treated as "day-of-week screenshot" and stored as:
#     screenshot_day_prefix, screenshot_day
# - Twitter on endline Android uses your known misspelling:
#     _AndroidLaskWeekTw3_*
# ============================================================

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tidyr)
})

# ----------------------------
# CONFIG (EDIT THESE)
# ----------------------------
TEAM_SLUG <- "team_example"

OUT_DIR <- file.path("data", "qualtrics", TEAM_SLUG, "endline")
RESPONSES_CSV <- file.path(OUT_DIR, "responses.csv")
MANIFEST_CSV  <- file.path(OUT_DIR, "uploaded_files_manifest.csv")

DERIVED_DIR <- file.path(OUT_DIR, "derived")
dir.create(DERIVED_DIR, recursive = TRUE, showWarnings = FALSE)

AVG_OUT_CSV <- file.path(DERIVED_DIR, "average_screentime_for_annotation.csv")
APP_OUT_CSV <- file.path(DERIVED_DIR, "app_screentime_for_annotation.csv")

RESP_ID_COL <- "ResponseId"
DEVICE_COL  <- "iPhoneorAndroid3"

# ---- day-of-week mapping for Android prefix 1..7 (EDIT if needed) ----
PREFIX_TO_DAY <- c(
  "1" = "Monday",
  "2" = "Tuesday",
  "3" = "Wednesday",
  "4" = "Thursday",
  "5" = "Friday",
  "6" = "Saturday",
  "7" = "Sunday"
)
prefix_to_day <- function(prefix_int) unname(PREFIX_TO_DAY[as.character(prefix_int)])

# ----------------------------
# Helpers
# ----------------------------
normalize_device <- function(x) {
  x_chr <- tolower(trimws(as.character(x)))
  out <- ifelse(str_detect(x_chr, "android"), "Android",
                ifelse(str_detect(x_chr, "iphone|ios"), "iPhone", NA_character_))
  is_na <- is.na(out) | !nzchar(out)
  suppressWarnings({ x_num <- as.numeric(x_chr) })
  out[is_na & !is.na(x_num) & x_num == 1] <- "iPhone"
  out[is_na & !is.na(x_num) & x_num == 2] <- "Android"
  out
}

to_num <- function(x) suppressWarnings(as.numeric(as.character(x)))

mget_col_by_row <- function(df, col_names_vec) {
  df0 <- as.data.frame(df, stringsAsFactors = FALSE)
  stopifnot(length(col_names_vec) == nrow(df0))
  idx <- match(col_names_vec, names(df0))
  out <- rep(NA_character_, nrow(df0))
  ok  <- !is.na(idx)
  if (any(ok)) {
    rows <- which(ok)
    out[ok] <- as.character(df0[cbind(rows, idx[ok])])
  }
  out
}

pick_android_prefix <- function(df) {
  prefixes <- 1:7
  
  score_mat <- sapply(prefixes, function(p) {
    rx_main <- paste0("^", p, "_AndroidLastWeek(",
                      "SS[1-4]3_Id|",
                      "Tot3_[12]|",
                      "Inst3_[12]|",
                      "FB3_[12]|",
                      "TT3_[12]",
                      ")$")
    cols1 <- grep(rx_main, names(df), value = TRUE)
    
    # Twitter special case: AndroidLaskWeekTw3_*
    rx_tw <- paste0("^", p, "_AndroidLaskWeekTw3_[12]$")
    cols2 <- grep(rx_tw, names(df), value = TRUE)
    
    cols <- unique(c(cols1, cols2))
    if (length(cols) == 0) return(rep(0L, nrow(df)))
    
    x <- df[, cols, drop = FALSE]
    x <- as.data.frame(lapply(x, as.character), stringsAsFactors = FALSE)
    rowSums(!is.na(x) & nzchar(x))
  })
  
  if (is.null(dim(score_mat))) score_mat <- matrix(score_mat, nrow = nrow(df), byrow = TRUE)
  
  best_idx <- max.col(score_mat, ties.method = "first")
  best_score <- score_mat[cbind(seq_len(nrow(df)), best_idx)]
  
  out <- prefixes[best_idx]
  out[best_score == 0] <- NA_integer_
  out
}

get_col_or_na <- function(df, col) if (col %in% names(df)) df[[col]] else rep(NA, nrow(df))

ensure_cols <- function(df, cols, fill = NA_character_) {
  for (nm in cols) if (!nm %in% names(df)) df[[nm]] <- fill
  df
}

add_screenshot_paths <- function(df, manifest, id_col = "ResponseId") {
  file_id_cols <- grep("^ss[1-4]_file_id$", names(df), value = TRUE)
  if (length(file_id_cols) == 0) return(df)
  
  ss_long <- df %>%
    select(all_of(id_col), all_of(file_id_cols)) %>%
    pivot_longer(cols = all_of(file_id_cols), names_to = "ss_slot", values_to = "file_id") %>%
    mutate(
      file_id = as.character(file_id),
      ss_slot = str_replace(ss_slot, "_file_id$", "")
    ) %>%
    filter(!is.na(file_id) & nzchar(file_id))
  
  if (nrow(ss_long) == 0) return(df)
  
  by_map <- c(stats::setNames("response_id", id_col), "file_id" = "file_id")
  
  ss_long2 <- ss_long %>%
    left_join(
      manifest %>% select(response_id, file_id, saved_path, ok, http_status),
      by = by_map
    )
  
  ss_wide <- ss_long2 %>%
    select(all_of(id_col), ss_slot, saved_path) %>%
    pivot_wider(names_from = ss_slot, values_from = saved_path, values_fn = dplyr::first)
  
  names(ss_wide) <- sub("^(ss[1-4])$", "\\1_path", names(ss_wide))
  df %>% left_join(ss_wide, by = id_col)
}

# ----------------------------
# Load inputs
# ----------------------------
stopifnot(file.exists(RESPONSES_CSV))
stopifnot(file.exists(MANIFEST_CSV))

responses <- read_csv(RESPONSES_CSV, show_col_types = FALSE)
manifest  <- read_csv(MANIFEST_CSV, show_col_types = FALSE) %>%
  mutate(
    response_id = as.character(response_id),
    file_id     = as.character(file_id),
    saved_path  = as.character(saved_path)
  )

stopifnot(RESP_ID_COL %in% names(responses))
stopifnot(DEVICE_COL %in% names(responses))

responses <- responses %>% mutate(device = normalize_device(.data[[DEVICE_COL]]))

# ----------------------------
# Build canonical dataset
# ----------------------------

# iPhone endline
iphone_df <- responses %>%
  filter(device == "iPhone") %>%
  transmute(
    respondent_id = as.character(.data[[RESP_ID_COL]]),
    device,
    screenshot_day_prefix = NA_integer_,
    screenshot_day        = NA_character_,
    
    total_hours   = to_num(get_col_or_na(., "IPhoneLastWeekTotal3_1")),
    total_minutes = to_num(get_col_or_na(., "IPhoneLastWeekTotal3_2")),
    
    instagram_hours   = to_num(get_col_or_na(., "IPhoneLastWeekInsta3_1")),
    instagram_minutes = to_num(get_col_or_na(., "IPhoneLastWeekInsta3_2")),
    
    facebook_hours    = to_num(get_col_or_na(., "IPhoneLastWeekFB3_1")),
    facebook_minutes  = to_num(get_col_or_na(., "IPhoneLastWeekFB3_2")),
    
    tiktok_hours      = to_num(get_col_or_na(., "IPhoneLastWeekTT3_1")),
    tiktok_minutes    = to_num(get_col_or_na(., "IPhoneLastWeekTT3_2")),
    
    twitter_hours     = to_num(get_col_or_na(., "IPhoneLastWeekTwit3_1")),
    twitter_minutes   = to_num(get_col_or_na(., "IPhoneLastWeekTwit3_2")),
    
    ss1_file_id = as.character(get_col_or_na(., "IPhoneLastWeekSS13_Id")),
    ss2_file_id = as.character(get_col_or_na(., "IPhoneLastWeekSS23_Id")),
    ss3_file_id = as.character(get_col_or_na(., "IPhoneLastWeekSS33_Id")),
    ss4_file_id = as.character(get_col_or_na(., "IPhoneLastWeekSS43_Id"))
  )

# Android endline (prefix = day-of-week)
android_raw <- responses %>% filter(device == "Android")
android_prefix <- pick_android_prefix(android_raw)

android_df <- android_raw %>%
  mutate(android_prefix = android_prefix) %>%
  transmute(
    respondent_id = as.character(.data[[RESP_ID_COL]]),
    device,
    
    screenshot_day_prefix = as.integer(android_prefix),
    screenshot_day        = prefix_to_day(android_prefix),
    
    total_hours   = to_num(mget_col_by_row(android_raw, paste0(android_prefix, "_AndroidLastWeekTot3_1"))),
    total_minutes = to_num(mget_col_by_row(android_raw, paste0(android_prefix, "_AndroidLastWeekTot3_2"))),
    
    instagram_hours   = to_num(mget_col_by_row(android_raw, paste0(android_prefix, "_AndroidLastWeekInst3_1"))),
    instagram_minutes = to_num(mget_col_by_row(android_raw, paste0(android_prefix, "_AndroidLastWeekInst3_2"))),
    
    facebook_hours    = to_num(mget_col_by_row(android_raw, paste0(android_prefix, "_AndroidLastWeekFB3_1"))),
    facebook_minutes  = to_num(mget_col_by_row(android_raw, paste0(android_prefix, "_AndroidLastWeekFB3_2"))),
    
    tiktok_hours      = to_num(mget_col_by_row(android_raw, paste0(android_prefix, "_AndroidLastWeekTT3_1"))),
    tiktok_minutes    = to_num(mget_col_by_row(android_raw, paste0(android_prefix, "_AndroidLastWeekTT3_2"))),
    
    # Twitter special case (endline)
    twitter_hours     = to_num(mget_col_by_row(android_raw, paste0(android_prefix, "_AndroidLaskWeekTw3_1"))),
    twitter_minutes   = to_num(mget_col_by_row(android_raw, paste0(android_prefix, "_AndroidLaskWeekTw3_2"))),
    
    ss1_file_id = as.character(mget_col_by_row(android_raw, paste0(android_prefix, "_AndroidLastWeekSS13_Id"))),
    ss2_file_id = as.character(mget_col_by_row(android_raw, paste0(android_prefix, "_AndroidLastWeekSS23_Id"))),
    ss3_file_id = as.character(mget_col_by_row(android_raw, paste0(android_prefix, "_AndroidLastWeekSS33_Id"))),
    ss4_file_id = as.character(mget_col_by_row(android_raw, paste0(android_prefix, "_AndroidLastWeekSS43_Id")))
  )

canonical <- bind_rows(iphone_df, android_df) %>%
  rename(ResponseId = respondent_id) %>%
  mutate(ResponseId = as.character(ResponseId))

canonical <- ensure_cols(canonical, c(
  "screenshot_day_prefix","screenshot_day",
  "ss1_file_id","ss2_file_id","ss3_file_id","ss4_file_id"
), fill = NA_character_)

canonical2 <- add_screenshot_paths(canonical, manifest, id_col = "ResponseId")
canonical2 <- ensure_cols(canonical2, c("ss1_path","ss2_path","ss3_path","ss4_path"), fill = NA_character_)

# ----------------------------
# Output files
# ----------------------------
avg_out <- canonical2 %>%
  transmute(
    respondent_id = ResponseId,
    device,
    screenshot_day_prefix,
    screenshot_day,
    total_hours,
    total_minutes,
    total_screenshot_file_id = ss1_file_id,
    total_screenshot_path    = ss1_path
  )

app_out <- canonical2 %>%
  transmute(
    respondent_id = ResponseId,
    device,
    screenshot_day_prefix,
    screenshot_day,
    instagram_hours, instagram_minutes,
    facebook_hours,  facebook_minutes,
    tiktok_hours,    tiktok_minutes,
    twitter_hours,   twitter_minutes,
    app_screenshot1_file_id = ss2_file_id,
    app_screenshot1_path    = ss2_path,
    app_screenshot2_file_id = ss3_file_id,
    app_screenshot2_path    = ss3_path,
    app_screenshot3_file_id = ss4_file_id,
    app_screenshot3_path    = ss4_path
  )

write_csv(avg_out, AVG_OUT_CSV)
write_csv(app_out, APP_OUT_CSV)

message("✅ Endline wrangle complete:")
message(" - ", AVG_OUT_CSV)
message(" - ", APP_OUT_CSV)
