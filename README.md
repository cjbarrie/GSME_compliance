# Screenshot Compliance Check Pipeline for Global Social Media Experiment

This repository implements a two-stage screenshot compliance-check workflow for the Global Social Media Experiment:

## Country Survey Teams Workflow

1. **Download** Qualtrics responses + screenshot uploads
2. **Wrangle** into standardized CSVs for annotation
3. **Manual annotation** of 100 avg + 100 app screenshots (randomly sampled) using Shiny app
4. **Bundle results** and send to leadership team

## Leadership Team Workflow

5. **AI validation** on the same screenshots manually annotated by country teams
6. **Agreement analysis** comparing human vs AI annotations
7. **Quality assessment** across all country teams

It supports:

* **Baseline** and **Endline** surveys
* **iPhone** and **Android**
* Android’s **day-of-week branching (prefix 1:7)**, stored as `screenshot_day_prefix` and `screenshot_day`

---

## Scripts

### Country Survey Teams Use:
* `01_download.R` - Download survey data (set `WAVE="baseline"` or `"endline"`)
* `02_wrangle.R` - Prepare for annotation (set `WAVE` to match)
* `03_run_app.R` - Manual annotation interface (Shiny app)
* `04_bundle_results.R` - Package results for submission

### Leadership Team Use:
* `11_auto_validate.py` - AI validation on country team samples
* `12_compare_annotations.R` - Compare human vs AI annotations
* `13_upload_times.R` - Analyze screenshot upload durations
* `14_device_consistency.R` - Compare devices across baseline/endline waves
* `15_edge_anomaly.py` - TruFor tamper detection (requires external tools)
* `16_web_detection_check.py` - Reverse image search (requires Google Cloud)
* `17_combine_all.R` - Combine all outputs into single report

---

## Prerequisites

### 1) Install R packages

Run once in R:

```r
install.packages(c(
  "qualtRics","httr","readr","dplyr","stringr","tidyr","shiny","tibble","irr"
))
```

Note: The `irr` package is only needed by the leadership team for running the agreement analysis script (`12_compare_annotations.R`).

### 2) Set Qualtrics API key (required for download)

Set `QUALTRICS_API_KEY` **once**:

**macOS/Linux**

```bash
export QUALTRICS_API_KEY="YOUR_KEY_HERE"
```

**Windows (PowerShell)**

```powershell
setx QUALTRICS_API_KEY "YOUR_KEY_HERE"
```

Or place in `~/.Renviron`:

```r
QUALTRICS_API_KEY=YOUR_KEY_HERE
```

The easiest way to set your API key in .Renviron is with:

```r
usethis::edit_r_environ()
```

Once you have set it, you will need to restart R for it become active. 

### 3) Confirm Qualtrics data center

Your download scripts contain something like:

```r
BASE_URL <- "ca1.qualtrics.com"
```

Change it if your Qualtrics account uses a different data center. You can find details on how to find the datacenter your Qualtrics subscription is using with by reading the following short [guide](https://www.qualtrics.com/support/integrations/api-integration/finding-qualtrics-ids/#LocatingtheDatacenterID) on the Qualtrics website.


---

## Folder structure

The scripts create the following structure:

```
project/
  # Country team scripts
  01_download.R        # Set WAVE="baseline" or "endline"
  02_wrangle.R         # Set WAVE to match download
  03_run_app.R
  04_bundle_results.R

  # Leadership team scripts (not used by country teams)
  11_auto_validate.py
  12_compare_annotations.R
  13_upload_times.R
  14_device_consistency.R
  15_edge_anomaly.py
  16_web_detection_check.py
  17_combine_all.R
  .env  (leadership only - API keys)

  data/
    qualtrics/
      <TEAM_SLUG>/
        combined_compliance_report.csv  # Final combined report (17_)
        device_consistency.csv          # Cross-wave device comparison (14_)
        baseline/
          responses.csv
          uploaded_files_manifest.csv
          uploads/
            <ResponseId>/
              <image files...>
          derived/
            average_screentime_for_annotation.csv
            app_screentime_for_annotation.csv
          results/
            sample_avg.csv  (sent to leadership)
            sample_app.csv  (sent to leadership)
            annotations_avg.csv  (sent to leadership)
            annotations_app.csv  (sent to leadership)
            bundle_<TEAM_SLUG>_baseline_<timestamp>.zip  (send this!)

            # Leadership team files (created after receiving bundle)
            auto_annotations_avg.csv
            auto_annotations_app.csv
            agreement_report_avg.csv
            agreement_report_app.csv
            agreement_summary.txt
            upload_times.csv              # (13_)
            trufor_report_avg.csv         # (15_)
            trufor_report_app.csv         # (15_)
            web_detection_report_avg.csv  # (16_)
            web_detection_report_app.csv  # (16_)
        endline/
          ...same structure...
```

`<TEAM_SLUG>` is a short folder-safe team identifier (e.g., `GB`, `US`). **Please set the team name as the ISO2 for your country team**. You'll find a list of Alpha-2 ISO codes [here](http://iso.org/obp/ui/#search).

---

## Quick start for country teams

First, you should locate the survey ID for the baseline (treatment assignment) and endline (post-treatment) surveys. These are the surveys where we ask respondents, respectively, to upload screenshots of their pre-experiment social media usage and their post-experiment social media usage.

You'll find the Survey ID for each individual survey by accessing the survey in question on Qualtrics. You will then find the survey ID in the URL for that survey. It will begin with `SV_*` as in the below:

![qualtrics1.png](qualtrics1.png)

### A) Baseline

1. Edit `01_download.R`: set `TEAM_SLUG`, `SURVEY_ID` (baseline survey), and `WAVE <- "baseline"`
2. Edit `02_wrangle.R`: set `TEAM_SLUG` and `WAVE <- "baseline"`
3. Edit `03_run_app.R`: set `TEAM_SLUG` and `WAVE <- "baseline"`

Then run:

```bash
Rscript 01_download.R
Rscript 02_wrangle.R
Rscript 03_run_app.R
Rscript 04_bundle_results.R
```

### B) Endline

1. Edit `01_download.R`: set `SURVEY_ID` (endline survey) and `WAVE <- "endline"`
2. Edit `02_wrangle.R`: set `WAVE <- "endline"`
3. Edit `03_run_app.R`: set `WAVE <- "endline"`

Then run:

```bash
Rscript 01_download.R
Rscript 02_wrangle.R
Rscript 03_run_app.R
Rscript 04_bundle_results.R
```

**After bundling, send the ZIP file to cb5691@nyu.edu.**

The bundle contains:
- `sample_avg.csv` and `sample_app.csv` (the 100+100 screenshots you annotated)
- `annotations_avg.csv` and `annotations_app.csv` (your manual annotations)

---

## Step-by-step details

## 1) Download survey data + screenshots

Edit `01_download.R` to set `TEAM_SLUG`, `SURVEY_ID`, and `WAVE`, then run:

```bash
Rscript 01_download.R
```

This writes:

* `responses.csv` — full Qualtrics export
* `uploaded_files_manifest.csv` — mapping from Qualtrics file IDs (`F_...`) to local paths
* `uploads/<ResponseId>/...` — downloaded screenshots

**Note:** download scripts use hard-coded `SURVEY_ID` to avoid flaky “list surveys” endpoints.

---

## 2) Wrangle for annotation

Edit `02_wrangle.R` to set `TEAM_SLUG` and `WAVE` (must match download), then run:

```bash
Rscript 02_wrangle.R
```

### Participant ID configuration

The wrangle script includes settings for cross-wave respondent matching:

* `PARTICIPANT_ID_COL` - Column name in Qualtrics containing stable participant ID (e.g., `"ID"`, `"PanelID"`)
* `GENERATE_DUMMY_IDS` - Set to `TRUE` for test data to auto-generate placeholder IDs (`P001`, `P002`, ...)

For real studies, set `PARTICIPANT_ID_COL` to your panel provider's ID field and `GENERATE_DUMMY_IDS <- FALSE`.

This writes:

* `derived/average_screentime_for_annotation.csv`
* `derived/app_screentime_for_annotation.csv`

These are the inputs to the app.

### Device detection and standardization

The wrangling scripts automatically detect and standardize device type from the Qualtrics response field:

* **iOS**: Detected from "iPhone", "iOS", or numeric value 1
* **Android**: Detected from "Android" or numeric value 2
* Output stored as `device` field with values: "iOS", "Android", or NA

This standardized device field is critical for AI validation as it determines which screenshot type to expect (weekly summary for iOS, specific day for Android).

### Android day-of-week branching (prefix 1:7)

Android survey blocks are repeated for different day-of-week prompts using the prefix `1_` to `7_`.

Wrangling:

* Detects which prefix has data for each respondent
* Stores:
  * `screenshot_day_prefix` (1–7)
  * `screenshot_day` (Monday–Sunday)
  * `android_target_date` (YYYY-MM-DD) - calculated calendar date for that day in "last week" relative to survey completion
* Uses `EndDate` field from Qualtrics to anchor date calculations

If your study uses a different mapping, edit `PREFIX_TO_DAY` inside the wrangle script(s).

---

## 3) Manual annotation in the Shiny app

Edit at the top of `03_run_app.R`:

* `TEAM_SLUG`
* `WAVE <- "baseline"` or `"endline"`

Then run:

```bash
Rscript 03_run_app.R
```

A browser window opens.

### App behavior (important)

* **No Save button.** The app **auto-saves** whenever you click:

  * **Next**, **Prev**, or **Go**
* It forces the task order:

  1. **Average** tasks
  2. automatically switches to **App-level** tasks
  3. shows **Done** when finished

### Context displayed to annotators

The app shows key metadata for each task to help validate screenshots:
* **Respondent ID**: Wave-specific Qualtrics ResponseId
* **Participant ID**: Stable cross-wave identifier (for linking baseline/endline)
* **Device**: iOS or Android
* **Day (Android)**: Day of week (Monday-Sunday) - only shown for Android users
* **Date (Android)**: Calendar date (YYYY-MM-DD) for the target day - only shown for Android users

For Android screenshots, annotators should verify that the screenshot shows the specified day and date.

### Sampling (100 by default)

On first run, the app creates stable random samples:

* `results/sample_avg.csv`
* `results/sample_app.csv`

These are reused on subsequent runs so the task list doesn’t change.

To regenerate samples:

* delete `results/sample_avg.csv` and/or `results/sample_app.csv`
* re-run `03_run_app.R`

### What gets saved

The app creates/updates:

* `results/annotations_avg.csv`
* `results/annotations_app.csv`

Each annotation record includes:

* `task_id`
* `respondent_id`
* `reviewer`
* `screenshot_correct` (Yes/No/Unsure)
* `numbers_match` (Yes/No/Unsure)
* `notes`
* `annotated_at`

Sample files (`sample_avg.csv`, `sample_app.csv`) include:

* `respondent_id` - Wave-specific Qualtrics ResponseId
* `participant_id` - Stable cross-wave identifier
* `device`, `screenshot_day`, `android_target_date` - Validation context
* Screenshot paths and reported values

---

## 4) Bundle results for return

Run:

```bash
Rscript 04_bundle_results.R
```

This creates a ZIP in:

* `data/qualtrics/<TEAM_SLUG>/<WAVE>/results/`

  * `bundle_<TEAM_SLUG>_<WAVE>_<timestamp>.zip`

The bundle includes:

* `annotations_avg.csv`
* `annotations_app.csv`
* `sample_avg.csv`
* `sample_app.csv`
* (optionally) a small manifest of the bundle contents

Send the ZIP back to the compliance lead, Christopher Barrie, at cb5691@nyu.edu.

---

## What to send back

After completing baseline or endline:

✅ Send back the ZIP created by `04_bundle_results.R`:

* `bundle_<TEAM_SLUG>_<WAVE>_<timestamp>.zip`

---

# Leadership Team Workflow

After receiving bundles from all country teams, the leadership team runs AI validation and agreement analysis.

## Prerequisites

**Install Python packages:**

```bash
pip install pandas requests python-dotenv scikit-learn
```

Or use the requirements file:

```bash
pip install -r requirements.txt
```

**Set OpenRouter API key:**

1. Copy `.env.example` to `.env`
2. Get your API key from https://openrouter.ai/keys
3. Add it to `.env`:

```
OPENROUTER_API_KEY=your_key_here
```

## Workflow Steps

### 1) Extract country team bundles

For each country team bundle received:

```bash
# Example for GB team baseline
unzip bundle_GB_baseline_20260115.zip -d data/qualtrics/GB/baseline/results/
```

This gives you:
- `sample_avg.csv` - The 100 screenshots they annotated
- `sample_app.csv` - The 100 screenshots they annotated
- `annotations_avg.csv` - Their human annotations
- `annotations_app.csv` - Their human annotations

### 2) Run AI validation on the same samples

Edit `11_auto_validate.py`:
- Set `TEAM_SLUG` to match the country team (e.g., "GB")
- Set `WAVE` to match ("baseline" or "endline")

Run:

```bash
python 11_auto_validate.py
```

**What it does:**
- Reads the `sample_avg.csv` and `sample_app.csv` files from the country team
- Validates the EXACT SAME screenshots that humans annotated
- Uses OpenRouter Vision API (Claude 3.5 Sonnet by default)
- Asks the same two questions:
  1. Is this the correct type of screenshot?
     - iOS: Checks for "Last Week's Average" with "Week" tab and S-M-T-W-T-F-S calendar bar chart (REJECTS "Last 7 Days" rolling window)
     - Android: Verifies both day name and calendar date match the expected date from Digital Wellbeing Dashboard
  2. Do the numbers match what was reported?
- Provides same context to AI: device type, day of week (Android), calendar date (Android), reported values
- Validates source app (Screen Time for iOS, Digital Wellbeing for Android)

**Outputs:**
- `results/auto_annotations_avg.csv` - AI annotations
- `results/auto_annotations_app.csv` - AI annotations

### 3) Compare human vs AI annotations

Run:

```bash
Rscript 12_compare_annotations.R
```

**What it does:**
- Loads human annotations from country team
- Loads AI annotations
- Normalizes responses (Yes/No/Unsure)
- Calculates agreement metrics:
  - Overall agreement rate
  - Per-question agreement (screenshot_correct, numbers_match)
  - Cohen's kappa for inter-rater reliability (using R's `irr` package)
  - Confusion matrices
  - Disagreement pattern breakdown
- Identifies disagreement cases for review

**Outputs:**
- `results/agreement_report_avg.csv` - Per-task comparison with metadata (device, day, date)
- `results/agreement_report_app.csv` - Per-task comparison with metadata (device, day, date)
- `results/agreement_summary.txt` - Overall statistics

The CSV reports include task metadata (device type, screenshot day, Android target date) to help identify patterns in disagreements. For example, you can filter to see if Android date verification has lower agreement than iOS validation.

### 4) Repeat for all country teams

Repeat steps 1-3 for each country team bundle received.

---