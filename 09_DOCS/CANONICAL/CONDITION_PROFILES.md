# RGSR Condition Profiles (V1.1)

**Status:** LOCKED
Profiles live in: `conditions/profiles/*.json`
Schema: `conditions/schema/condition_profile.schema.json` (ID: RGSR_CONDITION_PROFILE_V1_1)

## Rules
- Profiles are immutable templates. If conditions change, create a new profile.
- Runs reference a profile by name (ConditionProfile) or by explicit file path (ConditionsPath).
- If -RequireConditions is used, the required fields must exist.

## Environmental fields
- temp_c, humidity_rh, pressure_kpa
- season (spring|summer|autumn|winter)
- weather (dry|rain|snow|fog|windy|storm)

## Thermal sub-domain (recommended)
- thermal.ambient_temp_c
- thermal.internal_air_temp_c
- thermal.water_temp_c
- thermal.inlet_water_temp_c
- thermal.surface_temp_c

These fields are provenance-only. They do not assert physics effects; they enable reproducible comparison.
