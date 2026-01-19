#!/usr/bin/env python3
"""
test_sightengine.py

Quick test script to verify Sightengine AI detection on known AI-generated images.

Usage:
  python test_sightengine.py

Expects test images in data/test_ai_images/
"""

import os
import sys
from pathlib import Path

from dotenv import load_dotenv

# Import the detection function from our main script
from importlib.util import spec_from_loader, module_from_spec
from importlib.machinery import SourceFileLoader

# Load the main module
spec = spec_from_loader("sightengine", SourceFileLoader("sightengine", "17_sightengine_ai_detection.py"))
sightengine = module_from_spec(spec)
spec.loader.exec_module(sightengine)

load_dotenv()

TEST_DIR = Path("data/test_ai_images")
THRESHOLD = 0.5


def main():
    api_user, api_secret = sightengine.get_api_credentials()
    if not api_user or not api_secret:
        print("ERROR: Missing Sightengine credentials in .env")
        return 1

    if not TEST_DIR.exists():
        print(f"ERROR: Test directory not found: {TEST_DIR}")
        return 1

    # Find all images
    image_extensions = {".jpg", ".jpeg", ".png", ".gif", ".webp"}
    images = [f for f in TEST_DIR.iterdir() if f.suffix.lower() in image_extensions]

    if not images:
        print(f"No images found in {TEST_DIR}")
        return 1

    print(f"Testing Sightengine AI detection on {len(images)} images")
    print(f"Threshold for flagging: {THRESHOLD}")
    print("=" * 60)

    results = []
    for img_path in sorted(images):
        print(f"\nScanning: {img_path.name}")
        result = sightengine.detect_ai_generated(
            image_path=img_path,
            api_user=api_user,
            api_secret=api_secret,
        )

        status = result.get("status")
        score = result.get("ai_generated_score", "")
        error = result.get("error", "")

        if status == "ok" and score != "":
            score = float(score)
            flagged = score >= THRESHOLD
            flag_str = "🚨 FLAGGED" if flagged else "✓ OK"
            print(f"  Score: {score:.3f} ({score*100:.1f}% AI) {flag_str}")
            results.append({"image": img_path.name, "score": score, "flagged": flagged})
        else:
            print(f"  ERROR: {error}")
            results.append({"image": img_path.name, "score": None, "flagged": None, "error": error})

    # Summary
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)

    successful = [r for r in results if r.get("score") is not None]
    if successful:
        avg_score = sum(r["score"] for r in successful) / len(successful)
        n_flagged = sum(1 for r in successful if r["flagged"])
        print(f"Images tested: {len(successful)}")
        print(f"Average AI score: {avg_score:.3f} ({avg_score*100:.1f}%)")
        print(f"Flagged as AI-generated: {n_flagged}/{len(successful)}")

        if n_flagged == len(successful):
            print("\n✓ All known AI images correctly detected!")
        elif n_flagged > 0:
            print(f"\n⚠ Only {n_flagged}/{len(successful)} AI images detected")
        else:
            print("\n✗ No AI images detected - detection may not be working")

    errors = [r for r in results if r.get("error")]
    if errors:
        print(f"\nErrors: {len(errors)}")
        for r in errors:
            print(f"  - {r['image']}: {r.get('error')}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
