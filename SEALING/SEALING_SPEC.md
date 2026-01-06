# ENGINE SEALING SPEC (CANONICAL)

## Purpose
RGSR must emit deterministic correlation artifacts that CORE can seal and verify.

## Canonical Output Rules
1. Output MUST be valid UTF-8 JSON.
2. Output MUST be deterministic under identical sealed inputs + parameters + engine version.
3. Output MUST NOT include:
   - user identity
   - governance state (roles, tiers, feature flags)
   - billing/monetization signals
   - causal or attribution claims
4. Output MUST include:
   - run_id
   - engine_code + engine_version
   - inputs_hash (sha256 of canonical input JSON text)
   - outputs_hash (sha256 of canonical output JSON text)
   - input_artifact_index (hash-referenced list of all upstream artifacts)

## Hashing
- Hash algorithm: SHA-256
- Canonicalization: JSON serialized text (CORE defines canonical serializer).
- Engines must not reorder fields nondeterministically.

## What CORE seals
CORE seals:
- ENGINE_MANIFEST.json
- schemas + coupling rules
- upstream artifact hashes
- run input/output payloads
- run metadata

RGSR does not modify sealed artifacts after emission.
