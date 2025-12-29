# Planetary Pyramid Network (PPN)

This workspace is a structured research + build environment for testing the **Planetary Resonance Grid Hypothesis**
using falsifiable experiments (Phase 1 / Phase 2), sensors, signal processing, and (optional) simulation.

## Folder Map
- 01_DOCS: Theory, methods, references
- 02_EXPERIMENTS: Test plans and run logs
- 03_HARDWARE: BOM, sensor specs, build logs
- 04_DATA: Raw + processed datasets and metadata
- 05_ANALYSIS: Notebooks, reports, figures
- 06_SIMULATION: Optional multiphysics work
- 07_SOFTWARE: Python tooling + scripts
- 08_AUTOMATION: PowerShell pipelines (data ingest, run book helpers)

## Golden Rules
1) Everything must be testable, measurable, and logged.
2) Every experiment has: plan → instrumentation → run → analysis → report.
3) Raw data is immutable (never overwrite RAW).
4) Reports reference exact dataset + commit hash (if using git).