# 🧬 CORE ENGINE — RGSR GOVERNANCE (CANONICAL)

Engine Key: **RGSR**  
Authority Level: Engine Governance (Binding)  
Status: ✅ BINDING | ✅ NON-OPTIONAL  

## 1. Authority & Inheritance

RGSR is permanently bound by CORE platform governance, including:

- CORE_CONSTITUTIONAL_STOP_LAYER.md  
- CORE_PLATFORM_CONSTITUTION.md  
- CORE_ENGINE_REGISTRY_AND_VERTICAL_INHERITANCE_LAW.md  
- CORE_GOVERNANCE_INDEX_CHAIN_OF_AUTHORITY.md  
- CORE_ENGINE_REGISTRY_CONTRACT.md  

RGSR defines computation only.  
RGSR has no independent authority.

## 2. Scope (What RGSR Is)

RGSR is a **correlation/relationship integrator** (coherence mapper) operating on sealed domain artifacts.

RGSR may compute:

- correlations and cross-correlations  
- coherence / phase-locking measures  
- coupling strength estimates  
- confidence bounds and uncertainty surfaces  
- provenance-linked summaries referencing inputs by hash  

## 3. Non-Scope (What RGSR Is Not)

RGSR may NOT:

- generate new physics or claim causal mechanisms  
- reinterpret truth-engine outputs as meaning, intent, or attribution  
- access sensors/devices directly (CORE orchestrates all I/O)  
- accept peer-engine direct delivery (CORE-only delivery)  
- publish outside CORE permissions and audit gates  
- include user identity, governance state (roles/tiers/flags), or billing signals in outputs or logs  

## 4. Determinism & Reproducibility (Hard Requirement)

RGSR runs must be reproducible given:

- sealed upstream artifacts  
- sealed inputs + parameters  
- engine version identity  
- canonical JSON rules used by CORE sealing  

Heuristics or probabilistic logic, if present:

- MUST be declared  
- MUST be logged  
- MUST be made deterministic (fixed seed + sealed parameters) so identical sealed inputs yield identical outputs  
- may only execute when CORE authorizes the lane for the run context; RGSR does not evaluate lane eligibility  

## 5. Required Artifacts (Minimum Bundle)

RGSR must emit, at minimum:

- ENGINE_MANIFEST.json  
- RUN_CONDITIONS.json  
- SHA256SUMS.txt  
- ARTIFACT_INDEX.json  
- INPUT_ARTIFACT_INDEX.json (hash-referenced list of all upstream artifacts)  
- COUPLING_REPORT.json (optional but recommended)  
- OUTPUT_SUMMARY.json (correlation-only summary; no attribution)  

All artifacts must be sealable and verifiable.

## 6. Output Semantics (Enforceable)

RGSR outputs MUST:

- explicitly state **CORRELATION_ONLY** semantics  
- label uncertainty when inputs are incomplete  
- reference upstream artifacts by hash  
- include `inputs_hash` and `outputs_hash` for replay verification  
- include an `input_artifact_index` (hash list) for every run  

RGSR must not emit language implying causation, intent, attribution, or operational directives.

## 7. Publishing & Export Rules

Export requires:

- sealed run bundle  
- manifest + schemas included  
- hashes + artifact index included  
- replay verification possible without network access  

## 8. Enforcement (CORE Rejection Rules)

CORE must reject any RGSR output that:

- fails schema validation  
- lacks inputs_hash / outputs_hash  
- lacks input_artifact_index  
- contains forbidden fields (identity/governance/billing)  
- is not reproducible under replay  

## 9. Amendment Rules

Changes require:

- CORE governance review  
- engine repo version bump  
- Git audit trail and registry update
