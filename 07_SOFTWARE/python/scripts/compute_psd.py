# Example placeholder: load a CSV time-series and compute PSD
# Expected CSV columns: t, x
import pandas as pd
import numpy as np
from ppn.signal.spectral import psd

def main(path: str, fs: float):
    df = pd.read_csv(path)
    x = df['x'].to_numpy(dtype=float)
    f, pxx = psd(x, fs)
    out = pd.DataFrame({'f_hz': f, 'psd': pxx})
    out.to_csv('psd_out.csv', index=False)
    print('Wrote psd_out.csv')

if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--fs", type=float, required=True)
    args = ap.parse_args()
    main(args.path, args.fs)