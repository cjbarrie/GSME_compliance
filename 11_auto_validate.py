#!/usr/bin/env python3

"""
11_auto_validate.py

Uses OpenRouter Vision API to automatically validate screenshots
and extract screentime values.

Reads:
  data/qualtrics/<TEAM_SLUG>/<WAVE>/derived/average_screentime_for_annotation.csv
  data/qualtrics/<TEAM_SLUG>/<WAVE>/derived/app_screentime_for_annotation.csv

Writes:
  data/qualtrics/<TEAM_SLUG>/<WAVE>/results/auto_annotations_avg.csv
  data/qualtrics/<TEAM_SLUG>/<WAVE>/results/auto_annotations_app.csv

Requires:
  .env file with OPENROUTER_API_KEY
"""

import os
import sys
import time
import base64
import json
import re
from pathlib import Path
from datetime import datetime
from typing import List, Dict, Optional, Any

import pandas as pd
import requests
from dotenv import load_dotenv

# ----------------------------
# CONFIG (EDIT THESE)
# ----------------------------
TEAM_SLUG = "team_example"
WAVE = "endline"  # "baseline" or "endline"

# OpenRouter model to use
MODEL = "anthropic/claude-3.5-sonnet"  # or "openai/gpt-4-vision-preview", "google/gemini-pro-vision"

# Note: This script validates the SAME screenshots that country teams manually annotated
# It reads from results/sample_avg.csv and results/sample_app.csv (created by 03_run_app.R)

# Rate limiting
MAX_REQUESTS_PER_MINUTE = 10
RETRY_ATTEMPTS = 5

ROOT_DIR = Path("data") / "qualtrics" / TEAM_SLUG / WAVE
RESULTS_DIR = ROOT_DIR / "results"

# Input: samples created by country team manual annotation
SAMPLE_AVG_PATH = RESULTS_DIR / "sample_avg.csv"
SAMPLE_APP_PATH = RESULTS_DIR / "sample_app.csv"

# Output: AI annotations on same samples
AUTO_ANN_AVG_PATH = RESULTS_DIR / "auto_annotations_avg.csv"
AUTO_ANN_APP_PATH = RESULTS_DIR / "auto_annotations_app.csv"

# ----------------------------
# Load .env file
# ----------------------------
load_dotenv()

API_KEY = os.getenv("OPENROUTER_API_KEY")
if not API_KEY:
    print("Error: OPENROUTER_API_KEY not found in .env file")
    print("Copy .env.example to .env and add your API key")
    sys.exit(1)

# ----------------------------
# Helpers
# ----------------------------
def file_exists_safe(path: Any) -> bool:
    """Check if file exists safely."""
    if path is None or pd.isna(path):
        return False
    path_str = str(path)
    if not path_str:
        return False
    return Path(path_str).exists()


def encode_image_base64(path: str) -> Optional[str]:
    """Encode image to base64 data URL."""
    if not file_exists_safe(path):
        return None

    try:
        path_obj = Path(path)
        with open(path_obj, "rb") as f:
            image_data = f.read()

        base64_str = base64.b64encode(image_data).decode("utf-8")

        # Detect mime type
        ext = path_obj.suffix.lower()
        mime_map = {
            ".jpg": "image/jpeg",
            ".jpeg": "image/jpeg",
            ".png": "image/png",
            ".webp": "image/webp"
        }
        mime = mime_map.get(ext, "image/jpeg")

        return f"data:{mime};base64,{base64_str}"
    except Exception as e:
        print(f"  Error encoding image {path}: {e}")
        return None


def with_retry(func, tries: int = RETRY_ATTEMPTS, base_sleep: float = 2.0, max_sleep: float = 30.0):
    """Retry function with exponential backoff."""
    last_error = None

    for attempt in range(tries):
        try:
            return func()
        except Exception as e:
            last_error = e
            if attempt < tries - 1:
                sleep_time = min(max_sleep, base_sleep * (2 ** attempt)) + (0.5 * (1 if attempt % 2 == 0 else -1))
                print(f"  Retry {attempt + 1}/{tries} after error; sleeping {sleep_time:.1f}s ...")
                time.sleep(sleep_time)

    raise last_error


def rate_limit_sleep():
    """Sleep to respect rate limits."""
    sleep_time = 60.0 / MAX_REQUESTS_PER_MINUTE
    time.sleep(sleep_time)


# ----------------------------
# OpenRouter API
# ----------------------------
def call_openrouter_vision(prompt: str, image_data_urls: List[str], model: str = MODEL) -> str:
    """Call OpenRouter Vision API."""
    url = "https://openrouter.ai/api/v1/chat/completions"

    # Build content array with text + images
    content = [{"type": "text", "text": prompt}]
    for img_url in image_data_urls:
        if img_url:
            content.append({
                "type": "image_url",
                "image_url": {"url": img_url}
            })

    body = {
        "model": model,
        "messages": [
            {"role": "user", "content": content}
        ],
        "temperature": 0,
        "max_tokens": 1500
    }

    def make_request():
        response = requests.post(
            url,
            headers={
                "Authorization": f"Bearer {API_KEY}",
                "Content-Type": "application/json",
                "HTTP-Referer": "https://gsme-compliance.research",
                "X-Title": "GSME Screenshot Validator"
            },
            json=body,
            timeout=60
        )
        response.raise_for_status()
        return response.json()

    result = with_retry(make_request)

    if not result.get("choices") or len(result["choices"]) == 0:
        raise ValueError("No response from OpenRouter API")

    return result["choices"][0]["message"]["content"]


def parse_json_response(text: str) -> Optional[Dict]:
    """Parse JSON response, handling markdown code blocks."""
    # Try to extract JSON from markdown code blocks if present
    json_match = re.search(r'```json\s*\n(.+?)\n```', text, re.DOTALL)
    if json_match:
        text = json_match.group(1)

    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        print(f"Failed to parse JSON response: {text[:200]}")
        return None


def safe_int(val: Any) -> Optional[int]:
    """Safely convert to int."""
    if pd.isna(val):
        return None
    try:
        return int(val)
    except (ValueError, TypeError):
        return None


def safe_str(val: Any) -> str:
    """Safely convert to string."""
    if pd.isna(val):
        return ""
    return str(val)


# ----------------------------
# Validation Functions
# ----------------------------
def validate_avg_screenshot(
    task_id: str,
    respondent_id: str,
    screenshot_path: str,
    device: str,
    screenshot_day: Optional[str],
    android_target_date: Optional[str],
    reported_hours: Optional[int],
    reported_minutes: Optional[int]
) -> Dict[str, Any]:
    """Validate average screentime screenshot."""
    print(f"  Validating avg task: {task_id} (respondent: {respondent_id})")

    base_result = {
        "task_id": task_id,
        "respondent_id": respondent_id,
        "reviewer": "AI_OpenRouter",
        "screenshot_correct": None,
        "numbers_match": None,
        "notes": "",
        "annotated_at": datetime.now().isoformat(),
        "model_used": MODEL
    }

    if not file_exists_safe(screenshot_path):
        base_result["notes"] = "Screenshot file not found"
        return base_result

    img_data = encode_image_base64(screenshot_path)
    if not img_data:
        base_result["notes"] = "Failed to encode screenshot"
        return base_result

    # Build context string
    device_str = safe_str(device) or "Unknown"
    day_context = ""
    if device_str.lower() == "android":
        if screenshot_day:
            day_context += f"\n- Day of week that should be shown: {screenshot_day}"
        if android_target_date:
            day_context += f"\n- Date from last week that should be shown: {android_target_date}"

    reported_str = f"{reported_hours or 0}h {reported_minutes or 0}m"

    prompt = f'''You are validating a screenshot for a research compliance check.

CONTEXT:
- Device type: {device_str}{day_context}
- Respondent reported total screen time: {reported_str}

YOUR TASK:
Carefully examine the screenshot and answer two questions:

1. Is this the CORRECT TYPE of screenshot?
   - iOS: Must be from Settings → Screen Time with these specific features:
     * "Week" tab selected (NOT "Day" tab)
     * Shows "Last Week's Average" as the heading
     * Has a bar chart with S M T W T F S day labels (calendar week)
     * REJECT if it shows "Last 7 Days" (that's a rolling window, not correct)
   - Android: Must be from Digital Wellbeing Dashboard with these features:
     * Shows the SPECIFIC DATE listed above (e.g., "Tue, Dec 19"){" - verify both day name and calendar date match exactly" if day_context else ""}
     * Date should be prominently displayed at the top
     * Shows total screen time for that single day
   - Answer "Yes" if it matches these requirements, "No" if wrong (wrong app, wrong view, wrong date, shows "Last 7 Days"), "Unsure" if unclear

2. Do the numbers MATCH what was reported?
   - Compare the total screen time shown in the screenshot to the reported value: {reported_str}
   - Answer "Yes" if they match (or very close), "No" if different, "Unsure" if can't tell

Return ONLY a JSON object with this exact structure:
{{
  "screenshot_correct": "Yes",
  "numbers_match": "Yes",
  "notes": "iOS Screen Time showing Week tab with 'Last Week's Average' heading and S-M-T-W-T-F-S bar chart. Shows 7h 35m, matching reported value."
}}
OR if INCORRECT:
{{
  "screenshot_correct": "No",
  "numbers_match": "Unsure",
  "notes": "Shows 'Last 7 Days' instead of 'Last Week's Average'. This is a rolling window, not the correct calendar week view."
}}
OR for Android:
{{
  "screenshot_correct": "Yes",
  "numbers_match": "Yes",
  "notes": "Digital Wellbeing Dashboard shows Friday, Dec 19 with 3h 22m total. Date matches expected day and calendar date. Numbers match reported value."
}}

Important:
- screenshot_correct and numbers_match must be exactly "Yes", "No", or "Unsure"
- notes should mention key indicators: "Week" tab vs "Last 7 Days", S-M-T-W-T-F-S labels, date verification for Android (1-2 sentences)
'''

    try:
        response_text = call_openrouter_vision(prompt, [img_data], model=MODEL)
        parsed = parse_json_response(response_text)

        if parsed:
            base_result.update({
                "screenshot_correct": parsed.get("screenshot_correct"),
                "numbers_match": parsed.get("numbers_match"),
                "notes": parsed.get("notes", "")
            })
        else:
            base_result["notes"] = "Failed to parse API response"

    except Exception as e:
        base_result["notes"] = f"API error: {str(e)}"

    return base_result


def validate_app_screenshots(
    task_id: str,
    respondent_id: str,
    screenshot_paths: List[str],
    device: str,
    screenshot_day: Optional[str],
    android_target_date: Optional[str],
    reported_values: Dict[str, Dict[str, Optional[int]]]
) -> Dict[str, Any]:
    """Validate app-level screentime screenshots."""
    print(f"  Validating app task: {task_id} (respondent: {respondent_id})")

    base_result = {
        "task_id": task_id,
        "respondent_id": respondent_id,
        "reviewer": "AI_OpenRouter",
        "screenshot_correct": None,
        "numbers_match": None,
        "notes": "",
        "annotated_at": datetime.now().isoformat(),
        "model_used": MODEL
    }

    # Filter to existing files
    valid_paths = [p for p in screenshot_paths if file_exists_safe(p)]

    if not valid_paths:
        base_result["notes"] = "No valid screenshot files found"
        return base_result

    # Encode all images
    img_data_list = []
    for path in valid_paths:
        img_data = encode_image_base64(path)
        if img_data:
            img_data_list.append(img_data)

    if not img_data_list:
        base_result["notes"] = "Failed to encode screenshots"
        return base_result

    # Build context
    device_str = safe_str(device) or "Unknown"
    day_context = ""
    if device_str.lower() == "android":
        if screenshot_day:
            day_context += f"\n- Day of week that should be shown: {screenshot_day}"
        if android_target_date:
            day_context += f"\n- Date from last week that should be shown: {android_target_date}"

    # Format reported values
    reported_lines = []
    for app in ["Instagram", "Facebook", "TikTok", "Twitter"]:
        app_key = app.lower()
        h = reported_values.get(app_key, {}).get("hours") or 0
        m = reported_values.get(app_key, {}).get("minutes") or 0
        reported_lines.append(f"  - {app}: {h}h {m}m")
    reported_str = "\n".join(reported_lines)

    prompt = f'''You are validating screenshot(s) for a research compliance check.

CONTEXT:
- Device type: {device_str}{day_context}
- Number of screenshots: {len(img_data_list)}
- Respondent reported these app usage times:
{reported_str}

YOUR TASK:
Carefully examine the screenshot(s) and answer two questions:

1. Is this the CORRECT TYPE of screenshot?
   - iOS: Must be from Settings → Screen Time with these specific features:
     * Shows "Last Week" at the top with navigation arrows
     * Shows "MOST USED" section with individual apps
     * Displays weekly screen time for each app (NOT daily)
     * REJECT if it shows "Last 7 Days" or daily view
   - Android: Must be from Digital Wellbeing Dashboard with these features:
     * Shows the SPECIFIC DATE at the top (e.g., "Tue, Dec 19"){" - verify both day name and calendar date match exactly" if day_context else ""}
     * Lists individual apps with their screen time for that single day
     * Should show "Dashboard" or similar heading
   - Answer "Yes" if it matches these requirements, "No" if wrong (wrong app, wrong view, wrong date, shows "Last 7 Days"), "Unsure" if unclear

2. Do the numbers MATCH what was reported?
   - Compare the app usage times shown in screenshot(s) to the reported values above
   - Answer "Yes" if they match (or very close), "No" if clearly different, "Unsure" if can't verify all apps

Return ONLY a JSON object with this exact structure:
{{
  "screenshot_correct": "Yes",
  "numbers_match": "Yes",
  "notes": "iOS Screen Time showing 'Last Week' with MOST USED section and weekly app breakdown. All reported apps match: Instagram 2h 15m, Facebook 1h 45m, TikTok 0h 35m, Twitter 0h 20m."
}}
OR if INCORRECT:
{{
  "screenshot_correct": "No",
  "numbers_match": "Unsure",
  "notes": "Shows 'Last 7 Days' instead of 'Last Week'. This is a rolling window view, not the correct calendar week view."
}}
OR for Android:
{{
  "screenshot_correct": "Yes",
  "numbers_match": "No",
  "notes": "Digital Wellbeing Dashboard shows Friday, Dec 19 with per-app list. Date matches expected. Instagram matches (2h 15m), but Facebook shows 3h 10m instead of reported 1h 45m."
}}

Important:
- screenshot_correct and numbers_match must be exactly "Yes", "No", or "Unsure"
- notes should mention key indicators: "Last Week" vs "Last 7 Days", date verification for Android, which apps match/don't match (2-3 sentences)
- The screenshots are provided in order (1, 2, 3...)
'''

    try:
        response_text = call_openrouter_vision(prompt, img_data_list, model=MODEL)
        parsed = parse_json_response(response_text)

        if parsed:
            base_result.update({
                "screenshot_correct": parsed.get("screenshot_correct"),
                "numbers_match": parsed.get("numbers_match"),
                "notes": parsed.get("notes", "")
            })
        else:
            base_result["notes"] = "Failed to parse API response"

    except Exception as e:
        base_result["notes"] = f"API error: {str(e)}"

    return base_result


# ----------------------------
# Main Processing
# ----------------------------
def main():
    print("Loading sample files from country team...")

    if not SAMPLE_AVG_PATH.exists():
        print(f"Error: Missing sample_avg.csv: {SAMPLE_AVG_PATH}")
        print("This file should be created by the country team's manual annotation (03_run_app.R)")
        sys.exit(1)

    if not SAMPLE_APP_PATH.exists():
        print(f"Error: Missing sample_app.csv: {SAMPLE_APP_PATH}")
        print("This file should be created by the country team's manual annotation (03_run_app.R)")
        sys.exit(1)

    # Load the exact samples that country team manually annotated
    avg_sample = pd.read_csv(SAMPLE_AVG_PATH)
    app_sample = pd.read_csv(SAMPLE_APP_PATH)

    print(f"Found {len(avg_sample)} average tasks to validate")
    print(f"Found {len(app_sample)} app tasks to validate")

    # Process average tasks
    print("\n=== Processing Average Screentime Tasks ===")
    avg_results = []

    for i, row in enumerate(avg_sample.itertuples(), 1):
        # Use task_id from sample file to match human annotations
        task_id = str(row.task_id) if hasattr(row, "task_id") else f"avg_{row.respondent_id}_{i:04d}"

        result = validate_avg_screenshot(
            task_id=task_id,
            respondent_id=str(row.respondent_id),
            screenshot_path=str(row.total_screenshot_path) if pd.notna(row.total_screenshot_path) else "",
            device=safe_str(row.device if hasattr(row, "device") else ""),
            screenshot_day=safe_str(row.screenshot_day) if hasattr(row, "screenshot_day") and pd.notna(row.screenshot_day) else None,
            android_target_date=safe_str(row.android_target_date) if hasattr(row, "android_target_date") and pd.notna(row.android_target_date) else None,
            reported_hours=safe_int(row.total_hours if hasattr(row, "total_hours") else None),
            reported_minutes=safe_int(row.total_minutes if hasattr(row, "total_minutes") else None)
        )

        avg_results.append(result)
        rate_limit_sleep()

        if i % 10 == 0:
            print(f"  Progress: {i}/{len(avg_sample)} completed")

    avg_annotations = pd.DataFrame(avg_results)
    avg_annotations.to_csv(AUTO_ANN_AVG_PATH, index=False)
    print(f"✅ Saved: {AUTO_ANN_AVG_PATH}")

    # Process app-level tasks
    print("\n=== Processing App-level Screentime Tasks ===")
    app_results = []

    for i, row in enumerate(app_sample.itertuples(), 1):
        # Use task_id from sample file to match human annotations
        task_id = str(row.task_id) if hasattr(row, "task_id") else f"app_{row.respondent_id}_{i:04d}"

        screenshot_paths = []
        for col in ["app_screenshot1_path", "app_screenshot2_path", "app_screenshot3_path"]:
            if hasattr(row, col):
                val = getattr(row, col)
                if pd.notna(val):
                    screenshot_paths.append(str(val))

        # Gather reported values
        reported_values = {
            "instagram": {
                "hours": safe_int(row.instagram_hours if hasattr(row, "instagram_hours") else None),
                "minutes": safe_int(row.instagram_minutes if hasattr(row, "instagram_minutes") else None)
            },
            "facebook": {
                "hours": safe_int(row.facebook_hours if hasattr(row, "facebook_hours") else None),
                "minutes": safe_int(row.facebook_minutes if hasattr(row, "facebook_minutes") else None)
            },
            "tiktok": {
                "hours": safe_int(row.tiktok_hours if hasattr(row, "tiktok_hours") else None),
                "minutes": safe_int(row.tiktok_minutes if hasattr(row, "tiktok_minutes") else None)
            },
            "twitter": {
                "hours": safe_int(row.twitter_hours if hasattr(row, "twitter_hours") else None),
                "minutes": safe_int(row.twitter_minutes if hasattr(row, "twitter_minutes") else None)
            }
        }

        result = validate_app_screenshots(
            task_id=task_id,
            respondent_id=str(row.respondent_id),
            screenshot_paths=screenshot_paths,
            device=safe_str(row.device if hasattr(row, "device") else ""),
            screenshot_day=safe_str(row.screenshot_day) if hasattr(row, "screenshot_day") and pd.notna(row.screenshot_day) else None,
            android_target_date=safe_str(row.android_target_date) if hasattr(row, "android_target_date") and pd.notna(row.android_target_date) else None,
            reported_values=reported_values
        )

        app_results.append(result)
        rate_limit_sleep()

        if i % 10 == 0:
            print(f"  Progress: {i}/{len(app_sample)} completed")

    app_annotations = pd.DataFrame(app_results)
    app_annotations.to_csv(AUTO_ANN_APP_PATH, index=False)
    print(f"✅ Saved: {AUTO_ANN_APP_PATH}")

    print("\n=== Auto-validation Complete ===")
    print(f"Average tasks validated: {len(avg_annotations)}")
    print(f"App tasks validated: {len(app_annotations)}")


if __name__ == "__main__":
    main()
