# RGSR Reproducibility Spec V1

## Goal
Make every result re-runnable and comparable across time, machines, and operators.

## Required Run Artifacts (per run)
- AB_inputs_pointer.txt (deterministic pointer)
- RUN_CONDITIONS.json (schema-stable)
- CONDITIONS_SHA256 (hash of RUN_CONDITIONS.json)
- git_head (commit hash)
- input bundle pointer (P1 export bundle + best_band)
- key outputs (csv + summary + plots)
- SHA256SUMS.txt covering outputs (+ conditions file)

## Condition Profiles
Condition profiles are stored under:
- conditions/profiles/*.json

A run references exactly one ConditionProfile:
- ConditionProfile = profile file name (without extension)
- The profile JSON is embedded into RUN_CONDITIONS.json or referenced by hash/path

## Strict Mode (future)
When strict mode is enabled, the runner fails-fast if required condition fields are missing.

Required minimum in strict mode:
- profile, environment (dry/humid/water state)
- humidity_rh, temp_c (for dry/humid comparisons)
- mounting, drive_profile, sensor_pack, sample_id
- operator