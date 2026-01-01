# RGSR / PPN Engine Output Contract (V1)

**Status:** LOCKED
**Scope:** Layer 1 (Core Engine) output naming + presence expectations.

## Required Run Artifacts (minimum set)
Produced under:
`05_ANALYSIS/REPORTS/<P2>/_AB_COMPARE/`

### Must Exist
- RUN_CONDITIONS.json
- SHA256SUMS.txt
- AB_inputs_pointer.txt

### Expected (when AB compare artifacts exist)
- AB_compare_P1_vs_P2.csv
- AB_in_band_summary.txt

### Optional (if produced by analyzers)
- delta_em_rms_in_band.png
- delta_em_rms_vs_drive_hz.png
- delta_vib_rms_vs_drive_hz.png
- delta_chamber_rms_vs_drive_hz.png

## Invariants
- Layer 1 produces **no identity** and performs **no network calls**.
- Any "publication" or "lane promotion" is Layer 2/3 only.
- Outputs are append-only.

## Schema IDs (stable strings)
- RUN_CONDITIONS schema: `PPN_RUN_CONDITIONS_V1`
- Pointer footer marker: `PPN_REPRODUCIBILITY_V1`
