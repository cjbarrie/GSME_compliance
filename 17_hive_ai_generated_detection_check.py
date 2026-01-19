#!/usr/bin/env python3
"""
17_hive_ai_generated_detection_check.py

Batch Hive "AI-Generated Content Detection" for screenshot compliance checking
(dedicated Hive Models project; V2 Task API sync endpoint).

- Reads an input CSV containing screenshot paths (relative or absolute).
- Submits each local file to Hive's sync endpoint.
- Extracts ai_generated / not_ai_generated scores (and a few optional fields if present).
- Writes one row per image to an output report CSV.

Usage:
  python 17_hive_ai_generated_detection_check.py \
    --csv data/qualtrics/team_example/baseline/results/sample_avg.csv \
    --out_csv data/qualtrics/team_example/baseline/results/hive_ai_gen_report.csv

Auth (recommended):
  export HIVE_API_KEY="YOUR_PRIMARY_API_KEY"
  export HIVE_API_KEY_2="YOUR_SECONDARY_API_KEY"   # optional failover

Alternative (your naming; treated as primary/secondary keys):
  export HIVE_ACCESS_KEY="YOUR_PRIMARY_API_KEY"
  export HIVE_SECRET_KEY="YOUR_SECONDARY_API_KEY"

Requirements:
  pip install requests pandas python-dotenv
"""

import argparse
import json
import os
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import pandas as pd
import requests
from dotenv import load_dotenv

load_dotenv()

DEFAULT_SLEEP = 0.5
DEFAULT_TIMEOUT = 60

HIVE_SYNC_ENDPOINT = "https://api.thehive.ai/api/v2/task/sync"


def get_api_keys() -> Tuple[str, str]:
    """
    Returns (primary_key, secondary_key).

    Supports either:
      - HIVE_API_KEY (+ optional HIVE_API_KEY_2)
      - HIVE_ACCESS_KEY + HIVE_SECRET_KEY (treated as primary + secondary)
    """
    primary = (os.getenv("HIVE_API_KEY") or "").strip()
    secondary = (os.getenv("HIVE_API_KEY_2") or "").strip()

    if not primary:
        primary = (os.getenv("HIVE_ACCESS_KEY") or "").strip()
    if not secondary:
        secondary = (os.getenv("HIVE_SECRET_KEY") or "").strip()

    return primary, secondary


def parse_hive_response(resp_json: Dict[str, Any]) -> Dict[str, Any]:
    """
    Best-effort parsing of Hive V2 task/sync response.

    Hive responses are nested; commonly:
      status[0].response.output[0].classes -> list of {class, score}
    But schemas can vary by project/model; this function remains defensive.
    """
    classes: List[Dict[str, Any]] = []
    c2pa_metadata = ""

    try:
        status = resp_json.get("status") or []
        status0 = status[0] if status else {}
        response = status0.get("response") or {}
        output = response.get("output") or []
        output0 = output[0] if output else {}
        classes = output0.get("classes") or []
        if not isinstance(classes, list):
            classes = []

        # Best-effort C2PA metadata capture (field names can vary by product/version)
        for k in ("c2pa", "c2pa_metadata", "c2pa_manifest", "c2paManifest", "content_credentials"):
            if k in response and response[k]:
                c2pa_metadata = json.dumps(response[k])[:2000]
                break
    except Exception:
        classes = []
        c2pa_metadata = ""

    def score_for(name: str) -> Optional[float]:
        for c in classes:
            if c.get("class") == name:
                try:
                    return float(c.get("score"))
                except Exception:
                    return None
        return None

    ai_score = score_for("ai_generated")
    not_ai_score = score_for("not_ai_generated")

    predicted = ""
    if ai_score is not None and not_ai_score is not None:
        predicted = "ai_generated" if ai_score >= not_ai_score else "not_ai_generated"
    elif ai_score is not None:
        predicted = "ai_generated"
    elif not_ai_score is not None:
        predicted = "not_ai_generated"

    # Optional: some projects/models include this
    deepfake_score = score_for("deepfake")

    # Optional: if your model emits source classes (e.g., "midjourney", "dalle", etc.),
    # pick the top non-binary class.
    exclude = {"ai_generated", "not_ai_generated", "deepfake"}
    top_source_class = ""
    top_source_score: Optional[float] = None
    for c in classes:
        name = c.get("class")
        if not name or name in exclude:
            continue
        try:
            sc = float(c.get("score"))
        except Exception:
            continue
        if top_source_score is None or sc > top_source_score:
            top_source_class, top_source_score = name, sc

    return {
        "ai_generated_score": ai_score if ai_score is not None else "",
        "not_ai_generated_score": not_ai_score if not_ai_score is not None else "",
        "predicted_generation": predicted,
        "deepfake_score": deepfake_score if deepfake_score is not None else "",
        "top_source_class": top_source_class,
        "top_source_score": top_source_score if top_source_score is not None else "",
        "c2pa_metadata": c2pa_metadata,
    }


def submit_to_hive_sync(
    image_path: Path,
    api_key_primary: str,
    api_key_secondary: str = "",
    endpoint: str = HIVE_SYNC_ENDPOINT,
    timeout_s: int = DEFAULT_TIMEOUT,
    max_retries: int = 2,
) -> Dict[str, Any]:
    """
    Submit a local image to Hive's v2 task/sync endpoint.

    Returns a dict with:
      - status: ok|error
      - http_status
      - error
      - parsed fields
      - raw_response (truncated)
    """
    if not api_key_primary:
        return {
            "status": "error",
            "http_status": "",
            "error": "Missing Hive API key. Set HIVE_API_KEY (or HIVE_ACCESS_KEY).",
            "raw_response": "",
        }

    keys_to_try = [api_key_primary] + ([api_key_secondary] if api_key_secondary else [])
    last_err = "Unknown error"
    last_http = ""

    for key_index, api_key in enumerate(keys_to_try, start=1):
        headers = {
            "Authorization": f"Token {api_key}",
            "Accept": "application/json",
        }

        # Note: keep the file handle open for the request; close immediately after.
        with image_path.open("rb") as f:
            files = {"media": (image_path.name, f)}

            for attempt in range(max_retries + 1):
                try:
                    resp = requests.post(endpoint, headers=headers, files=files, timeout=timeout_s)
                except requests.RequestException as e:
                    last_err = f"Request error: {e}"
                    last_http = ""
                    if attempt < max_retries:
                        time.sleep(1.5 * (attempt + 1))
                        continue
                    break

                last_http = str(resp.status_code)

                # Auth failure: try the secondary key if available
                if resp.status_code in (401, 403):
                    last_err = f"Auth failed with key #{key_index} (HTTP {resp.status_code})."
                    break

                # Retry transient failures
                if resp.status_code in (429, 500, 502, 503, 504):
                    last_err = f"Transient HTTP {resp.status_code}: {resp.text[:300]}"
                    if attempt < max_retries:
                        ra = resp.headers.get("Retry-After")
                        if ra and ra.isdigit():
                            time.sleep(int(ra))
                        else:
                            time.sleep(1.5 * (attempt + 1))
                        continue
                    break

                if resp.status_code != 200:
                    last_err = f"HTTP {resp.status_code}: {resp.text[:300]}"
                    break

                try:
                    resp_json = resp.json()
                except Exception:
                    last_err = f"Non-JSON response (HTTP 200): {resp.text[:300]}"
                    break

                parsed = parse_hive_response(resp_json)
                raw = json.dumps(resp_json)[:8000]

                return {
                    "status": "ok",
                    "http_status": str(resp.status_code),
                    "error": "",
                    **parsed,
                    "raw_response": raw,
                }

        # move to next key if auth failed
        continue

    return {
        "status": "error",
        "http_status": last_http,
        "error": last_err,
        "raw_response": "",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Hive AI-generated detection for screenshot compliance checking")
    parser.add_argument("--csv", required=True, help="Input CSV with screenshot paths")
    parser.add_argument("--out_csv", required=True, help="Output report CSV")
    parser.add_argument(
        "--path_cols",
        default="total_screenshot_path,app_screenshot1_path,app_screenshot2_path,app_screenshot3_path",
        help="Comma-separated column names containing image paths",
    )
    parser.add_argument("--sleep", type=float, default=DEFAULT_SLEEP, help="Seconds between API requests")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="HTTP timeout (seconds)")
    parser.add_argument("--endpoint", default=HIVE_SYNC_ENDPOINT, help="Hive sync endpoint URL")

    args = parser.parse_args()

    api_key_primary, api_key_secondary = get_api_keys()
    if not api_key_primary:
        print("ERROR: Hive API key missing.")
        print("Set one of:")
        print("  export HIVE_API_KEY='...'\n  (optional) export HIVE_API_KEY_2='...'\n")
        print("or:")
        print("  export HIVE_ACCESS_KEY='...'\n  export HIVE_SECRET_KEY='...'\n")
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
                    "not_ai_generated_score": "",
                    "predicted_generation": "",
                    "deepfake_score": "",
                    "top_source_class": "",
                    "top_source_score": "",
                    "c2pa_metadata": "",
                    "raw_response": "",
                })
                continue

            print(f"[hive_ai_gen] Scanning: {img_path.name}")
            result = submit_to_hive_sync(
                image_path=img_path,
                api_key_primary=api_key_primary,
                api_key_secondary=api_key_secondary,
                endpoint=args.endpoint,
                timeout_s=args.timeout,
            )

            rows.append({
                "task_id": task_id,
                "image_col": col,
                "image_path": str(img_path),
                "status": result.get("status", "error"),
                "http_status": result.get("http_status", ""),
                "error": result.get("error", ""),
                "ai_generated_score": result.get("ai_generated_score", ""),
                "not_ai_generated_score": result.get("not_ai_generated_score", ""),
                "predicted_generation": result.get("predicted_generation", ""),
                "deepfake_score": result.get("deepfake_score", ""),
                "top_source_class": result.get("top_source_class", ""),
                "top_source_score": result.get("top_source_score", ""),
                "c2pa_metadata": result.get("c2pa_metadata", ""),
                "raw_response": result.get("raw_response", ""),
            })

            time.sleep(args.sleep)

    out_df = pd.DataFrame(rows)
    out_path = Path(args.out_csv)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_df.to_csv(out_path, index=False)

    n_ok = int((out_df["status"] == "ok").sum())
    n_err = int((out_df["status"] == "error").sum())
    n_ai = int((out_df.get("predicted_generation") == "ai_generated").sum()) if "predicted_generation" in out_df else 0

    print(f"\n[hive_ai_gen] Results saved: {out_path}")
    print(f"[hive_ai_gen] Summary: {n_ok} ok, {n_err} errors, {n_ai} predicted ai_generated")

    if n_ai > 0:
        print("\n[hive_ai_gen] NOTE: ai_generated is a triage signal; review flagged cases manually.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())