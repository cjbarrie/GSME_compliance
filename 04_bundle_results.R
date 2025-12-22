#!/usr/bin/env Rscript

# ============================================================
# 04_bundle_results.R
#
# Creates a single ZIP bundle to send back after annotation.
#
# Produces:
#   data/qualtrics/<TEAM_SLUG>/<WAVE>/results/
#     bundle_<TEAM_SLUG>_<WAVE>_<timestamp>.zip
#
# Run:
#   Rscript 04_bundle_results.R
# ============================================================

suppressPackageStartupMessages({
  library(stringr)
})

# ----------------------------
# CONFIG (EDIT THESE)
# ----------------------------
TEAM_SLUG <- "team_example"
WAVE <- "baseline"   # "baseline" or "endline"

# Files we try to include (if present)
FILES_TO_BUNDLE <- c(
  "annotations_avg.csv",
  "annotations_app.csv",
  "sample_avg.csv",
  "sample_app.csv"
)

# ----------------------------
# Helpers
# ----------------------------

# Get directory of this script (works for Rscript --file=...)
get_script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- args[grepl("^--file=", args)]
  if (length(file_arg) == 0) return(normalizePath(getwd(), winslash = "/", mustWork = TRUE))
  script_path <- sub("^--file=", "", file_arg[1])
  normalizePath(dirname(script_path), winslash = "/", mustWork = TRUE)
}

timestamp_str <- function() format(Sys.time(), "%Y%m%d_%H%M%S")

write_manifest <- function(results_dir, included_files) {
  manifest_path <- file.path(results_dir, "bundle_manifest.txt")
  lines <- c(
    paste0("TEAM_SLUG: ", TEAM_SLUG),
    paste0("WAVE: ", WAVE),
    paste0("CREATED_AT: ", as.character(Sys.time())),
    "",
    "FILES_INCLUDED:",
    paste0(" - ", included_files)
  )
  writeLines(lines, manifest_path, useBytes = TRUE)
  manifest_path
}

# Zip from inside results_dir so paths inside zip are clean
make_zip_in_dir <- function(results_dir, zip_path, files_rel) {
  old <- getwd()
  on.exit(setwd(old), add = TRUE)
  setwd(results_dir)
  
  # Only include files that exist *in results_dir*
  files_rel <- files_rel[file.exists(files_rel)]
  if (length(files_rel) == 0) stop("No files to zip found in results dir.", call. = FALSE)
  
  utils::zip(zipfile = zip_path, files = files_rel)
  invisible(zip_path)
}

# ----------------------------
# Main
# ----------------------------

BASE_DIR <- get_script_dir()

RESULTS_DIR <- file.path(BASE_DIR, "data", "qualtrics", TEAM_SLUG, WAVE, "results")

if (!dir.exists(RESULTS_DIR)) {
  stop("Results directory not found:\n  ", RESULTS_DIR, "\n\n",
       "Did you run 03_run_app.R and complete at least one task?",
       call. = FALSE)
}

# Determine which expected files exist
existing_rel <- FILES_TO_BUNDLE[file.exists(file.path(RESULTS_DIR, FILES_TO_BUNDLE))]

if (length(existing_rel) == 0) {
  stop(
    "No result files found to bundle in:\n  ", RESULTS_DIR, "\n\n",
    "Expected at least one of:\n  - ", paste(FILES_TO_BUNDLE, collapse = "\n  - "), "\n\n",
    "Run 03_run_app.R and complete/save some annotations first.",
    call. = FALSE
  )
}

# Write manifest into results dir (include it too)
manifest_path <- write_manifest(RESULTS_DIR, included_files = existing_rel)
manifest_rel  <- basename(manifest_path)

# Create zip
zip_name <- paste0("bundle_", TEAM_SLUG, "_", WAVE, "_", timestamp_str(), ".zip")
zip_path <- file.path(RESULTS_DIR, zip_name)

files_rel <- c(existing_rel, manifest_rel)

make_zip_in_dir(results_dir = RESULTS_DIR, zip_path = zip_path, files_rel = files_rel)

cat("✅ Bundle created:\n  ", zip_path, "\n\n", sep = "")
cat("Includes:\n")
cat(paste0(" - ", files_rel), sep = "\n")
cat("\n")
