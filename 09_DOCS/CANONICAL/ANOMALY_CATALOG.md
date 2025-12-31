# Anomaly Catalog (PPN)

## Missing output
- Likely: RAW/PROCESSED missing, bad path, upstream script failure.
- Check: existence gate, processed sweep path, python/tool exit codes.

## Flat deltas
- Likely: comparing same dataset, join mismatch, constant columns.
- Check: AB_inputs_pointer.txt, sweep row counts, drive_hz overlap.

## In-band empty
- Likely: band limits do not overlap drive_hz, filter window wrong.
- Check: configured band vs drive_hz min/max.
