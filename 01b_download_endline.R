#!/usr/bin/env Rscript

# ============================================================
# 01_download_endline.R
#
# Downloads endline Qualtrics responses + uploaded files.
#
# Outputs:
#   data/qualtrics/<TEAM_SLUG>/endline/responses.csv
#   data/qualtrics/<TEAM_SLUG>/endline/uploaded_files_manifest.csv
#   data/qualtrics/<TEAM_SLUG>/endline/uploads/<ResponseId>/*
#
# Requires:
#   Sys.setenv(QUALTRICS_API_KEY="...")  # or ~/.Renviron
# ============================================================

suppressPackageStartupMessages({
  library(qualtRics)
  library(httr)
  library(readr)
})

# ----------------------------
# CONFIG (EDIT THESE)
# ----------------------------
BASE_URL <- "ca1.qualtrics.com"

TEAM_SLUG <- "team_example"   # <-- change per team
SURVEY_ID <- "SV_cHhAEVcpXcmnFPM"  # <-- your endline survey id

OUT_DIR <- file.path("data", "qualtrics", TEAM_SLUG, "endline")

# Resume controls
FORCE_RESPONSES <- FALSE
FORCE_UPLOADS   <- FALSE

# ----------------------------
# Retry helper
# ----------------------------
with_retry <- function(expr_fn, tries = 8, base_sleep = 1, max_sleep = 30) {
  last_err <- NULL
  for (k in seq_len(tries)) {
    out <- tryCatch(expr_fn(), error = function(e) { last_err <<- e; NULL })
    if (!is.null(out)) return(out)
    s <- min(max_sleep, base_sleep * (2^(k - 1))) + runif(1, 0, 0.5)
    message(sprintf("Retry %d/%d after error; sleeping %.1fs ...", k, tries, s))
    Sys.sleep(s)
  }
  stop(last_err)
}

# ----------------------------
# Qualtrics helpers
# ----------------------------
get_api_key <- function(env_var = "QUALTRICS_API_KEY") {
  key <- Sys.getenv(env_var, unset = NA_character_)
  if (is.na(key) || !nzchar(key)) {
    stop(
      sprintf("Missing %s. Set it with Sys.setenv(%s='...') or in your .Renviron.",
              env_var, env_var),
      call. = FALSE
    )
  }
  key
}

setup_qualtrics <- function(base_url = BASE_URL, env_var = "QUALTRICS_API_KEY") {
  api_key <- get_api_key(env_var)
  qualtrics_api_credentials(api_key = api_key, base_url = base_url, install = FALSE)
  invisible(api_key)
}

download_responses <- function(survey_id, out_csv, force = FALSE) {
  if (file.exists(out_csv) && !isTRUE(force)) {
    message("responses.csv already exists; skipping (set FORCE_RESPONSES=TRUE to override): ", out_csv)
    return(read_csv(out_csv, show_col_types = FALSE))
  }
  
  df <- with_retry(function() {
    fetch_survey(
      surveyID = survey_id,
      force_request = TRUE,
      verbose = TRUE,
      label = FALSE,
      convert = FALSE
    )
  }, tries = 8)
  
  dir.create(dirname(out_csv), recursive = TRUE, showWarnings = FALSE)
  write_csv(df, out_csv)
  df
}

find_response_id_col <- function(df) {
  candidates <- c("ResponseId", "responseid", "response_id", "responseId")
  col <- intersect(candidates, names(df))
  if (length(col) == 0) stop("Could not find a ResponseId column in the downloaded data.", call. = FALSE)
  col[[1]]
}

find_file_id_columns <- function(df) {
  is_file_col <- vapply(df, function(x) {
    x <- as.character(x)
    any(grepl("^F_[A-Za-z0-9]", x[!is.na(x) & nzchar(x)]))
  }, logical(1))
  names(df)[is_file_col]
}

parse_content_disposition_filename <- function(cd) {
  if (is.null(cd) || !nzchar(cd)) return(NA_character_)
  m <- regexec('filename\\*?="?([^";]+)"?', cd, ignore.case = TRUE)
  r <- regmatches(cd, m)[[1]]
  if (length(r) >= 2) r[[2]] else NA_character_
}

download_one_uploaded_file <- function(base_url, api_key, survey_id, response_id, file_id, dest_path) {
  url <- sprintf(
    "https://%s/API/v3/surveys/%s/responses/%s/uploaded-files/%s",
    base_url, survey_id, response_id, file_id
  )
  
  dir.create(dirname(dest_path), recursive = TRUE, showWarnings = FALSE)
  
  resp <- with_retry(function() {
    GET(
      url,
      add_headers(`X-API-TOKEN` = api_key, Accept = "*/*"),
      write_disk(dest_path, overwrite = TRUE)
    )
  }, tries = 6)
  
  if (http_error(resp)) {
    if (file.exists(dest_path)) file.remove(dest_path)
    return(list(ok = FALSE, status = status_code(resp), path = NA_character_, cd = NA_character_))
  }
  
  list(ok = TRUE, status = status_code(resp), path = dest_path, cd = headers(resp)[["content-disposition"]])
}

download_uploaded_files <- function(df, survey_id, out_dir, base_url = BASE_URL, env_var = "QUALTRICS_API_KEY", force = FALSE) {
  manifest_path <- file.path(out_dir, "uploaded_files_manifest.csv")
  if (file.exists(manifest_path) && !isTRUE(force)) {
    message("uploaded_files_manifest.csv already exists; skipping uploads download (set FORCE_UPLOADS=TRUE to override): ", manifest_path)
    return(read_csv(manifest_path, show_col_types = FALSE))
  }
  
  api_key <- get_api_key(env_var)
  
  response_col <- find_response_id_col(df)
  file_cols <- find_file_id_columns(df)
  
  if (length(file_cols) == 0) {
    message("No file-upload IDs detected in this dataset. Nothing to download.")
    write_csv(data.frame(), manifest_path)
    return(invisible(data.frame()))
  }
  
  df_chr <- df
  df_chr[] <- lapply(df_chr, as.character)
  
  manifest <- list()
  
  for (i in seq_len(nrow(df_chr))) {
    response_id <- df_chr[[response_col]][i]
    if (is.na(response_id) || !nzchar(response_id)) next
    
    file_ids <- unique(na.omit(unlist(df_chr[i, file_cols, drop = FALSE], use.names = FALSE)))
    file_ids <- file_ids[grepl("^F_[A-Za-z0-9]", file_ids)]
    if (length(file_ids) == 0) next
    
    for (file_id in file_ids) {
      resp_dir <- file.path(out_dir, "uploads", response_id)
      tmp_path <- file.path(resp_dir, paste0(file_id, ".bin"))
      
      res <- download_one_uploaded_file(base_url, api_key, survey_id, response_id, file_id, tmp_path)
      
      final_path <- res$path
      if (isTRUE(res$ok)) {
        fn <- parse_content_disposition_filename(res$cd)
        if (!is.na(fn) && nzchar(fn)) {
          final_path2 <- file.path(resp_dir, fn)
          file.rename(tmp_path, final_path2)
          final_path <- final_path2
        }
      }
      
      manifest[[length(manifest) + 1]] <- data.frame(
        response_id = response_id,
        file_id     = file_id,
        ok          = isTRUE(res$ok),
        http_status = res$status,
        saved_path  = ifelse(isTRUE(res$ok), final_path, NA_character_),
        stringsAsFactors = FALSE
      )
    }
  }
  
  out <- if (length(manifest)) do.call(rbind, manifest) else data.frame()
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  write_csv(out, manifest_path)
  out
}

# ----------------------------
# RUN
# ----------------------------
if (is.na(SURVEY_ID) || !nzchar(SURVEY_ID)) stop("SURVEY_ID is blank.", call. = FALSE)

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
setup_qualtrics(BASE_URL)

responses_csv <- file.path(OUT_DIR, "responses.csv")
df <- download_responses(SURVEY_ID, responses_csv, force = FORCE_RESPONSES)
download_uploaded_files(df, SURVEY_ID, OUT_DIR, BASE_URL, force = FORCE_UPLOADS)

message("✅ Endline download complete:")
message(" - ", responses_csv)
message(" - ", file.path(OUT_DIR, "uploaded_files_manifest.csv"))
message(" - ", file.path(OUT_DIR, "uploads"))
