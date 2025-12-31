# Canonical Commands (PPN)

## A/B Packet Builder (single P2)
pwsh -NoProfile -ExecutionPolicy Bypass -File "08_AUTOMATION\powershell\ppn_ab_packet.ps1" -P2 "PPN-P2-0002"

## One-Shot (auto-discover all P2 RAW)
pwsh -NoProfile -ExecutionPolicy Bypass -File "08_AUTOMATION\powershell\ppn_ab_one_shot.ps1"

## One-Shot (Only list)
pwsh -NoProfile -ExecutionPolicy Bypass -File "08_AUTOMATION\powershell\ppn_ab_one_shot.ps1" -Only "PPN-P2-0002","PPN-P2-0001"

## Golden rules
- RAW presence is the existence gate.
- Do not hand-edit generated packets; regenerate.
