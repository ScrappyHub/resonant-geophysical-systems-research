#requires -Version 7
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "CORE one-shot: remote migrations only (no psql)" -ForegroundColor Cyan

# Ensure this repo is linked to the correct Supabase project
supabase link --project-ref zqhkyovksldzueqsznmd

# Apply any pending migrations to remote
supabase db push

# Show canonical applied list (local vs remote)
supabase migration list

Write-Host "DONE ✅" -ForegroundColor Green
