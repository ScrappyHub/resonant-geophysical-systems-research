from __future__ import annotations

from dataclasses import dataclass, asdict
from pathlib import Path
import json
import numpy as np
from scipy.signal import iirpeak, lfilter

@dataclass
class ResonanceConfig:
    fs_hz: float = 2000.0
    seconds: float = 30.0

    # Water driver (pressure oscillation proxy)
    drive_hz: float = 20.0
    drive_amp: float = 1.0
    drive_noise: float = 0.02

    # Acoustic chamber resonance (2nd-order bandpass via iirpeak)
    chamber_f0_hz: float = 25.0
    chamber_q: float = 12.0
    chamber_gain: float = 3.0

    # Stone vibration resonance
    stone_f0_hz: float = 32.0
    stone_q: float = 18.0
    stone_gain: float = 2.0

    # Piezo -> EM proxy coefficient (not a claim, a measurable proxy variable)
    piezo_k: float = 0.05

    # Optional nonlinearity (cavitation-ish proxy)
    nonlinearity: float = 0.10

@dataclass
class ResonanceResult:
    drive_hz: float
    chamber_f0_hz: float
    stone_f0_hz: float
    em_rms: float
    vib_rms: float
    chamber_rms: float
    peak_em_hz: float

def _bandpass_iir(x: np.ndarray, fs: float, f0: float, q: float, gain: float) -> np.ndarray:
    # iirpeak gives a second-order bandpass centered at f0
    b, a = iirpeak(w0=f0, Q=q, fs=fs)
    y = lfilter(b, a, x)
    return gain * y

def _fft_peak_hz(x: np.ndarray, fs: float) -> float:
    n = len(x)
    w = np.hanning(n)
    X = np.fft.rfft(x * w)
    f = np.fft.rfftfreq(n, d=1.0/fs)
    mag = np.abs(X)
    idx = int(np.argmax(mag[1:])) + 1
    return float(f[idx])

def run_once(cfg: ResonanceConfig, seed: int = 1) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, ResonanceResult]:
    rng = np.random.default_rng(seed)
    n = int(cfg.fs_hz * cfg.seconds)
    t = np.arange(n) / cfg.fs_hz

    # Water pressure driver
    drive = cfg.drive_amp * np.sin(2*np.pi*cfg.drive_hz*t)
    drive += cfg.drive_noise * rng.normal(size=n)

    # Mild nonlinearity (proxy for turbulence/cavitation harmonics)
    if cfg.nonlinearity > 0:
        drive = drive + cfg.nonlinearity * np.tanh(2.5 * drive)

    # Chamber acoustic response
    chamber = _bandpass_iir(drive, cfg.fs_hz, cfg.chamber_f0_hz, cfg.chamber_q, cfg.chamber_gain)

    # Stone vibration response
    vib = _bandpass_iir(chamber, cfg.fs_hz, cfg.stone_f0_hz, cfg.stone_q, cfg.stone_gain)

    # EM proxy (piezoelectric coupling proxy): proportional to strain-rate-ish magnitude
    dv = np.gradient(vib) * cfg.fs_hz
    em = cfg.piezo_k * dv

    res = ResonanceResult(
        drive_hz=cfg.drive_hz,
        chamber_f0_hz=cfg.chamber_f0_hz,
        stone_f0_hz=cfg.stone_f0_hz,
        em_rms=float(np.sqrt(np.mean(em**2))),
        vib_rms=float(np.sqrt(np.mean(vib**2))),
        chamber_rms=float(np.sqrt(np.mean(chamber**2))),
        peak_em_hz=_fft_peak_hz(em, cfg.fs_hz),
    )
    return t, drive, chamber, em, res

def sweep(cfg: ResonanceConfig, drive_hz_list: list[float], seed: int = 1) -> list[ResonanceResult]:
    out: list[ResonanceResult] = []
    for i, hz in enumerate(drive_hz_list):
        c = ResonanceConfig(**asdict(cfg))
        c.drive_hz = float(hz)
        _, _, _, _, r = run_once(c, seed=seed + i)
        out.append(r)
    return out

def write_results(out_dir: str | Path, cfg: ResonanceConfig, results: list[ResonanceResult]) -> Path:
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    payload = {
        "config": asdict(cfg),
        "results": [asdict(r) for r in results],
    }
    path = out_dir / "resonance_sweep.json"
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return path
