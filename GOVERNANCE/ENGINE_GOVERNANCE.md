## RGSR CORRELATION-ONLY ENFORCEMENT (CANONICAL)

RGSR is a fusion and correlation engine.

RGSR:
- MUST prohibit causal or attribution language.
- MUST emit outputs with semantics = CORRELATION_ONLY.
- MUST NOT generate new physics or override upstream engine truth.
- MUST NOT privilege one upstream engine as authoritative over others.

RGSR MUST include a hash-referenced upstream artifact list:
- input_artifact_index field in OUTPUT_SCHEMA.json outputs, and/or
- INPUT_ARTIFACT_INDEX.json as part of the sealed run bundle.

All correlations MUST reference upstream artifacts by SHA-256 hash.
Correlation does not imply causation.
