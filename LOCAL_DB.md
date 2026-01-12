\# LOCAL DB (CORE/RGSR) — Canonical workflow



\## One command (always)



\*\*Canonical local reset + auth lockdown:\*\*



```powershell

pwsh -NoProfile -ExecutionPolicy Bypass -File .\\tools\\local\\reset\_and\_lock\_auth.ps1 -DbPassword "postgres"



