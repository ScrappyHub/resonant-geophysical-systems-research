# Methods (Minimum Standard)

## Experimental logging
Each run must record:
- experiment_id
- timestamp start/end
- configuration (geometry/material/water/drive)
- sensor calibration info
- sampling rates, units
- environment notes (temperature, noise sources)
- raw file paths (immutable)

## Data handling
- RAW: write-once, read-many
- PROCESSED: derived outputs
- METADATA: run descriptors, configs, calibration tables

## Analysis
- prefer FFT + spectrogram + coherence + cross-correlation
- always compare against control runs (no water, no drive, dummy geometry)