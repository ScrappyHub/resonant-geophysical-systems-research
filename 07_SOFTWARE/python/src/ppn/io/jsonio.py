from __future__ import annotations
from pathlib import Path
import json

def write_json(path: str | Path, obj: dict) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj, indent=2), encoding="utf-8")

def read_json(path: str | Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))