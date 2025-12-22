# Screenshot Compliance Check Pipeline for Global Social Media Experiment

This repository automates a manual screenshot compliance-check workflow for the Global Social Media Experiment:

1. **Download** Qualtrics responses + screenshot uploads
2. **Wrangle** into standardized CSVs for annotation
3. Run a **Shiny annotation app** (auto-saves on navigation; Average → App-level → Done)
4. **Bundle results** into a single ZIP file for return

It supports:

* **Baseline** and **Endline** surveys
* **iPhone** and **Android**
* Android’s **day-of-week branching (prefix 1:7)**, stored as `screenshot_day_prefix` and `screenshot_day`

---

## Scripts

You should have these scripts at repo root:

* `01a_download_baseline.R`
* `01b_download_endline.R`
* `02a_wrangle_baseline.R`
* `02b_wrangle_endline.R`
* `03_run_app.R`
* `04_bundle_results.R`

---

## Prerequisites

### 1) Install R packages

Run once in R:

```r
install.packages(c(
  "qualtRics","httr","readr","dplyr","stringr","tidyr","shiny","tibble"
))
```

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
  01a_download_baseline.R
  01b_download_endline.R
  02a_wrangle_baseline.R
  02b_wrangle_endline.R
  03_run_app.R
  04_bundle_results.R
  data/
    qualtrics/
      <TEAM_SLUG>/
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
            sample_avg.csv
            sample_app.csv
            annotations_avg.csv
            annotations_app.csv
            bundle_<TEAM_SLUG>_baseline_<timestamp>.zip
        endline/
          ...same structure...
```

`<TEAM_SLUG>` is a short folder-safe team identifier (e.g., `GB`, `US`). **Please set the team name as the ISO2 for your country team**. You'll find a list of Alpha-2 ISO codes [here](http://iso.org/obp/ui/#search).

---

## Quick start (what a team should do)

First, you should locate the survey ID for the baseline (treatment assignment) and endline (post-treatment) surveys. These are the surveys where we ask respondents, respectively, to upload screenshots of their pre-experiment social media usage and their post-experiment social media usage. 

You'll find the Survey ID for each individual survey by accessing the survey in question on Qualtrics. You will then find the survey ID in the URL for that survey. It will begin with `SV_*` as in the below:

![qualtrics1.png](qualtrics1.png)

### A) Baseline

1. Edit `TEAM_SLUG` and `SURVEY_ID` in `01a_download_baseline.R`
2. Edit `TEAM_SLUG` in `02a_wrangle_baseline.R`
3. Edit `TEAM_SLUG` and set `WAVE <- "baseline"` in `03_run_app.R`

Then run:

```bash
Rscript 01a_download_baseline.R
Rscript 02a_wrangle_baseline.R
Rscript 03_run_app.R
Rscript 04_bundle_results.R
```

### B) Endline

1. Edit `TEAM_SLUG` and `SURVEY_ID` in `01b_download_endline.R`
2. Edit `TEAM_SLUG` in `02b_wrangle_endline.R`
3. Edit `TEAM_SLUG` and set `WAVE <- "endline"` in `03_run_app.R`

Then run:

```bash
Rscript 01b_download_endline.R
Rscript 02b_wrangle_endline.R
Rscript 03_run_app.R
Rscript 04_bundle_results.R
```

After bundling, send the ZIP file back to @cb5691@nyu.edu.

---

## Step-by-step details

## 1) Download survey data + screenshots

Run one of:

```bash
Rscript 01a_download_baseline.R
# or
Rscript 01b_download_endline.R
```

This writes:

* `responses.csv` — full Qualtrics export
* `uploaded_files_manifest.csv` — mapping from Qualtrics file IDs (`F_...`) to local paths
* `uploads/<ResponseId>/...` — downloaded screenshots

**Note:** download scripts use hard-coded `SURVEY_ID` to avoid flaky “list surveys” endpoints.

---

## 2) Wrangle for annotation

Run one of:

```bash
Rscript 02a_wrangle_baseline.R
# or
Rscript 02b_wrangle_endline.R
```

This writes:

* `derived/average_screentime_for_annotation.csv`
* `derived/app_screentime_for_annotation.csv`

These are the inputs to the app.

### Android day-of-week branching (prefix 1:7)

Android survey blocks are repeated for different day-of-week prompts using the prefix `1_` to `7_`.

Wrangling:

* detects which prefix has data for each respondent
* stores:

  * `screenshot_day_prefix` (1–7)
  * `screenshot_day` (Monday–Sunday)

If your study uses a different mapping, edit `PREFIX_TO_DAY` inside the wrangle script(s).

---

## 3) Annotate in the Shiny app

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

Each record includes:

* `task_id`
* `respondent_id`
* `reviewer`
* `screenshot_correct` (Yes/No/Unsure)
* `numbers_match` (Yes/No/Unsure)
* `notes`
* `annotated_at`

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