# 📦 RGSR — REQUIRED RUN ARTIFACTS (CANONICAL V1)

This document is an addendum to ScrappyHub/Core-platform/GOVERNANCE/RUN_BUNDLE_SPEC.md.
Authority Level: Engine Repo Spec (Binding declaration; enforced by CORE Runtime)
Status: ✅ LOCKED | ✅ BINDING | ✅ NON-OPTIONAL

## Required (In Addition to core-platform/GOVERNANCE/RUN_BUNDLE_SPEC.md)
RGSR runs MUST include:
- INPUT_ARTIFACT_INDEX.json (non-empty; hash-referenced upstream artifacts)

## Output Requirements
RGSR RUN_OUTPUT.json MUST:
- declare semantics = CORRELATION_ONLY
- include input_artifact_index (non-empty)
- reference upstream artifacts by SHA-256 hash
- prohibit causal, intent, attribution, or agency language

## Replay Rule
A RGSR run is replayable only if:
- upstream referenced artifacts exist
- hashes match SHA256SUMS.txt
- RGSR output replays byte-identically under JCS (RFC 8785)
