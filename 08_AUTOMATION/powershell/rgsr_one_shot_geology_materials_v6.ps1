param(
  [Parameter(Mandatory)][string]$RepoRoot,
  [switch]$LinkProject,
  [string]$ProjectRef = "",
  [switch]$ApplyRemote
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p) { if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }

function WriteUtf8NoBom([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if ($dir) { EnsureDir $dir }
  [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
  Write-Host ("[OK] WROTE " + $Path) -ForegroundColor DarkGreen
}

if (-not (Test-Path -LiteralPath $RepoRoot)) { throw "RepoRoot not found: $RepoRoot" }
Set-Location $RepoRoot

$mgDir = Join-Path $RepoRoot "supabase\migrations"
EnsureDir $mgDir

Write-Host ("[INFO] RepoRoot=" + $RepoRoot) -ForegroundColor Gray
Write-Host ("[INFO] mgDir=" + $mgDir) -ForegroundColor Gray

$MigrationId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$mgPath = Join-Path $mgDir ("{0}_rgsr_geology_and_materials_model_v1.sql" -f $MigrationId)

$sql = @"
-- ============================================================
-- RGSR: Canonical Geology & Materials Model (PHYSICS-FIRST)
-- - Materials must have required physical properties (no cosmetics)
-- - Layer stacks for chambers/structures
-- - Water-stone interaction modeling
-- - Subsurface domains (aquifers/voids/fractures/etc)
-- - Geometry<->Geology coupling via attachable references
-- ============================================================

begin;

-- ---------------------------
-- 0) Core enums (text + CHECK to stay portable)
-- ---------------------------

create table if not exists rgsr.material_profiles (
  material_id uuid primary key default gen_random_uuid(),

  -- Not meaning-bearing, just an identifier label for humans
  material_code text not null unique,              -- e.g., GRANITE_A, LIMESTONE_CORE, COPPER_C110
  display_name text not null,                      -- e.g., "Granite (sample A)"
  classification text not null default 'STONE',    -- STONE|METAL|CLAY|CONCRETE|SALT|COMPOSITE|OTHER

  -- REQUIRED PHYSICAL PROPERTIES (NON-NEGOTIABLE)
  density_kg_m3 numeric not null,
  youngs_modulus_pa numeric not null,
  poissons_ratio numeric not null,
  acoustic_impedance_rayl numeric not null,
  porosity_frac numeric not null,
  moisture_content_frac numeric not null,
  grain_structure text not null,       -- categorical description (not a name claim; scattering descriptor)
  crystalline_order text not null,     -- categorical descriptor
  electrical_conductivity_s_m numeric not null,
  thermal_conductivity_w_mk numeric not null,

  -- REACTIVE / EM / THERMAL EXTENSIONS (required for conductive/reactive families)
  dielectric_constant_rel numeric not null,
  piezoelectric_potential_index numeric not null,  -- normalized index (0..1) unless you later adopt d33 etc
  thermal_inertia_j_m2_k_s05 numeric not null,      -- common form of thermal inertia (J m^-2 K^-1 s^-1/2)

  -- Optional notes / provenance (sample source, lab calibration refs)
  provenance jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint material_profiles_classification_chk
    check (classification in ('STONE','METAL','CLAY','CONCRETE','SALT','COMPOSITE','OTHER')),

  constraint material_profiles_density_chk
    check (density_kg_m3 > 0),

  constraint material_profiles_youngs_chk
    check (youngs_modulus_pa > 0),

  constraint material_profiles_poisson_chk
    check (poissons_ratio >= 0 and poissons_ratio < 0.5),

  constraint material_profiles_impedance_chk
    check (acoustic_impedance_rayl > 0),

  constraint material_profiles_porosity_chk
    check (porosity_frac >= 0 and porosity_frac <= 1),

  constraint material_profiles_moisture_chk
    check (moisture_content_frac >= 0 and moisture_content_frac <= 1),

  constraint material_profiles_sigma_chk
    check (electrical_conductivity_s_m >= 0),

  constraint material_profiles_k_chk
    check (thermal_conductivity_w_mk > 0),

  constraint material_profiles_eps_chk
    check (dielectric_constant_rel > 0),

  constraint material_profiles_piezo_chk
    check (piezoelectric_potential_index >= 0 and piezoelectric_potential_index <= 1),

  constraint material_profiles_thermin_chk
    check (thermal_inertia_j_m2_k_s05 > 0)
);

create index if not exists ix_material_profiles_class on rgsr.material_profiles(classification);
create index if not exists ix_material_profiles_code on rgsr.material_profiles(material_code);

-- ---------------------------
-- 1) Geological structures: the “thing” that can have a layer stack
--    (pyramid casing, chamber wall, shaft lining, substrate block, etc)
-- ---------------------------
create table if not exists rgsr.geology_structures (
  structure_id uuid primary key default gen_random_uuid(),

  lane text not null default 'PUBLIC',       -- PUBLIC|LAB|INTERNAL
  lab_id uuid null,

  structure_type text not null,             -- CHAMBER|WALL|SHAFT|CASING|SUBSTRATE|FOUNDATION|OTHER
  name text not null,
  description text,

  -- Optional attachment hooks (filled if your geometry system exists)
  -- These are generic references; we may add FK constraints via introspection below.
  geometry_element_id uuid null,
  geometry_profile_id uuid null,

  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint geology_structures_lane_chk
    check (lane in ('PUBLIC','LAB','INTERNAL')),

  constraint geology_structures_type_chk
    check (structure_type in ('CHAMBER','WALL','SHAFT','CASING','SUBSTRATE','FOUNDATION','OTHER'))
);

create index if not exists ix_geology_structures_lane on rgsr.geology_structures(lane);
create index if not exists ix_geology_structures_lab on rgsr.geology_structures(lab_id);
create index if not exists ix_geology_structures_geom_el on rgsr.geology_structures(geometry_element_id);
create index if not exists ix_geology_structures_geom_prof on rgsr.geology_structures(geometry_profile_id);

-- ---------------------------
-- 2) Geological layering: ordered layer stack per structure
--    Each layer references a Material Profile (required).
-- ---------------------------
create table if not exists rgsr.geology_layers (
  layer_id uuid primary key default gen_random_uuid(),
  structure_id uuid not null references rgsr.geology_structures(structure_id) on delete cascade,

  layer_order integer not null,          -- 1..N (outer -> inner or top -> bottom; you define convention per structure)
  layer_role text not null,              -- SURFACE|STRUCTURAL|INNER|SUBSTRATE|BELOW|OTHER

  material_id uuid not null references rgsr.material_profiles(material_id) on delete restrict,

  thickness_m numeric not null,
  contact_impedance_rayl numeric not null,      -- interface impedance estimate
  moisture_frac numeric not null,
  thermal_gradient_c_per_m numeric not null,
  electrical_coupling_index numeric not null,   -- 0..1 coupling potential across interface

  notes text,
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint geology_layers_order_chk check (layer_order >= 1),
  constraint geology_layers_role_chk check (layer_role in ('SURFACE','STRUCTURAL','INNER','SUBSTRATE','BELOW','OTHER')),
  constraint geology_layers_thickness_chk check (thickness_m > 0),
  constraint geology_layers_contact_imp_chk check (contact_impedance_rayl > 0),
  constraint geology_layers_moisture_chk check (moisture_frac >= 0 and moisture_frac <= 1),
  constraint geology_layers_ecoup_chk check (electrical_coupling_index >= 0 and electrical_coupling_index <= 1)
);

create unique index if not exists uq_geology_layers_structure_order
  on rgsr.geology_layers(structure_id, layer_order);

create index if not exists ix_geology_layers_structure on rgsr.geology_layers(structure_id);
create index if not exists ix_geology_layers_material on rgsr.geology_layers(material_id);

-- ---------------------------
-- 3) Water–stone interaction model
--    Water is not separate; it modifies geology behavior.
-- ---------------------------
create table if not exists rgsr.water_stone_interactions (
  interaction_id uuid primary key default gen_random_uuid(),

  structure_id uuid not null references rgsr.geology_structures(structure_id) on delete cascade,
  layer_id uuid null references rgsr.geology_layers(layer_id) on delete cascade,

  -- Absorption / flow / wetting
  absorption_frac numeric not null,          -- 0..1
  capillary_flow_index numeric not null,     -- 0..1 (proxy until you adopt permeability)
  surface_wetting_index numeric not null,    -- 0..1

  -- Dissolved minerals & conductivity changes
  dissolved_mineral_ppm numeric not null,    -- >=0
  conductivity_delta_s_m numeric not null,   -- signed change in S/m due to wetting/minerals

  -- Temperature coupling
  temp_coupling_index numeric not null,      -- 0..1

  notes text,
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint wsi_abs_chk check (absorption_frac >= 0 and absorption_frac <= 1),
  constraint wsi_cap_chk check (capillary_flow_index >= 0 and capillary_flow_index <= 1),
  constraint wsi_wet_chk check (surface_wetting_index >= 0 and surface_wetting_index <= 1),
  constraint wsi_ppm_chk check (dissolved_mineral_ppm >= 0),
  constraint wsi_tc_chk check (temp_coupling_index >= 0 and temp_coupling_index <= 1)
);

create index if not exists ix_wsi_structure on rgsr.water_stone_interactions(structure_id);
create index if not exists ix_wsi_layer on rgsr.water_stone_interactions(layer_id);

-- ---------------------------
-- 4) Subsurface domains (below-chamber geology)
-- ---------------------------
create table if not exists rgsr.subsurface_features (
  feature_id uuid primary key default gen_random_uuid(),

  lane text not null default 'PUBLIC',
  lab_id uuid null,

  feature_type text not null,              -- AQUIFER|BEDROCK|VOID|FRACTURE|WATER_TABLE|CONDUCTIVE_LAYER|OTHER
  name text not null,
  description text,

  -- Relationship to a structure (optional)
  structure_id uuid null references rgsr.geology_structures(structure_id) on delete set null,

  depth_top_m numeric null,
  depth_bottom_m numeric null,
  thickness_m numeric null,

  -- Conductivity & coupling to the system
  electrical_conductivity_s_m numeric not null default 0,
  coupling_index numeric not null default 0,         -- 0..1
  water_bearing boolean not null default false,

  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint subsurface_lane_chk check (lane in ('PUBLIC','LAB','INTERNAL')),
  constraint subsurface_type_chk check (feature_type in ('AQUIFER','BEDROCK','VOID','FRACTURE','WATER_TABLE','CONDUCTIVE_LAYER','OTHER')),
  constraint subsurface_sigma_chk check (electrical_conductivity_s_m >= 0),
  constraint subsurface_coup_chk check (coupling_index >= 0 and coupling_index <= 1),
  constraint subsurface_depth_chk check (
    (depth_top_m is null and depth_bottom_m is null) or
    (depth_top_m is not null and depth_bottom_m is not null and depth_bottom_m >= depth_top_m)
  )
);

create index if not exists ix_subsurface_type on rgsr.subsurface_features(feature_type);
create index if not exists ix_subsurface_structure on rgsr.subsurface_features(structure_id);

-- ---------------------------
-- 5) Geometry–Geology coupling
--    Generic mapping table so geometry elements know:
--      - what material
--      - what it touches
--      - what lies behind/below
-- ---------------------------
create table if not exists rgsr.geometry_geology_couplings (
  coupling_id uuid primary key default gen_random_uuid(),

  -- If you have geometry elements/profiles, you can populate these.
  geometry_element_id uuid null,
  geometry_profile_id uuid null,

  -- The geology structure that represents the physical medium
  structure_id uuid not null references rgsr.geology_structures(structure_id) on delete cascade,

  -- Coupling descriptors
  touches_structure_id uuid null references rgsr.geology_structures(structure_id) on delete set null,
  behind_structure_id uuid null references rgsr.geology_structures(structure_id) on delete set null,
  below_feature_id uuid null references rgsr.subsurface_features(feature_id) on delete set null,

  coupling_impedance_rayl numeric not null default 1,
  coupling_index numeric not null default 0, -- 0..1

  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint ggc_imp_chk check (coupling_impedance_rayl > 0),
  constraint ggc_coup_chk check (coupling_index >= 0 and coupling_index <= 1)
);

create index if not exists ix_ggc_structure on rgsr.geometry_geology_couplings(structure_id);
create index if not exists ix_ggc_geom_el on rgsr.geometry_geology_couplings(geometry_element_id);
create index if not exists ix_ggc_geom_prof on rgsr.geometry_geology_couplings(geometry_profile_id);

-- ---------------------------
-- 6) Optional: attach FKs to existing geometry tables if they exist
--    (No assumptions; introspection only.)
-- ---------------------------
do \$do\$
begin
  -- Try to bind geology_structures.geometry_profile_id -> rgsr.geometry_profiles(geometry_profile_id)
  if exists (
    select 1 from information_schema.tables
    where table_schema='rgsr' and table_name='geometry_profiles'
  ) and exists (
    select 1 from information_schema.columns
    where table_schema='rgsr' and table_name='geometry_profiles' and column_name='geometry_profile_id'
  ) then
    begin
      execute 'alter table rgsr.geology_structures
               add constraint fk_geol_struct_geom_profile
               foreign key (geometry_profile_id)
               references rgsr.geometry_profiles(geometry_profile_id)
               on delete set null';
    exception when duplicate_object then
      null;
    end;
  end if;

  -- Try to bind geology_structures.geometry_element_id -> rgsr.geometry_elements(geometry_element_id)
  if exists (
    select 1 from information_schema.tables
    where table_schema='rgsr' and table_name='geometry_elements'
  ) and exists (
    select 1 from information_schema.columns
    where table_schema='rgsr' and table_name='geometry_elements' and column_name='geometry_element_id'
  ) then
    begin
      execute 'alter table rgsr.geology_structures
               add constraint fk_geol_struct_geom_element
               foreign key (geometry_element_id)
               references rgsr.geometry_elements(geometry_element_id)
               on delete set null';
    exception when duplicate_object then
      null;
    end;
  end if;
end
\$do\$;

-- ---------------------------
-- 7) RLS defaults (safe by default)
--    You can harden with lab-capabilities later.
-- ---------------------------
alter table rgsr.material_profiles enable row level security;
alter table rgsr.geology_structures enable row level security;
alter table rgsr.geology_layers enable row level security;
alter table rgsr.water_stone_interactions enable row level security;
alter table rgsr.subsurface_features enable row level security;
alter table rgsr.geometry_geology_couplings enable row level security;

-- Minimal read access for authenticated; write restricted to sys_admin/service_role.
-- (We keep this conservative to avoid ungoverned state mutation.)
create or replace function rgsr.is_sys_admin()
returns boolean
language sql stable as \$sql\$
  select coalesce((select (auth.jwt() -> 'app_metadata' ->> 'role') = 'sys_admin'), false);
\$sql\$;

create or replace function rgsr.is_service_role()
returns boolean
language sql stable as \$sql\$
  select coalesce((select (auth.jwt() ->> 'role') = 'service_role'), false);
\$sql\$;

-- MATERIALS
drop policy if exists mp_select on rgsr.material_profiles;
create policy mp_select on rgsr.material_profiles for select to authenticated
using (true);

drop policy if exists mp_write on rgsr.material_profiles;
create policy mp_write on rgsr.material_profiles for insert to authenticated
with check (rgsr.is_sys_admin() or rgsr.is_service_role());

drop policy if exists mp_update on rgsr.material_profiles;
create policy mp_update on rgsr.material_profiles for update to authenticated
using (rgsr.is_sys_admin() or rgsr.is_service_role())
with check (rgsr.is_sys_admin() or rgsr.is_service_role());

-- STRUCTURES / LAYERS / INTERACTIONS / SUBSURFACE / COUPLINGS
drop policy if exists gs_select on rgsr.geology_structures;
create policy gs_select on rgsr.geology_structures for select to authenticated using (true);
drop policy if exists gs_write on rgsr.geology_structures;
create policy gs_write on rgsr.geology_structures for insert to authenticated
with check (rgsr.is_sys_admin() or rgsr.is_service_role());
drop policy if exists gs_update on rgsr.geology_structures;
create policy gs_update on rgsr.geology_structures for update to authenticated
using (rgsr.is_sys_admin() or rgsr.is_service_role())
with check (rgsr.is_sys_admin() or rgsr.is_service_role());

drop policy if exists gl_select on rgsr.geology_layers;
create policy gl_select on rgsr.geology_layers for select to authenticated using (true);
drop policy if exists gl_write on rgsr.geology_layers;
create policy gl_write on rgsr.geology_layers for insert to authenticated
with check (rgsr.is_sys_admin() or rgsr.is_service_role());
drop policy if exists gl_update on rgsr.geology_layers;
create policy gl_update on rgsr.geology_layers for update to authenticated
using (rgsr.is_sys_admin() or rgsr.is_service_role())
with check (rgsr.is_sys_admin() or rgsr.is_service_role());

drop policy if exists wsi_select on rgsr.water_stone_interactions;
create policy wsi_select on rgsr.water_stone_interactions for select to authenticated using (true);
drop policy if exists wsi_write on rgsr.water_stone_interactions;
create policy wsi_write on rgsr.water_stone_interactions for insert to authenticated
with check (rgsr.is_sys_admin() or rgsr.is_service_role());
drop policy if exists wsi_update on rgsr.water_stone_interactions;
create policy wsi_update on rgsr.water_stone_interactions for update to authenticated
using (rgsr.is_sys_admin() or rgsr.is_service_role())
with check (rgsr.is_sys_admin() or rgsr.is_service_role());

drop policy if exists ss_select on rgsr.subsurface_features;
create policy ss_select on rgsr.subsurface_features for select to authenticated using (true);
drop policy if exists ss_write on rgsr.subsurface_features;
create policy ss_write on rgsr.subsurface_features for insert to authenticated
with check (rgsr.is_sys_admin() or rgsr.is_service_role());
drop policy if exists ss_update on rgsr.subsurface_features;
create policy ss_update on rgsr.subsurface_features for update to authenticated
using (rgsr.is_sys_admin() or rgsr.is_service_role())
with check (rgsr.is_sys_admin() or rgsr.is_service_role());

drop policy if exists ggc_select on rgsr.geometry_geology_couplings;
create policy ggc_select on rgsr.geometry_geology_couplings for select to authenticated using (true);
drop policy if exists ggc_write on rgsr.geometry_geology_couplings;
create policy ggc_write on rgsr.geometry_geology_couplings for insert to authenticated
with check (rgsr.is_sys_admin() or rgsr.is_service_role());
drop policy if exists ggc_update on rgsr.geometry_geology_couplings;
create policy ggc_update on rgsr.geometry_geology_couplings for update to authenticated
using (rgsr.is_sys_admin() or rgsr.is_service_role())
with check (rgsr.is_sys_admin() or rgsr.is_service_role());

commit;

-- ============================================================
-- End migration
-- ============================================================
"@

WriteUtf8NoBom $mgPath ($sql + "`r`n")
Write-Host ("[OK] NEW MIGRATION READY: " + $mgPath) -ForegroundColor Green

if ($LinkProject) {
  if (-not $ProjectRef) { throw "ProjectRef is required for link." }
  & supabase link --project-ref $ProjectRef
  Write-Host "[OK] supabase link complete" -ForegroundColor Green
}

if ($ApplyRemote) {
  cmd /c "echo y| supabase db push"
  Write-Host "[OK] supabase db push complete" -ForegroundColor Green
}

Write-Host "✅ ONE-SHOT PIPELINE COMPLETE (v6 geology/materials)" -ForegroundColor Green