from __future__ import annotations
import argparse
from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt

def save_curve(df: pd.DataFrame, x: str, y: str, out: Path, title: str):
    plt.figure()
    plt.plot(df[x], df[y])
    plt.xlabel(x)
    plt.ylabel(y)
    plt.title(title)
    plt.grid(True, which="both", linestyle=":")
    plt.tight_layout()
    plt.savefig(out, dpi=150)
    plt.close()

def estimate_band(df: pd.DataFrame, x: str, y: str):
    # "3 dB-ish" bandwidth on amplitude proxy: threshold = peak / sqrt(2)
    peak_idx = df[y].idxmax()
    peak_x = float(df.loc[peak_idx, x])
    peak_y = float(df.loc[peak_idx, y])
    thr = peak_y / (2 ** 0.5)

    left = df[df[x] <= peak_x]
    right = df[df[x] >= peak_x]

    left_cross = left[left[y] < thr].tail(1)
    right_cross = right[right[y] < thr].head(1)

    f_lo = float(left_cross[x].values[0]) if len(left_cross) else float(left[x].min())
    f_hi = float(right_cross[x].values[0]) if len(right_cross) else float(right[x].max())

    return peak_x, peak_y, f_lo, f_hi

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    ap.add_argument("--outdir", required=True)
    args = ap.parse_args()

    csv = Path(args.csv)
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    df = pd.read_csv(csv)
    df = df.sort_values("drive_hz").reset_index(drop=True)

    # Plots
    save_curve(df, "drive_hz", "em_rms", outdir / "em_rms_vs_drive_hz.png", "EM_RMS vs drive_hz")
    save_curve(df, "drive_hz", "vib_rms", outdir / "vib_rms_vs_drive_hz.png", "VIB_RMS vs drive_hz")
    save_curve(df, "drive_hz", "chamber_rms", outdir / "chamber_rms_vs_drive_hz.png", "CHAMBER_RMS vs drive_hz")

    # Best band (using em_rms)
    peak_x, peak_y, f_lo, f_hi = estimate_band(df, "drive_hz", "em_rms")
    txt = outdir / "best_band.txt"
    txt.write_text(
        f"peak_drive_hz={peak_x}\n"
        f"peak_em_rms={peak_y}\n"
        f"band_lo_hz={f_lo}\n"
        f"band_hi_hz={f_hi}\n",
        encoding="utf-8"
    )

    print(f"Wrote plots + best_band.txt to: {outdir}")

if __name__ == "__main__":
    main()
