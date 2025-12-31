# PPN Master Index (Operator Entry Point)

Operator-grade docs so another engineer can run, verify, and extend PPN without touching canonical 1-10 files.

## Quick Start
- One-Shot A/B Builder:
  - pwsh -NoProfile -ExecutionPolicy Bypass -File "08_AUTOMATION\powershell\ppn_ab_one_shot.ps1"
  - pwsh -NoProfile -ExecutionPolicy Bypass -File "08_AUTOMATION\powershell\ppn_ab_one_shot.ps1" -Only "PPN-P2-0002","PPN-P2-0001"

## Documents
- CANONICAL_COMMANDS.md
- TESTING_PLAYBOOK.md
- DATA_FLOWS.md
- ANOMALY_CATALOG.md
- GLOSSARY.md

## Repo Structure (high level)
- 04_DATA\RAW\PPN-P2-****  (existence gate)
- 04_DATA\PROCESSED\PPN-*\resonance_engine_v1\resonance_sweep.csv
- 05_ANALYSIS\REPORTS\PPN-P2-****\_AB_COMPARE\
- 08_AUTOMATION\powershell\
