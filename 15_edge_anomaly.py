#!/usr/bin/env python3
"""
truFor_wrapper_screenshots.py

Batch TruFor-based tamper triage for screen-time screenshots.

What it does:
- Runs TruFor inference to get:
    * image integrity score
    * localization (tamper) map
    * reliability map
- OCRs likely numeric/time ROIs (digit-bearing lines)
- Computes ROI anomaly = mean(localization * reliability_mask) over OCR ROIs
- Flags if either:
    * global score exceeds threshold, OR
    * any ROI anomaly exceeds threshold (more sensitive to small text overlays)

Dependencies:
  pip install numpy pandas opencv-python pillow pytesseract

External:
  - Clone TruFor repo (GRIP-UNINA)
  - Install torch/torchvision + TruFor deps per their instructions
  - Download TruFor weights (this script can do it)

Caveat:
  TruFor output .npz keys differ across versions. This script auto-detects arrays by shape/name heuristics.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import cv2
import numpy as np
import pandas as pd
import pytesseract
from PIL import Image
from urllib.request import urlretrieve


WEIGHTS_URL = "https://www.grip.unina.it/download/prog/TruFor/TruFor_weights.zip"  # official host
# directory listing: https://www.grip.unina.it/download/prog/TruFor/  (shows TruFor_weights.zip)  # noqa


@dataclass
class Box:
    x: int
    y: int
    w: int
    h: int
    text: str
    conf: float

    @property
    def x2(self) -> int:
        return self.x + self.w

    @property
    def y2(self) -> int:
        return self.y + self.h


def safe_filename(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", str(s))


def clamp_box(x: int, y: int, w: int, h: int, W: int, H: int) -> Tuple[int, int, int, int]:
    x = max(0, min(int(x), W - 1))
    y = max(0, min(int(y), H - 1))
    w = max(1, min(int(w), W - x))
    h = max(1, min(int(h), H - y))
    return x, y, w, h


def crop(img: np.ndarray, x: int, y: int, w: int, h: int) -> np.ndarray:
    return img[y:y + h, x:x + w]


def ensure_weights(weights_dir: Path) -> Path:
    """
    Ensure TruFor weights are present.
    Expects unzipped weights to land under weights_dir (e.g., weights/trufor.pth.tar).
    Returns the weights_dir.
    """
    weights_dir.mkdir(parents=True, exist_ok=True)
    # Heuristic: if any .pth or .tar exists, assume weights exist.
    existing = list(weights_dir.rglob("*.pth")) + list(weights_dir.rglob("*.pth.tar")) + list(weights_dir.rglob("*.tar"))
    if existing:
        return weights_dir

    zip_path = weights_dir / "TruFor_weights.zip"
    print(f"[weights] Downloading: {WEIGHTS_URL}")
    urlretrieve(WEIGHTS_URL, zip_path)

    print(f"[weights] Unzipping to: {weights_dir}")
    with zipfile.ZipFile(zip_path, "r") as zf:
        zf.extractall(weights_dir)

    try:
        zip_path.unlink()
    except Exception:
        pass

    return weights_dir


def find_trufor_infer_entrypoint(trufor_root: Path) -> Path:
    """
    Find a plausible TruFor test script under test_docker.
    Commonly 'test_docker/src/trufor_test.py' in many checkouts.
    """
    candidates = [
        trufor_root / "test_docker" / "src" / "trufor_test.py",
        trufor_root / "test_docker" / "src" / "test.py",
    ]
    for c in candidates:
        if c.exists():
            return c

    # Fallback: search for something containing "trufor" and "test" under test_docker/src
    src_dir = trufor_root / "test_docker" / "src"
    if src_dir.exists():
        for p in src_dir.rglob("*.py"):
            name = p.name.lower()
            if "trufor" in name and ("test" in name or "infer" in name):
                return p

    raise FileNotFoundError(
        "Could not find TruFor inference script under <trufor_root>/test_docker/src.\n"
        "Inspect that folder and update find_trufor_infer_entrypoint()."
    )


def run_trufor(
    trufor_root: Path,
    image_path: Path,
    out_dir: Path,
    gpu: int = -1,
    save_np: bool = False,
) -> Path:
    """
    Runs TruFor inference via its provided script.
    Returns the expected .npz path for the image.
    """
    script = find_trufor_infer_entrypoint(trufor_root)
    out_dir.mkdir(parents=True, exist_ok=True)

    # TruFor test code typically accepts something like:
    #   python trufor_test.py --gpu -1 --input <file_or_glob> --output <folder> [--save_np]
    # Must run from the src directory where trufor.yaml lives
    src_dir = script.parent

    # Convert paths to absolute
    image_path_abs = image_path.resolve()
    out_dir_abs = out_dir.resolve()

    cmd = [
        sys.executable, str(script.name),
        "-gpu", str(gpu),
        "-in", str(image_path_abs),
        "-out", str(out_dir_abs),
    ]
    if save_np:
        cmd.append("--save_np")

    print(f"[trufor] Running from {src_dir}: {' '.join(cmd)}")
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=str(src_dir))
    if proc.returncode != 0:
        raise RuntimeError(
            "TruFor inference failed.\n"
            f"STDOUT:\n{proc.stdout}\n\nSTDERR:\n{proc.stderr}"
        )

    # TruFor commonly writes: <out>/<image_name>.npz
    npz_path = out_dir / f"{image_path.name}.npz"
    if not npz_path.exists():
        # Fallback: pick newest .npz in out_dir
        npzs = sorted(out_dir.glob("*.npz"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not npzs:
            raise FileNotFoundError(f"No .npz output found in {out_dir}")
        npz_path = npzs[0]
    return npz_path


def _pick_array(npz: np.lib.npyio.NpzFile, want: str, H: int, W: int) -> Optional[np.ndarray]:
    """
    Heuristic array picker.
    want in {'score','loc','rel'}.
    """
    keys = list(npz.keys())

    # 1) Prefer name hints
    name_priority = []
    if want == "score":
        name_priority = ["score", "global", "integrity", "sigmoid"]
    elif want == "loc":
        name_priority = ["map", "mask", "loc", "pred", "tamper"]
    elif want == "rel":
        name_priority = ["reliab", "conf", "uncert"]

    def name_rank(k: str) -> int:
        lk = k.lower()
        for i, token in enumerate(name_priority):
            if token in lk:
                return i
        return 999

    # 2) Shape hints
    cand = []
    for k in keys:
        arr = npz[k]
        if want == "score":
            if np.isscalar(arr) or (isinstance(arr, np.ndarray) and arr.size == 1):
                cand.append((name_rank(k), k, arr))
        else:
            if isinstance(arr, np.ndarray):
                if arr.ndim == 2 and arr.shape[0] == H and arr.shape[1] == W:
                    cand.append((name_rank(k), k, arr))
                # some outputs are 1xHxW or HxWx1
                elif arr.ndim == 3:
                    if arr.shape[-2:] == (H, W):  # (C,H,W) or (1,H,W)
                        a = arr[0] if arr.shape[0] == 1 else arr[-1]
                        cand.append((name_rank(k), k, a))
                    elif arr.shape[:2] == (H, W):  # (H,W,C)
                        a = arr[..., 0]
                        cand.append((name_rank(k), k, a))

    if not cand:
        return None
    cand.sort(key=lambda t: t[0])
    return cand[0][2].astype(np.float32)


def load_trufor_outputs(npz_path: Path, img_shape: Tuple[int, int]) -> Dict[str, np.ndarray]:
    """
    Load TruFor outputs and return:
      - score (float32 scalar)
      - loc_map (H,W) float32, higher = more suspicious
      - rel_map (H,W) float32, higher = more reliable prediction
    """
    H, W = img_shape
    with np.load(npz_path, allow_pickle=True) as npz:
        score_arr = _pick_array(npz, "score", H, W)
        loc = _pick_array(npz, "loc", H, W)
        rel = _pick_array(npz, "rel", H, W)

        # If score missing but present in dict-like object
        if score_arr is None:
            # last resort: search for any scalar-ish
            for k in npz.keys():
                a = npz[k]
                if np.isscalar(a) or (isinstance(a, np.ndarray) and a.size == 1):
                    score_arr = a
                    break

        if score_arr is None or loc is None:
            raise KeyError(
                f"Could not infer required outputs from {npz_path}.\n"
                f"Available keys: {list(npz.keys())}"
            )

        score = float(score_arr) if not isinstance(score_arr, np.ndarray) else float(score_arr.reshape(-1)[0])

        # If reliability map missing, set to 1s (don’t block ROI scoring)
        if rel is None:
            rel = np.ones((H, W), dtype=np.float32)

        # Normalize maps gently to [0,1] if they look unbounded
        def norm01(m: np.ndarray) -> np.ndarray:
            m = m.astype(np.float32)
            lo, hi = np.percentile(m, 1), np.percentile(m, 99)
            if hi - lo < 1e-6:
                return np.clip(m, 0, 1)
            return np.clip((m - lo) / (hi - lo), 0, 1)

        loc = norm01(loc)
        rel = norm01(rel)

        return {"score": np.array(score, dtype=np.float32), "loc": loc, "rel": rel}


def ocr_line_boxes(img_bgr: np.ndarray, min_conf: float = 40, min_size: int = 18) -> List[Box]:
    """
    Line-level OCR boxes. Focus on digit-bearing lines to target screen-time numbers.
    """
    pil_img = Image.fromarray(cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB))
    ocr = pytesseract.image_to_data(pil_img, output_type=pytesseract.Output.DICT)

    lines: Dict[Tuple[int, int, int], Dict] = {}
    n = len(ocr.get("text", []))

    for i in range(n):
        txt = (ocr["text"][i] or "").strip()
        if not txt:
            continue
        try:
            conf = float(ocr["conf"][i])
        except Exception:
            conf = -1.0
        if conf < min_conf:
            continue

        x, y, w, h = int(ocr["left"][i]), int(ocr["top"][i]), int(ocr["width"][i]), int(ocr["height"][i])
        if w < min_size or h < min_size:
            continue

        key = (int(ocr["block_num"][i]), int(ocr["par_num"][i]), int(ocr["line_num"][i]))
        if key not in lines:
            lines[key] = {"x1": x, "y1": y, "x2": x + w, "y2": y + h, "words": [txt], "conf_sum": conf, "conf_n": 1}
        else:
            d = lines[key]
            d["x1"] = min(d["x1"], x)
            d["y1"] = min(d["y1"], y)
            d["x2"] = max(d["x2"], x + w)
            d["y2"] = max(d["y2"], y + h)
            d["words"].append(txt)
            d["conf_sum"] += conf
            d["conf_n"] += 1

    boxes: List[Box] = []
    for d in lines.values():
        text = " ".join(d["words"]).strip()
        # Focus digit-bearing lines (screen time numbers, minutes, etc.)
        if not any(ch.isdigit() for ch in text):
            continue
        x1, y1, x2, y2 = d["x1"], d["y1"], d["x2"], d["y2"]
        w, h = x2 - x1, y2 - y1
        if w < min_size or h < min_size:
            continue
        conf = d["conf_sum"] / max(1, d["conf_n"])
        boxes.append(Box(x=int(x1), y=int(y1), w=int(w), h=int(h), text=text, conf=float(conf)))
    return boxes


def roi_anomaly_score(loc: np.ndarray, rel: np.ndarray, roi: Box, rel_min: float = 0.4) -> float:
    """
    Reliability-weighted ROI anomaly score:
      mean(loc * I(rel>=rel_min)) within ROI
    """
    H, W = loc.shape
    x, y, w, h = clamp_box(roi.x, roi.y, roi.w, roi.h, W, H)
    l = crop(loc, x, y, w, h)
    r = crop(rel, x, y, w, h)
    m = (r >= rel_min).astype(np.float32)
    if m.mean() < 0.15:
        # not enough reliable pixels => downweight strongly
        return float((l * r).mean() * 0.25)
    return float((l * m).mean())


def save_crop(img_bgr: np.ndarray, roi: Box, out_path: Path, pad: int = 24) -> None:
    H, W = img_bgr.shape[:2]
    x0, y0, w0, h0 = clamp_box(roi.x - pad, roi.y - pad, roi.w + 2 * pad, roi.h + 2 * pad, W, H)
    patch = crop(img_bgr, x0, y0, w0, h0)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(out_path), patch)


def analyze_image(
    trufor_root: Path,
    image_path: Path,
    out_dir: Path,
    gpu: int,
    min_conf: float,
    min_size: int,
    global_thresh: float,
    roi_thresh: float,
    rel_min: float,
) -> Dict:
    img = cv2.imread(str(image_path))
    if img is None:
        return {"status": "error", "error": "Could not read image"}

    H, W = img.shape[:2]
    npz_path = run_trufor(trufor_root, image_path, out_dir, gpu=gpu)
    outs = load_trufor_outputs(npz_path, (H, W))
    score = float(outs["score"])
    loc, rel = outs["loc"], outs["rel"]

    rois = ocr_line_boxes(img, min_conf=min_conf, min_size=min_size)

    roi_rows = []
    max_roi = 0.0
    best_roi = None

    for roi in rois:
        s = roi_anomaly_score(loc, rel, roi, rel_min=rel_min)
        roi_rows.append((roi, s))
        if s > max_roi:
            max_roi = s
            best_roi = roi

    flagged = (score >= global_thresh) or (max_roi >= roi_thresh)

    return {
        "status": "flagged" if flagged else "ok",
        "error": "",
        "trufor_score": score,
        "max_roi_score": max_roi,
        "n_rois": len(rois),
        "best_roi": best_roi,
        "npz_path": str(npz_path),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trufor_root", required=True, help="Path to cloned TruFor repo")
    ap.add_argument("--csv", required=True, help="Input CSV with screenshot path columns")
    ap.add_argument("--out_csv", required=True, help="Output report CSV path")
    ap.add_argument("--out_dir", required=True, help="Directory for TruFor .npz outputs")
    ap.add_argument("--crops_dir", required=True, help="Directory to save flagged crops")
    ap.add_argument("--weights_dir", default="", help="Optional: where to download weights (default: <trufor_root>/test_docker/weights)")

    ap.add_argument("--gpu", type=int, default=-1, help="GPU id, use -1 for CPU")
    ap.add_argument("--min_conf", type=float, default=40)
    ap.add_argument("--min_size", type=int, default=18)

    # Thresholds: tune these on a labeled dev set
    ap.add_argument("--global_thresh", type=float, default=0.50, help="Flag if TruFor global score >= this")
    ap.add_argument("--roi_thresh", type=float, default=0.22, help="Flag if max ROI anomaly >= this (more sensitive)")
    ap.add_argument("--rel_min", type=float, default=0.40, help="Only count pixels with reliability >= this in ROI scoring")

    ap.add_argument("--path_cols", default="total_screenshot_path,app_screenshot1_path,app_screenshot2_path,app_screenshot3_path")

    args = ap.parse_args()

    trufor_root = Path(args.trufor_root).expanduser().resolve()
    out_dir = Path(args.out_dir).expanduser().resolve()
    crops_dir = Path(args.crops_dir).expanduser().resolve()
    out_csv = Path(args.out_csv).expanduser().resolve()

    # Ensure weights exist (many TruFor setups expect them in test_docker/weights)
    weights_dir = Path(args.weights_dir).expanduser().resolve() if args.weights_dir else (trufor_root / "test_docker" / "weights")
    ensure_weights(weights_dir)

    df = pd.read_csv(args.csv)
    path_cols = [c.strip() for c in args.path_cols.split(",") if c.strip()]

    rows = []
    for i, r in df.iterrows():
        task_id = r.get("task_id", f"row_{i}")
        for col in path_cols:
            if col not in r or pd.isna(r[col]):
                continue
            img_path = Path(str(r[col])).expanduser()
            if not img_path.exists():
                rows.append({
                    "task_id": task_id, "image_col": col, "image_path": str(img_path),
                    "status": "error", "error": "File not found",
                    "trufor_score": np.nan, "max_roi_score": np.nan, "n_rois": 0, "npz_path": ""
                })
                continue

            try:
                res = analyze_image(
                    trufor_root=trufor_root,
                    image_path=img_path,
                    out_dir=out_dir,
                    gpu=args.gpu,
                    min_conf=args.min_conf,
                    min_size=args.min_size,
                    global_thresh=args.global_thresh,
                    roi_thresh=args.roi_thresh,
                    rel_min=args.rel_min,
                )
                best_roi = res.get("best_roi")
                crop_path = ""
                if res["status"] == "flagged" and best_roi is not None:
                    crop_name = f"{safe_filename(task_id)}_{safe_filename(col)}_roi{res['max_roi_score']:.3f}_g{res['trufor_score']:.3f}.png"
                    crop_path = str((crops_dir / crop_name))
                    img_bgr = cv2.imread(str(img_path))
                    save_crop(img_bgr, best_roi, Path(crop_path), pad=28)

                rows.append({
                    "task_id": task_id,
                    "image_col": col,
                    "image_path": str(img_path),
                    "status": res["status"],
                    "error": res.get("error", ""),
                    "trufor_score": res.get("trufor_score", np.nan),
                    "max_roi_score": res.get("max_roi_score", np.nan),
                    "n_rois": res.get("n_rois", 0),
                    "npz_path": res.get("npz_path", ""),
                    "best_roi_text": (best_roi.text[:80] if best_roi else ""),
                    "best_roi_conf": (best_roi.conf if best_roi else np.nan),
                    "crop_path": crop_path
                })
            except Exception as e:
                rows.append({
                    "task_id": task_id, "image_col": col, "image_path": str(img_path),
                    "status": "error", "error": str(e),
                    "trufor_score": np.nan, "max_roi_score": np.nan, "n_rois": 0, "npz_path": ""
                })

    out = pd.DataFrame(rows)
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    out.to_csv(out_csv, index=False)
    print(f"Saved report: {out_csv}")
    print(f"Saved crops (flagged): {crops_dir}")


if __name__ == "__main__":
    main()
