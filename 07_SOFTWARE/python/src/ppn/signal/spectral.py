from __future__ import annotations
import numpy as np
from scipy.signal import welch, spectrogram

def psd(x: np.ndarray, fs: float, nperseg: int = 4096):
    f, pxx = welch(x, fs=fs, nperseg=nperseg)
    return f, pxx

def spec(x: np.ndarray, fs: float, nperseg: int = 2048, noverlap: int = 1024):
    f, t, sxx = spectrogram(x, fs=fs, nperseg=nperseg, noverlap=noverlap)
    return f, t, sxx