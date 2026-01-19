# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a two-stage screenshot compliance-check pipeline for the Global Social Media Experiment (GSME).

**Country Survey Teams** download Qualtrics data, manually annotate 100 avg + 100 app screenshots (randomly sampled), and send results to leadership.

**Leadership Team** (Chris Barrie) receives bundles, runs AI validation on the same screenshots, and measures human-AI agreement.

The workflow handles both **baseline** (pre-experiment) and **endline** (post-experiment) surveys for **iPhone** and **Android** devices. Android surveys use day-of-week branching with prefixes 1-7 corresponding to Monday-Sunday.

## Country Team Workflow

1. **Download**: `01_download.R`
   - Fetches Qualtrics survey responses and uploaded screenshot files
   - Set `WAVE <- "baseline"` or `WAVE <- "endline"` in the config section
   - Requires `QUALTRICS_API_KEY` environment variable
   - Outputs: `responses.csv`, `uploaded_files_manifest.csv`, and `uploads/` directory

2. **Wrangle**: `02_wrangle.R`
   - Processes responses into standardized CSVs for annotation
   - Set `WAVE` to match the download script
   - Handles Android day-of-week prefix detection (1-7)
   - Uses wave-specific column mappings for baseline vs endline Qualtrics fields
   - Outputs: `average_screentime_for_annotation.csv` and `app_screentime_for_annotation.csv`

3. **Annotate**: `03_run_app.R`
   - Launches interactive Shiny app for manual screenshot review
   - Auto-saves on navigation (Next/Prev/Go buttons)
   - Creates stable random samples on first run (100 avg + 100 app by default)
   - Enforces sequential workflow: Average tasks → App-level tasks → Done
   - Outputs: `sample_avg.csv`, `sample_app.csv`, `annotations_avg.csv`, `annotations_app.csv`

4. **Bundle**: `04_bundle_results.R`
   - Creates ZIP file containing samples and annotations
   - ZIP is sent to compliance lead (cb5691@nyu.edu)

## Leadership Team Workflow

After receiving bundles from country teams:

1. **Extract bundle**: Unzip country team bundle into appropriate directory

2. **AI Validation**: `11_auto_validate.py`
   - Reads `sample_avg.csv` and `sample_app.csv` from country team bundle
   - Validates the EXACT SAME screenshots that humans annotated
   - Uses OpenRouter Vision API (Claude 3.5 Sonnet by default)
   - Asks the same two questions: (1) Is this the correct type of screenshot? (2) Do the numbers match what was reported?
   - Provides context to AI: Device type, day of week (Android), reported values
   - Outputs: `auto_annotations_avg.csv` and `auto_annotations_app.csv`

3. **Agreement Analysis**: `12_compare_annotations.R`
   - Compares human vs AI annotations task-by-task
   - Calculates agreement metrics (Cohen's kappa, confusion matrices)
   - Identifies disagreement patterns
   - Outputs: `agreement_report_avg.csv`, `agreement_report_app.csv`, `agreement_summary.txt`

4. **Upload Times**: `13_upload_times.R`
   - Extracts screenshot upload durations from Qualtrics timer fields
   - Reports median/mean/range by device type
   - Outputs: `upload_times.csv`

5. **Device Consistency**: `14_device_consistency.R`
   - Compares OS and browser between baseline and endline waves
   - Flags respondents who switched devices between waves
   - Outputs: `device_consistency.csv` (at team level, not wave level)

6. **Tamper Detection**: `15_edge_anomaly.py`
   - Uses TruFor neural network for image manipulation detection
   - OCRs digit-bearing regions and computes ROI-level anomaly scores
   - Flags images exceeding global or ROI thresholds
   - Requires: TruFor repo, weights (auto-downloaded), Tesseract OCR
   - Outputs: `trufor_report.csv`, cropped regions in `trufor_crops/`

7. **Reverse Image Search**: `16_web_detection_check.py`
   - Uses Google Cloud Vision Web Detection API
   - Finds matching images on the web (TinEye-like functionality)
   - Flags "full matching images" as potential stock/copied screenshots
   - Requires: `GOOGLE_APPLICATION_CREDENTIALS` service account
   - Outputs: `web_detection_report.csv`

8. **Combine All Outputs**: `17_combine_all.R`
   - Combines all compliance check outputs into a single tidy CSV
   - One row per respondent with both baseline and endline data
   - Converts Yes/No/Unsure to binary (1/0/NA)
   - Handles missing files gracefully (columns will be NA)
   - Outputs: `combined_compliance_report.csv` at team level

## Key Configuration

Before running scripts, teams must edit these variables:

- `TEAM_SLUG`: ISO2 country code (e.g., "GB", "US", "team_example")
- `SURVEY_ID`: Found in Qualtrics survey URL, starts with `SV_`
- `BASE_URL`: Qualtrics data center (e.g., "ca1.qualtrics.com")
- `WAVE`: Either "baseline" or "endline"
- `PARTICIPANT_ID_COL`: Column name in Qualtrics containing stable participant ID (e.g., "ID")
- `GENERATE_DUMMY_IDS`: Set to `TRUE` for test data to auto-generate placeholder IDs

## Architecture Notes

### Participant ID for Cross-Wave Matching
The pipeline uses a `participant_id` field to link respondents across baseline and endline waves:

- **Why needed**: Qualtrics assigns different `ResponseId` values for each survey completion. A stable participant ID (e.g., from a panel provider) is needed to track the same person across waves.
- **Configuration in 02_wrangle.R**:
  - `PARTICIPANT_ID_COL`: Name of the Qualtrics column containing the stable ID (default: `"ID"`)
  - `GENERATE_DUMMY_IDS`: When `TRUE`, generates placeholder IDs (`P001`, `P002`, ...) for test data
- **Propagation**: The `participant_id` flows through:
  1. `02_wrangle.R` → `derived/*_for_annotation.csv`
  2. `03_run_app.R` → `results/sample_*.csv`
  3. `14_device_consistency.R` → joins baseline/endline on `participant_id`
  4. `17_combine_all.R` → joins baseline/endline on `participant_id`
- **Output columns**: The combined report includes both `participant_id` (stable) and wave-specific `bl_respondent_id`/`el_respondent_id` (Qualtrics ResponseIds)

### Device Detection and Standardization
The wrangle script normalizes device values to standardized format:
- **iOS**: Derived from "iPhone", "iOS", "iphone", or numeric value 1
- **Android**: Derived from "Android", "android", or numeric value 2
- Field stored as `device` ∈ {"iOS", "Android", NA}
- Uses `normalize_device()` function in 02_wrangle.R:107-118

### Android Day-of-Week Branching
Android surveys repeat question blocks with prefixes 1-7 for different days. The wrangle script:
- Detects which prefix has data for each respondent via `pick_android_prefix()` function
- Stores `screenshot_day_prefix` (integer 1-7) and `screenshot_day` (Monday-Sunday)
- Maps prefixes using `PREFIX_TO_DAY` dictionary (02_wrangle.R:95-103)
- Calculates `android_target_date` (YYYY-MM-DD) for the calendar date corresponding to that day in "last week" relative to survey completion
- Uses `EndDate` field from Qualtrics and `calculate_android_target_date()` function (02_wrangle.R:122-149)

### Wave-Specific Column Mappings
The wrangle script uses a `WAVE_CONFIG` structure (02_wrangle.R:48-93) to handle different Qualtrics column names between baseline and endline surveys:
- **Baseline**: Uses column names like `IPhoneReportTotal2_*`, `1_AndroidReportTotal2_*`
- **Endline**: Uses column names like `IPhoneLastWeekTotal3_*`, `1_AndroidLastWeekTot3_*`
- Preserves known typo in endline Android Twitter columns (`AndroidLaskWeekTw3_*`)

### Shiny App State Management
The annotation app (03_run_app.R) uses reactive state to:
- Track phase progression: "avg" → "app" → "done"
- Auto-save annotations on every navigation action
- Prefill form fields when returning to previously annotated tasks
- Prevent phase regression
- Display context metadata to annotators:
  - Device type (iOS or Android)
  - For Android: Day of week and calendar date (lines 525-542)
  - Reported screentime values to compare against screenshots

### Sample Stability
On first run, the app creates `sample_avg.csv` and `sample_app.csv` with stable random samples (seed: 12345 by default). These files persist across runs to prevent task list changes. Delete them to regenerate samples.

### File Path Mapping
The wrangle scripts join `uploaded_files_manifest.csv` with responses to create `*_path` columns pointing to local screenshot files. The Shiny app renders these via `renderImage()` with `deleteFile = FALSE` to serve local files correctly.

### Critical Fields for AI Validation
The wrangling scripts produce standardized datasets with these fields required for reliable annotation:

**For all respondents:**
- `respondent_id`: Wave-specific Qualtrics ResponseId
- `participant_id`: Stable cross-wave identifier (from `PARTICIPANT_ID_COL` or generated)
- `device`: Standardized as "iOS" or "Android" (not "iPhone")
- `end_date`: Survey completion timestamp from Qualtrics `EndDate` field
- `total_hours`, `total_minutes`: Reported screentime values

**For Android respondents only:**
- `screenshot_day_prefix`: Integer 1-7 (inferred from which survey branch has data)
- `screenshot_day`: Day name "Monday" through "Sunday"
- `android_target_date`: Calculated calendar date (YYYY-MM-DD) for the target day in "last week"

**For iOS respondents:**
- `screenshot_day_prefix`, `screenshot_day`, `android_target_date`: All set to NA

These fields flow through `derived/*_for_annotation.csv` → `results/sample_*.csv` → AI validation.

### AI Validation Architecture (11_auto_validate.py)
The AI validation script uses OpenRouter's Vision API to analyze screenshots:
- **Uses country team samples**: Reads `sample_avg.csv` and `sample_app.csv` to validate the exact same screenshots humans annotated
- **Task ID matching**: Preserves task_ids from sample files to enable direct comparison with human annotations
- **Mimics manual workflow**: Asks the same two questions as human annotators with identical context
- **Context-aware prompts**: Provides the AI with:
  - Device type ("iOS" or "Android")
  - For Android users: Day of week name (e.g., "Friday") AND calendar date (e.g., "2025-12-19")
  - Reported screentime values for comparison
  - Explicit instructions to verify both day name and calendar date match for Android screenshots
- **Specific visual validation criteria**:
  - iOS: Must show "Last Week's Average" with "Week" tab and S-M-T-W-T-F-S calendar bar chart
  - iOS: REJECTS "Last 7 Days" (rolling window, not calendar week)
  - Android: Must show specific date prominently from Digital Wellbeing Dashboard
  - Checks for correct source app (Settings → Screen Time for iOS, Digital Wellbeing for Android)
- **Multi-image support**: For app-level tasks, sends all 3 screenshots in a single API call
- **Structured responses**: Uses temperature=0 and JSON response formatting for consistent Yes/No/Unsure answers
- **Rate limiting**: Configurable sleep between requests (default: 6 seconds per request for 10 req/min)
- **Retry logic**: Exponential backoff with configurable attempts (default: 5)
- **Output schema**: Same fields as manual annotations (`screenshot_correct`, `numbers_match`, `notes`) plus metadata

### Agreement Analysis Architecture (12_compare_annotations.R)
The agreement analysis script measures human-AI concordance:
- **Task-level comparison**: Merges human and AI annotations by task_id using dplyr's `inner_join()`
- **Metadata enrichment**: Merges in task metadata (device, screenshot_day, android_target_date) from sample files for context
- **Response normalization**: Handles variations in Yes/No/Unsure formatting using custom `normalize_response()` function
- **Agreement metrics**: Calculates overall agreement percentage and Cohen's kappa using R's `irr` package
- **Confusion matrices**: Shows patterns of human→AI response transitions using `table()` with factored levels
- **Disagreement patterns**: Identifies common types of disagreements (e.g., Yes→No, Unsure→Yes)
- **Per-question analysis**: Separate metrics for "screenshot_correct" and "numbers_match"
- **Both-questions agreement**: Percentage of tasks where both questions match
- **Outputs**: CSV files for task-level review (including device/date context for each task) and text summary with statistical overview (using `sink()` for file output)

### Upload Times Architecture (13_upload_times.R)
Extracts page-submit timer values from Qualtrics responses:
- **Wave-specific config**: Uses `WAVE_CONFIG` structure for column mappings like 02_wrangle.R
- **Timer columns**:
  - Baseline iOS: `SSiPhonetimer2_Page Submit`, `SSiPhoneTimer22_Page Submit`
  - Endline iOS: `SSiPhonetimer3_Page Submit`, `SSiPhoneTimer23_Page Submit`
  - Android: Prefixed versions `{1-7}_SSAndroidtimer{2|3}_Page Submit`
- **Device column**: `iPhoneorAndroid2` (baseline) or `iPhoneorAndroid3` (endline)
- **Android prefix detection**: Reuses same logic as wrangle scripts to find which day prefix has data
- **Output**: `upload_times.csv` with `respondent_id`, `device`, `avg_upload_sec`, `app_upload_sec`
- **Summary stats**: Prints median, mean, range by device type

### Device Consistency Architecture (14_device_consistency.R)
Compares respondent device/browser across survey waves:
- **Data source**: Reads from wrangled files (`derived/average_screentime_for_annotation.csv`) which contain `participant_id`
- **Cross-wave join**: Matches respondents by `participant_id` between baseline and endline
- **OS/Browser extraction**: Uses Qualtrics metadata fields `OSInfo2_*` (baseline) and `OSInfo3_*` (endline) from raw responses
- **Mismatch detection**: Flags respondents where device, OS, or browser changed between waves
- **Output columns**: `participant_id`, device/os/browser for each wave, `device_match`, `os_match`, `browser_match`
- **Output**: `device_consistency.csv` at team level (not per-wave)

### TruFor Tamper Detection Architecture (15_edge_anomaly.py)
Neural network-based image manipulation detection:
- **TruFor integration**: Runs external TruFor inference script via subprocess
- **Output parsing**: Auto-detects array keys in .npz output by shape/name heuristics (handles version differences)
- **Three signals**: Global integrity score, localization map (per-pixel suspicion), reliability map
- **OCR-guided ROI**: Uses Tesseract to find digit-bearing lines (screen time numbers)
- **ROI anomaly score**: `mean(localization * reliability_mask)` within OCR bounding boxes
- **Dual threshold flagging**: Flags if global score ≥ 0.50 OR max ROI score ≥ 0.22
- **Crop saving**: Saves padded crops of flagged ROIs for manual review

### Web Detection Architecture (16_web_detection_check.py)
Google Cloud Vision reverse image search:
- **API**: Uses `web_detection()` endpoint, not label detection
- **Match types**: Distinguishes full_matching_images (exact), partial_matching_images (variants), pages_with_matching_images
- **TinEye analogue**: Only flags "full matching images" as "match" status
- **Rate limiting**: Configurable sleep between requests (default 1s)
- **Output**: Per-image report with match counts, top URLs, and domains

### Combined Report Architecture (17_combine_all.R)
Aggregates all compliance outputs into a single tidy dataset:
- **One row per participant**: Combines baseline and endline data using full outer join on `participant_id`
- **ID columns**: Includes `participant_id` (stable), `bl_respondent_id`, `el_respondent_id` (wave-specific)
- **Binary encoding**: Converts Yes/No/Unsure to 1/0/NA for analysis
- **Column naming convention**:
  - `bl_`/`el_` prefix: baseline/endline wave
  - `avg`/`app`: average screentime / app-level screenshots
  - `h`/`ai`: human / AI annotation source
  - `_correct`: screenshot is correct type
  - `_match`: reported numbers match screenshot
  - `_trufor_flagged`: TruFor tamper detection flag
  - `_web_match`: web detection found matching image
  - `device_changed`: device/browser changed between waves
- **Cross-wave join**: Uses `participant_id` from sample files (not `respondent_id`) to correctly link baseline and endline data
- **Device consistency**: Joins on `participant_id` from `device_consistency.csv`
- **Graceful handling**: Missing files result in NA columns, not errors
- **Aggregation for multi-image tasks**: TruFor/web detection results aggregated with "any flagged" logic for app screenshots
- **Output**: `combined_compliance_report.csv` at team level (not per-wave)

## Running Scripts

### Country Teams

```bash
# Baseline workflow
# Edit 01_download.R: set TEAM_SLUG, SURVEY_ID, WAVE="baseline"
# Edit 02_wrangle.R: set TEAM_SLUG, WAVE="baseline"
# Edit 03_run_app.R: set TEAM_SLUG, WAVE="baseline"
Rscript 01_download.R
Rscript 02_wrangle.R
Rscript 03_run_app.R
Rscript 04_bundle_results.R
# Send bundle_<TEAM_SLUG>_baseline_<timestamp>.zip to cb5691@nyu.edu

# Endline workflow
# Edit 01_download.R: set SURVEY_ID (endline), WAVE="endline"
# Edit 02_wrangle.R: set WAVE="endline"
# Edit 03_run_app.R: set WAVE="endline"
Rscript 01_download.R
Rscript 02_wrangle.R
Rscript 03_run_app.R
Rscript 04_bundle_results.R
# Send bundle_<TEAM_SLUG>_endline_<timestamp>.zip to cb5691@nyu.edu
```

### Leadership Team

```bash
# For each country team bundle received:

# 1. Extract bundle
unzip bundle_GB_baseline_20260115.zip -d data/qualtrics/GB/baseline/results/

# 2. Edit TEAM_SLUG and WAVE in 11_auto_validate.py
python 11_auto_validate.py

# 3. Edit TEAM_SLUG and WAVE in 12_compare_annotations.R
Rscript 12_compare_annotations.R

# 4. Review agreement_summary.txt for results

# Optional: Additional compliance checks
Rscript 13_upload_times.R        # Analyze upload durations
Rscript 14_device_consistency.R  # Compare devices across waves

# Optional: Image authenticity checks (require external tools)
# See "Example Commands for Image Authenticity Checks" section below

# 8. Combine all outputs into final report
# Edit TEAM_SLUG in 17_combine_all.R
Rscript 17_combine_all.R
# Output: data/qualtrics/GB/combined_compliance_report.csv
```

### Example Commands for Image Authenticity Checks

These commands require external tools (TruFor repo, Google Cloud Vision API).
Replace `<TEAM>` with the team slug (e.g., `GB`, `US`) and adjust paths as needed.

**TruFor Tamper Detection (15_edge_anomaly.py):**

```bash
# Baseline - average screenshots
python 15_edge_anomaly.py --trufor_root ~/repos/TruFor \
  --csv data/qualtrics/<TEAM>/baseline/results/sample_avg.csv \
  --out_csv data/qualtrics/<TEAM>/baseline/results/trufor_report_avg.csv \
  --out_dir data/qualtrics/<TEAM>/baseline/results/trufor_npz \
  --crops_dir data/qualtrics/<TEAM>/baseline/results/trufor_crops \
  --path_cols total_screenshot_path

# Baseline - app screenshots
python 15_edge_anomaly.py --trufor_root ~/repos/TruFor \
  --csv data/qualtrics/<TEAM>/baseline/results/sample_app.csv \
  --out_csv data/qualtrics/<TEAM>/baseline/results/trufor_report_app.csv \
  --out_dir data/qualtrics/<TEAM>/baseline/results/trufor_npz \
  --crops_dir data/qualtrics/<TEAM>/baseline/results/trufor_crops \
  --path_cols app_screenshot1_path,app_screenshot2_path,app_screenshot3_path

# Endline - average screenshots
python 15_edge_anomaly.py --trufor_root ~/repos/TruFor \
  --csv data/qualtrics/<TEAM>/endline/results/sample_avg.csv \
  --out_csv data/qualtrics/<TEAM>/endline/results/trufor_report_avg.csv \
  --out_dir data/qualtrics/<TEAM>/endline/results/trufor_npz \
  --crops_dir data/qualtrics/<TEAM>/endline/results/trufor_crops \
  --path_cols total_screenshot_path

# Endline - app screenshots
python 15_edge_anomaly.py --trufor_root ~/repos/TruFor \
  --csv data/qualtrics/<TEAM>/endline/results/sample_app.csv \
  --out_csv data/qualtrics/<TEAM>/endline/results/trufor_report_app.csv \
  --out_dir data/qualtrics/<TEAM>/endline/results/trufor_npz \
  --crops_dir data/qualtrics/<TEAM>/endline/results/trufor_crops \
  --path_cols app_screenshot1_path,app_screenshot2_path,app_screenshot3_path
```

**Web Detection / Reverse Image Search (16_web_detection_check.py):**

```bash
# Baseline - average screenshots
python 16_web_detection_check.py \
  --csv data/qualtrics/<TEAM>/baseline/results/sample_avg.csv \
  --out_csv data/qualtrics/<TEAM>/baseline/results/web_detection_report_avg.csv

# Baseline - app screenshots
python 16_web_detection_check.py \
  --csv data/qualtrics/<TEAM>/baseline/results/sample_app.csv \
  --out_csv data/qualtrics/<TEAM>/baseline/results/web_detection_report_app.csv

# Endline - average screenshots
python 16_web_detection_check.py \
  --csv data/qualtrics/<TEAM>/endline/results/sample_avg.csv \
  --out_csv data/qualtrics/<TEAM>/endline/results/web_detection_report_avg.csv

# Endline - app screenshots
python 16_web_detection_check.py \
  --csv data/qualtrics/<TEAM>/endline/results/sample_app.csv \
  --out_csv data/qualtrics/<TEAM>/endline/results/web_detection_report_app.csv
```

## Environment Variables

- `QUALTRICS_API_KEY`: Required for download scripts (set via `~/.Renviron` or `export`)
- `OPENROUTER_API_KEY`: Required for auto-validation script (set in `.env` file)
- `GOOGLE_APPLICATION_CREDENTIALS`: Path to GCP service account JSON for web detection script
- `ANNOT_SEED`: Override random seed for sampling (default: 12345)
- `ANNOT_N_AVG`: Override average task sample size (default: 100)
- `ANNOT_N_APP`: Override app-level task sample size (default: 100)

## Directory Structure

```
data/qualtrics/<TEAM_SLUG>/
├── combined_compliance_report.csv   # Final combined report (17_)
├── device_consistency.csv           # Cross-wave device comparison (14_)
├── baseline/
│   ├── responses.csv                # Raw Qualtrics export
│   ├── uploaded_files_manifest.csv  # File ID to path mapping
│   ├── uploads/<ResponseId>/        # Downloaded screenshots
│   ├── derived/
│   │   ├── average_screentime_for_annotation.csv
│   │   └── app_screentime_for_annotation.csv
│   └── results/
│       ├── sample_avg.csv           # Stable random sample (avg tasks)
│       ├── sample_app.csv           # Stable random sample (app tasks)
│       ├── annotations_avg.csv      # Manual annotations (avg)
│       ├── annotations_app.csv      # Manual annotations (app)
│       ├── auto_annotations_avg.csv # AI auto-validation (avg)
│       ├── auto_annotations_app.csv # AI auto-validation (app)
│       ├── agreement_report_avg.csv # Human vs AI comparison
│       ├── agreement_report_app.csv
│       ├── agreement_summary.txt    # Agreement statistics
│       ├── upload_times.csv         # Screenshot upload durations (13_)
│       ├── trufor_report_avg.csv    # Tamper detection - avg screenshots (15_)
│       ├── trufor_report_app.csv    # Tamper detection - app screenshots (15_)
│       ├── trufor_npz/              # TruFor raw outputs
│       ├── trufor_crops/            # Flagged region crops
│       ├── web_detection_report_avg.csv  # Reverse image search - avg (16_)
│       ├── web_detection_report_app.csv  # Reverse image search - app (16_)
│       └── bundle_<TEAM_SLUG>_baseline_<timestamp>.zip
└── endline/
    └── ...same structure...
```

## Dependencies

### R Packages
- `qualtRics`: Qualtrics API client
- `httr`: HTTP requests for file downloads
- `readr`, `dplyr`, `stringr`, `tidyr`, `tibble`: Data wrangling
- `shiny`: Interactive annotation app
- `irr`: Cohen's kappa calculation (leadership team only for `12_compare_annotations.R`)

Install with: `install.packages(c("qualtRics", "httr", "readr", "dplyr", "stringr", "tidyr", "shiny", "tibble", "irr"))`

### Python Packages (leadership team only)
- `pandas`: Data manipulation
- `requests`: HTTP requests for API calls
- `python-dotenv`: Load environment variables from .env
- `opencv-python`, `numpy`, `pillow`: Image processing for TruFor
- `pytesseract`: OCR for digit region detection
- `google-cloud-vision`: Web Detection reverse image search

Install with: `pip install -r requirements.txt`

### External Tools (leadership team only)
- **Tesseract OCR**: Required by `15_edge_anomaly.py` for digit detection
  - macOS: `brew install tesseract`
  - Ubuntu: `apt install tesseract-ocr`
- **TruFor**: Neural network for image manipulation detection
  - Clone from GRIP-UNINA: `git clone https://github.com/grip-unina/TruFor`
  - Weights auto-downloaded on first run
  - Requires PyTorch (see TruFor repo for GPU setup)
- **Google Cloud**: Required by `16_web_detection_check.py`
  - Create service account with Vision API access
  - Enable Vision API in GCP console
  - Set `GOOGLE_APPLICATION_CREDENTIALS` to JSON key path
