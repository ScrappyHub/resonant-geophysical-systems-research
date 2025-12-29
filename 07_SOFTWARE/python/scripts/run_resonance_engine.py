from __future__ import annotations
import argparse
from pathlib import Path
import numpy as np
from ppn.analysis.resonance_engine import ResonanceConfig, sweep, write_results

def main():
    ap = argparse.ArgumentParser(description="PPN Resonance Engine v1 (synthetic coupled model)")
    ap.add_argument("--out", required=True, help="Output directory for results")
    ap.add_argument("--fs", type=float, default=2000.0)
    ap.add_argument("--seconds", type=float, default=30.0)

    ap.add_argument("--fmin", type=float, default=1.0)
    ap.add_argument("--fmax", type=float, default=150.0)
    ap.add_argument("--fstep", type=float, default=1.0)

    ap.add_argument("--chamber_f0", type=float, default=25.0)
    ap.add_argument("--chamber_q", type=float, default=12.0)

    ap.add_argument("--stone_f0", type=float, default=32.0)
    ap.add_argument("--stone_q", type=float, default=18.0)

    ap.add_argument("--piezo_k", type=float, default=0.05)
    ap.add_argument("--seed", type=int, default=1)

    args = ap.parse_args()

    cfg = ResonanceConfig(
        fs_hz=args.fs,
        seconds=args.seconds,
        chamber_f0_hz=args.chamber_f0,
        chamber_q=args.chamber_q,
        stone_f0_hz=args.stone_f0,
        stone_q=args.stone_q,
        piezo_k=args.piezo_k
    )

    drive_list = np.arange(args.fmin, args.fmax + 1e-9, args.fstep).tolist()
    results = sweep(cfg, drive_list, seed=args.seed)
    path = write_results(Path(args.out), cfg, results)
    print(f"Wrote: {path}")

if __name__ == "__main__":
    main()
