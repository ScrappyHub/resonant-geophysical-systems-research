# RGSR — Unified Multi-Domain Fusion Engine

RGSR is a **fusion engine** in the CORE engine family.

It computes **correlation, coherence, coupling, and alignment metrics** across outputs produced by other registered engines.  
RGSR must remain **correlation-only** and must not claim new domain truth.

## Invariants (Non-Negotiable)
- Deterministic: ✅
- Headless: ✅
- Network access: ❌
- User-aware: ❌
- Governance-aware: ❌
- Side effects: ❌

## Contract Surface (for CORE)
- `/MANIFEST/ENGINE_MANIFEST.json`
- `/MANIFEST/INPUT_SCHEMA.json`
- `/MANIFEST/OUTPUT_SCHEMA.json`
- `/MANIFEST/COUPLING_RULES.json`
- `/SEALING/SEALING_SPEC.md`
- `/GOVERNANCE/ENGINE_GOVERNANCE.md`

## Notes
RGSR never calls other engines directly. All inputs are mediated by CORE under the engine registry contract.
