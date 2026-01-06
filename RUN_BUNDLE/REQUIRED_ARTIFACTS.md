# RGSR REQUIRED ARTIFACTS (Canonical V1)

Engine Key: **RGSR**  
Semantics: **CORRELATION_ONLY**  
Authority: Engine Repo (Binding addendum; enforced by CORE Runtime)

This document is an addendum to:
`ScrappyHub/Core-platform/GOVERNANCE/RUN_BUNDLE_SPEC.md`

RGSR is a FUSION_ENGINE. It must always emit and preserve upstream provenance.  
Correlation ≠ causation.

---

## Required (in addition to standard RUN_BUNDLE spec)

### Required Provenance Artifact
- `INPUT_ARTIFACT_INDEX.json`

This file MUST list **all upstream artifacts** used by RGSR for the run, each with:
- `engine_code`
- `artifact_name`
- `sha256`

`INPUT_ARTIFACT_INDEX.json` MUST be:
- indexed in `ARTIFACT_INDEX.json`
- hashed in `SHA256SUMS.txt`
- consistent in content with the `input_artifact_index` field in RUN_OUTPUT.json

---

## Required Output Fields (RUN_OUTPUT.json)

RUN_OUTPUT.json MUST satisfy the engine OUTPUT_SCHEMA and MUST include:
- `semantics = CORRELATION_ONLY`
- `inputs_hash`
- `outputs_hash`
- `input_artifact_index` (array; same content class as INPUT_ARTIFACT_INDEX.json)

---

## Prohibitions

RGSR output MUST NOT include:
- causal claims
- intent/agency/actor attribution
- classification labels (missile/rocket/submarine/etc. — vertical lens only)
- identity/governance/billing fields
- peer delivery indicators (inputs are delivered by CORE only)
