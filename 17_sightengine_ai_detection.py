#!/usr/bin/env python3
"""
17_sightengine_ai_detection.py

Batch AI-generated image detection using Sightengine API.

- Reads an input CSV containing screenshot paths.
- Submits each image to Sightengine's genai detection model.
- Extracts ai_generated score (0-1 where higher = more likely AI).
- Writes one row per image to an output report CSV.

Usage:
  python 17_sightengine_ai_detection.py \
    --csv data/qualtrics/team_example/baseline/results/sample_avg.csv \
    --out_csv data/qualtrics/team_example/baseline/results/sightengine_ai_report.csv

Auth:
  export SIGHTENGINE_API_USER="your_api_user"
  export SIGHTENGINE_API_SECRET="your_api_secret"

Or add to .env file:
  SIGHTENGINE_API_USER=your_api_user
  SIGHTENGINE_API_SECRET=your_api_secret

Requirements:
  pip install requests pandas python-dotenv
"""

import argparse
import json
import os
import time
from pathlib import Path
from typing import Any, Dict, List

import pandas as pd
import requests
from dotenv import load_dotenv

load_dotenv()

DEFAULT_SLEEP = 0.5  # Sightengine allows 2 req/sec on free tier
DEFAULT_TIMEOUT = 60

SIGHTENGINE_ENDPOINT = "https://api.sightengine.com/1.0/check.json"


def get_api_credentials() -> tuple[str, str]:
    """Returns (api_user, api_secret) from environment."""
    api_user = (os.getenv("SIGHTENGINE_API_USER") or "").strip()
    api_secret = (os.getenv("SIGHTENGINE_API_SECRET") or "").strip()
    return api_user, api_secret


def detect_ai_generated(
    image_path: Path,
    api_user: str,
    api_secret: str,
    endpoint: str = SIGHTENGINE_ENDPOINT,
    timeout_s: int = DEFAULT_TIMEOUT,
    max_retries: int = 2,
) -> Dict[str, Any]:
    """
    Submit a local image to Sightengine's AI-generated detection.

    Returns a dict with:
      - status: ok|error
      - http_status
      - error
      - ai_generated_score (0-1)
      - raw_response (truncated)
    """
    if not api_user or not api_secret:
        return {
            "status": "error",
            "http_status": "",
            "error": "Missing Sightengine credentials. Set SIGHTENGINE_API_USER and SIGHTENGINE_API_SECRET.",
            "ai_generated_score": "",
            "raw_response": "",
        }

    params = {
        "models": "genai",
        "api_user": api_user,
        "api_secret": api_secret,
    }

    last_err = "Unknown error"
    last_http = ""

    for attempt in range(max_retries + 1):
        try:
            with image_path.open("rb") as f:
                files = {"media": (image_path.name, f)}
                resp = requests.post(
                    endpoint,
                    data=params,
                    files=files,
                    timeout=timeout_s,
                )
        except requests.RequestException as e:
            last_err = f"Request error: {e}"
            last_http = ""
            if attempt < max_retries:
                time.sleep(1.5 * (attempt + 1))
                continue
            break

        last_http = str(resp.status_code)

        # Rate limiting
        if resp.status_code == 429:
            last_err = f"Rate limited (HTTP 429): {resp.text[:300]}"
            if attempt < max_retries:
                ra = resp.headers.get("Retry-After")
                if ra and ra.isdigit():
                    time.sleep(int(ra))
                else:
                    time.sleep(2 * (attempt + 1))
                continue
            break

        # Transient errors
        if resp.status_code in (500, 502, 503, 504):
            last_err = f"Transient HTTP {resp.status_code}: {resp.text[:300]}"
            if attempt < max_retries:
                time.sleep(1.5 * (attempt + 1))
                continue
            break

        # Auth errors
        if resp.status_code in (401, 403):
            last_err = f"Auth failed (HTTP {resp.status_code}): {resp.text[:300]}"
            break

        if resp.status_code != 200:
            last_err = f"HTTP {resp.status_code}: {resp.text[:300]}"
            break

        try:
            resp_json = resp.json()
        except Exception:
            last_err = f"Non-JSON response (HTTP 200): {resp.text[:300]}"
            break

        # Check for API-level error
        if resp_json.get("status") == "failure":
            error_msg = resp_json.get("error", {}).get("message", "Unknown API error")
            return {
                "status": "error",
                "http_status": str(resp.status_code),
                "error": f"API error: {error_msg}",
                "ai_generated_score": "",
                "raw_response": json.dumps(resp_json)[:2000],
            }

        # Extract ai_generated score
        ai_score = ""
        try:
            type_info = resp_json.get("type", {})
            ai_score = type_info.get("ai_generated", "")
            if ai_score != "":
                ai_score = float(ai_score)
        except (KeyError, TypeError, ValueError):
            ai_score = ""

        raw = json.dumps(resp_json)[:2000]

        return {
            "status": "ok",
            "http_status": str(resp.status_code),
            "error": "",
            "ai_generated_score": ai_score,
            "raw_response": raw,
        }

    return {
        "status": "error",
        "http_status": last_http,
        "error": last_err,
        "ai_generated_score": "",
        "raw_response": "",
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Sightengine AI-generated image detection for screenshot compliance"
    )
    parser.add_argument("--csv", required=True, help="Input CSV with screenshot paths")
    parser.add_argument("--out_csv", required=True, help="Output report CSV")
    parser.add_argument(
        "--path_cols",
        default="total_screenshot_path,app_screenshot1_path,app_screenshot2_path,app_screenshot3_path",
        help="Comma-separated column names containing image paths",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.5,
        help="Score threshold for flagging as AI-generated (default: 0.5)",
    )
    parser.add_argument(
        "--sleep", type=float, default=DEFAULT_SLEEP, help="Seconds between API requests"
    )
    parser.add_argument(
        "--timeout", type=int, default=DEFAULT_TIMEOUT, help="HTTP timeout (seconds)"
    )

    args = parser.parse_args()

    api_user, api_secret = get_api_credentials()
    if not api_user or not api_secret:
        print("ERROR: Sightengine credentials missing.")
        print("Set environment variables:")
        print("  export SIGHTENGINE_API_USER='your_api_user'")
        print("  export SIGHTENGINE_API_SECRET='your_api_secret'")
        print("\nOr add to .env file.")
        return 1

    df = pd.read_csv(args.csv)
    path_cols = [c.strip() for c in args.path_cols.split(",") if c.strip()]

    rows: List[Dict[str, Any]] = []
    for i, r in df.iterrows():
        task_id = r.get("task_id", f"row_{i}")

        for col in path_cols:
            if col not in r or pd.isna(r[col]):
                continue

            img_path = Path(str(r[col])).expanduser()
            if not img_path.exists():
                rows.append({
                    "task_id": task_id,
                    "image_col": col,
                    "image_path": str(img_path),
                    "status": "error",
                    "http_status": "",
                    "error": "File not found",
                    "ai_generated_score": "",
                    "flagged": "",
                    "raw_response": "",
                })
                continue

            print(f"[sightengine] Scanning: {img_path.name}")
            result = detect_ai_generated(
                image_path=img_path,
                api_user=api_user,
                api_secret=api_secret,
                timeout_s=args.timeout,
            )

            # Determine if flagged based on threshold
            flagged = ""
            if result.get("ai_generated_score") != "":
                try:
                    score = float(result["ai_generated_score"])
                    flagged = 1 if score >= args.threshold else 0
                except (ValueError, TypeError):
                    flagged = ""

            rows.append({
                "task_id": task_id,
                "image_col": col,
                "image_path": str(img_path),
                "status": result.get("status", "error"),
                "http_status": result.get("http_status", ""),
                "error": result.get("error", ""),
                "ai_generated_score": result.get("ai_generated_score", ""),
                "flagged": flagged,
                "raw_response": result.get("raw_response", ""),
            })

            time.sleep(args.sleep)

    out_df = pd.DataFrame(rows)
    out_path = Path(args.out_csv)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_df.to_csv(out_path, index=False)

    n_ok = int((out_df["status"] == "ok").sum())
    n_err = int((out_df["status"] == "error").sum())
    n_flagged = int((out_df["flagged"] == 1).sum()) if "flagged" in out_df else 0

    print(f"\n[sightengine] Results saved: {out_path}")
    print(f"[sightengine] Summary: {n_ok} ok, {n_err} errors, {n_flagged} flagged as AI-generated (threshold: {args.threshold})")

    if n_flagged > 0:
        print("\n[sightengine] WARNING: Some images flagged as potentially AI-generated. Review manually.")
        flagged_rows = out_df[out_df["flagged"] == 1]
        for _, row in flagged_rows.iterrows():
            print(f"  - {row['task_id']}: score={row['ai_generated_score']:.3f}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
