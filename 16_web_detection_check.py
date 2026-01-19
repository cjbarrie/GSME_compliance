#!/usr/bin/env python3
"""
16_google_web_detection_check.py

Batch Google Cloud Vision "Web Detection" reverse image search for screenshot compliance checking.

Goal (TinEye-like logic):
- Use Google's Web Detection to find pages/images on the web that match the uploaded screenshot.
- Flag ONLY "full matching images" as "match" (closest analogue to TinEye exact matches).
- Optionally record partial matches + pages for manual review context.

Usage:
    python 16_google_web_detection_check.py \
        --csv data/qualtrics/team_example/baseline/results/sample_avg.csv \
        --out_csv data/qualtrics/team_example/baseline/results/web_detection_report.csv

Auth (recommended, standard for Vision API):
- Set GOOGLE_APPLICATION_CREDENTIALS to a service-account JSON file path, e.g.
    export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service_account.json"

Requirements:
    pip install google-cloud-vision pandas python-dotenv

Notes:
- Google Web Detection returns several result types:
    * full_matching_images: closest to "exact matches"
    * partial_matching_images: resized/cropped/variant
    * pages_with_matching_images: where matching images were found
    * web_entities: concepts/entities (less useful for exact match)
- If you truly want "exact matches" only, this script flags only full_matching_images.
"""

import argparse
import os
import time
from pathlib import Path
from typing import Any, Dict, List

import pandas as pd
from dotenv import load_dotenv

load_dotenv()

DEFAULT_SLEEP = 1.0  # seconds between requests


def _domain_from_url(url: str) -> str:
    try:
        # minimal parsing without extra deps
        if "://" in url:
            url = url.split("://", 1)[1]
        return url.split("/", 1)[0].lower()
    except Exception:
        return ""


def web_detect_image(client: Any, image_path: Path, max_results: int = 10) -> Dict[str, Any]:
    """
    Run Google Vision Web Detection on a local image file.

    Returns dict with:
        - status: 'match', 'no_match', or 'error'
        - n_full_matches
        - n_partial_matches
        - n_pages
        - full_matches: list of {url, score}
        - partial_matches: list of {url, score}
        - pages: list of {url, score}
        - top_full_match_url/domain/score
        - top_page_url/domain/score
        - error
    """
    try:
        from google.cloud import vision  # type: ignore
    except ImportError:
        return {
            "status": "error",
            "error": "google-cloud-vision not installed. Run: pip install google-cloud-vision",
            "n_full_matches": 0,
            "n_partial_matches": 0,
            "n_pages": 0,
            "full_matches": [],
            "partial_matches": [],
            "pages": [],
            "top_full_match_url": "",
            "top_full_match_domain": "",
            "top_full_match_score": "",
            "top_page_url": "",
            "top_page_domain": "",
            "top_page_score": "",
        }

    try:
        content = image_path.read_bytes()
        image = vision.Image(content=content)

        # Web Detection call
        response = client.web_detection(image=image)
        if response.error and response.error.message:
            raise RuntimeError(response.error.message)

        wd = response.web_detection

        # Collect full matching images (closest analogue to "exact match")
        full_matches = []
        for im in (wd.full_matching_images or [])[:max_results]:
            full_matches.append({
                "url": im.url,
                "score": float(im.score) if im.score is not None else None
            })

        # Collect partial matching images (variants)
        partial_matches = []
        for im in (wd.partial_matching_images or [])[:max_results]:
            partial_matches.append({
                "url": im.url,
                "score": float(im.score) if im.score is not None else None
            })

        # Pages containing matching images
        pages = []
        for p in (wd.pages_with_matching_images or [])[:max_results]:
            pages.append({
                "url": p.url,
                "score": float(p.score) if p.score is not None else None
            })

        top_full = full_matches[0] if full_matches else {}
        top_page = pages[0] if pages else {}

        status = "match" if len(full_matches) > 0 else "no_match"

        return {
            "status": status,
            "error": "",
            "n_full_matches": len(full_matches),
            "n_partial_matches": len(partial_matches),
            "n_pages": len(pages),
            "full_matches": full_matches,
            "partial_matches": partial_matches,
            "pages": pages,
            "top_full_match_url": top_full.get("url", ""),
            "top_full_match_domain": _domain_from_url(top_full.get("url", "")),
            "top_full_match_score": top_full.get("score", ""),
            "top_page_url": top_page.get("url", ""),
            "top_page_domain": _domain_from_url(top_page.get("url", "")),
            "top_page_score": top_page.get("score", ""),
        }

    except Exception as e:
        return {
            "status": "error",
            "error": str(e),
            "n_full_matches": 0,
            "n_partial_matches": 0,
            "n_pages": 0,
            "full_matches": [],
            "partial_matches": [],
            "pages": [],
            "top_full_match_url": "",
            "top_full_match_domain": "",
            "top_full_match_score": "",
            "top_page_url": "",
            "top_page_domain": "",
            "top_page_score": "",
        }


def main() -> int:
    parser = argparse.ArgumentParser(description="Google Vision Web Detection reverse image search for compliance")
    parser.add_argument("--csv", required=True, help="Input CSV with screenshot paths")
    parser.add_argument("--out_csv", required=True, help="Output report CSV")
    parser.add_argument(
        "--path_cols",
        default="total_screenshot_path,app_screenshot1_path,app_screenshot2_path,app_screenshot3_path",
        help="Comma-separated column names containing image paths",
    )
    parser.add_argument("--sleep", type=float, default=DEFAULT_SLEEP, help="Seconds between API requests")
    parser.add_argument("--max_results", type=int, default=10, help="Max URLs to store per result type")

    args = parser.parse_args()

    # Basic auth check: GOOGLE_APPLICATION_CREDENTIALS should be set for google-cloud-vision
    creds = os.getenv("GOOGLE_APPLICATION_CREDENTIALS", "")
    if not creds:
        print("ERROR: GOOGLE_APPLICATION_CREDENTIALS is not set.")
        print("Set it to the path of your Google service-account JSON, e.g.:")
        print('  export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service_account.json"')
        print("Then re-run. (You must also enable the Vision API for your GCP project.)")
        return 1
    if not Path(creds).expanduser().exists():
        print(f"ERROR: GOOGLE_APPLICATION_CREDENTIALS points to a missing file: {creds}")
        return 1

    # Import and initialize Vision client
    try:
        from google.cloud import vision  # type: ignore
    except ImportError:
        print("ERROR: google-cloud-vision not installed. Run: pip install google-cloud-vision")
        return 1

    try:
        client = vision.ImageAnnotatorClient()
    except Exception as e:
        print(f"ERROR: could not initialize Vision client: {e}")
        return 1

    # Load input CSV
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
                    "error": "File not found",
                    "n_full_matches": 0,
                    "n_partial_matches": 0,
                    "n_pages": 0,
                    "top_full_match_domain": "",
                    "top_full_match_url": "",
                    "top_full_match_score": "",
                    "top_page_domain": "",
                    "top_page_url": "",
                    "top_page_score": "",
                })
                continue

            print(f"[web_detection] Searching: {img_path.name}")
            result = web_detect_image(client, img_path, max_results=args.max_results)

            rows.append({
                "task_id": task_id,
                "image_col": col,
                "image_path": str(img_path),
                "status": result["status"],
                "error": result["error"],
                # TinEye-like "match count" field:
                # Here, "exact match" analogue is full matching images only.
                "n_full_matches": result["n_full_matches"],
                "n_partial_matches": result["n_partial_matches"],
                "n_pages": result["n_pages"],
                "top_full_match_domain": result["top_full_match_domain"],
                "top_full_match_url": result["top_full_match_url"],
                "top_full_match_score": result["top_full_match_score"],
                "top_page_domain": result["top_page_domain"],
                "top_page_url": result["top_page_url"],
                "top_page_score": result["top_page_score"],
                # Store full lists as JSON-ish strings for auditing (optional)
                "full_matches": str(result["full_matches"]),
                "partial_matches": str(result["partial_matches"]),
                "pages": str(result["pages"]),
            })

            time.sleep(args.sleep)

    # Save report
    out_df = pd.DataFrame(rows)
    out_path = Path(args.out_csv)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_df.to_csv(out_path, index=False)

    # Summary
    n_match = int((out_df["status"] == "match").sum())
    n_no = int((out_df["status"] == "no_match").sum())
    n_err = int((out_df["status"] == "error").sum())

    print(f"\n[web_detection] Results saved: {out_path}")
    print(f"[web_detection] Summary: {n_match} exact-like matches, {n_no} no match, {n_err} errors")

    if n_match > 0:
        print(f"\n[web_detection] WARNING: {n_match} image(s) returned full matching images!")
        print("[web_detection] These should be manually inspected for compliance.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
