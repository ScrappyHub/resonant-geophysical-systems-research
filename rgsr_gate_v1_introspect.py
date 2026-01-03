import os, json, sys, hashlib
from collections import Counter, defaultdict

BOM = "\ufeff"

MEASURE_KEYS = {
  "drive_hz","chamber_f0_hz","stone_f0_hz",
  "em_rms","vib_rms","chamber_rms","peak_em_hz"
}

STRICT_UNIQUE_KEYS = ["material_profile_ids","layer_stack_ids","subsurface_domain_ids"]
GROUP_KEYS = ["experiment_id","sample_id","phase1_experiment_id","phase2_experiment_id"]

def _safe_read_text(path: str) -> str:
  with open(path, "rb") as f:
    b = f.read()
  try:
    s = b.decode("utf-8")
  except UnicodeDecodeError:
    s = b.decode("utf-8", errors="replace")
  if s.startswith(BOM):
    s = s.lstrip(BOM)
  return s

def _load_json(path: str):
  s = _safe_read_text(path)
  return json.loads(s)

def _sha256_bytes(path: str) -> str:
  h = hashlib.sha256()
  with open(path, "rb") as f:
    for chunk in iter(lambda: f.read(1024*1024), b""):
      h.update(chunk)
  return h.hexdigest()

def _walk_json_files(root: str):
  # skip reports + git internals
  skip_dirs = {"_rgsr_reports",".git",".venv","venv","node_modules"}
  for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in skip_dirs]
    for fn in filenames:
      if fn.lower().endswith(".json"):
        yield os.path.join(dirpath, fn)

def _norm_key(k) -> str:
  return "".join(ch for ch in str(k).lower() if ch.isalnum())

def _collect_ids_anywhere(node, where: str, strict_hits, group_hits):
  # strict unique ids: treat string OR list-of-strings as IDs
  if isinstance(node, dict):
    for k, v in node.items():
      nk = _norm_key(k)
      if nk in set(_norm_key(x) for x in STRICT_UNIQUE_KEYS):
        if isinstance(v, str) and v.strip():
          strict_hits[k].append((v.strip(), where))
        elif isinstance(v, list):
          for it in v:
            if isinstance(it, str) and it.strip():
              strict_hits[k].append((it.strip(), where))
      if nk in set(_norm_key(x) for x in GROUP_KEYS):
        if isinstance(v, str) and v.strip():
          group_hits[k].append((v.strip(), where))
      _collect_ids_anywhere(v, where, strict_hits, group_hits)
  elif isinstance(node, list):
    for it in node:
      _collect_ids_anywhere(it, where, strict_hits, group_hits)

def main():
  if len(sys.argv) < 3:
    print("USAGE: python rgsr_gate_v1_introspect.py <Root> <OutDir>")
    return 64

  root = os.path.abspath(sys.argv[1])
  outdir = os.path.abspath(sys.argv[2])
  os.makedirs(outdir, exist_ok=True)

  out_txt = os.path.join(outdir, "rgsr_gate_v1_report.txt")
  out_sum = os.path.join(outdir, "rgsr_gate_v1_summary.json")
  out_col = os.path.join(outdir, "rgsr_gate_v1_collisions.json")

  files_scanned = 0
  failures = []
  top_keys = Counter()

  frames = []
  frame_paths = []   # (file, $.results[i], meas_keys)
  configs_detected = 0
  results_path_nodes_seen = 0

  strict_hits = defaultdict(list)  # key -> [(id, where)]
  group_hits  = defaultdict(list)

  for path in _walk_json_files(root):
    files_scanned += 1
    rel = os.path.relpath(path, root)
    where_file = f"{rel}"

    try:
      obj = _load_json(path)
    except Exception as e:
      failures.append({"file": path, "error": f"{type(e).__name__}: {e}"})
      continue

    # count keys everywhere (for discovery)
    stack = [obj]
    while stack:
      n = stack.pop()
      if isinstance(n, dict):
        for k, v in n.items():
          top_keys[_norm_key(k)] += 1
          stack.append(v)
      elif isinstance(n, list):
        stack.extend(n)

    # IDs anywhere (strict + grouping)
    try:
      _collect_ids_anywhere(obj, where_file, strict_hits, group_hits)
    except Exception:
      pass

    if isinstance(obj, dict):
      # canonical config
      cfg = obj.get("config")
      if isinstance(cfg, dict):
        configs_detected += 1

      # canonical results frames: $.results[*] where each item is a dict containing measure keys
      res = obj.get("results")
      if isinstance(res, list):
        results_path_nodes_seen += 1
        for i, it in enumerate(res):
          if isinstance(it, dict):
            meas = sorted(set(it.keys()) & MEASURE_KEYS)
            if meas:
              frames.append({"file": path, "json_path": f"$.results.[{i}]", "matched_measure_keys": meas})
              frame_paths.append((path, f"$.results.[{i}]", meas))

  # collisions
  def build_collisions(hit_map):
    # hit_map: key -> [(id, where)]
    out = {}
    for k, pairs in hit_map.items():
      byid = defaultdict(list)
      for idv, where in pairs:
        byid[idv].append(where)
      # collisions = ids that appear more than once
      col = {idv: wh for (idv, wh) in byid.items() if len(wh) > 1}
      out[k] = col
    return out

  strict_coll = build_collisions(strict_hits)
  group_coll  = build_collisions(group_hits)

  # normalize TOP_KEYS back to original-looking keys where possible
  # (keep normalized keys; counts still useful and stable)
  top_keys_list = [(k, int(v)) for k, v in top_keys.most_common(80)]

  summary = {
    "files_scanned": files_scanned,
    "results_path_nodes_seen": results_path_nodes_seen,
    "configs_detected": configs_detected,
    "frames_detected": len(frames),
    "candidate_count": len(frames),
    "top_keys": top_keys_list,
    "candidates": frames[:25],
    "failures": failures
  }

  collisions = {
    "strict_unique_id_collisions": {
      "material_profile_ids": strict_coll.get("material_profile_ids", {}),
      "layer_stack_ids": strict_coll.get("layer_stack_ids", {}),
      "subsurface_domain_ids": strict_coll.get("subsurface_domain_ids", {})
    },
    "grouping_id_collisions": {
      "experiment_id": group_coll.get("experiment_id", {}),
      "sample_id": group_coll.get("sample_id", {}),
      "phase1_experiment_id": group_coll.get("phase1_experiment_id", {}),
      "phase2_experiment_id": group_coll.get("phase2_experiment_id", {})
    }
  }

  lines = []
  lines.append(f"FILES_SCANNED: {files_scanned}")
  lines.append(f"RESULTS_PATH_NODES_SEEN: {results_path_nodes_seen}")
  lines.append(f"FRAMES_DETECTED: {len(frames)}")
  lines.append(f"CONFIGS_DETECTED: {configs_detected}")
  lines.append(f"FAILURES: {len(failures)}")
  lines.append("")
  lines.append("TOP_KEYS (first 40):")
  for k, v in top_keys_list[:40]:
    lines.append(f"  {v:6d}  {k}")
  lines.append("")
  lines.append("FRAME_PATHS (first 20):")
  for j, (fp, jp, meas) in enumerate(frame_paths[:20]):
    lines.append(f"  [{j}] file={fp} path={jp} meas={meas}")
  lines.append("")
  lines.append("STRICT_UNIQUE_ID_COLLISIONS (should be 0 unless bad):")
  for k in ["material_profile_ids","layer_stack_ids","subsurface_domain_ids"]:
    lines.append(f"  {k}: {len(collisions['strict_unique_id_collisions'].get(k,{}))} collisions")
  lines.append("")
  lines.append("GROUPING_ID_COLLISIONS (expected, informational only):")
  for k in ["experiment_id","sample_id","phase1_experiment_id","phase2_experiment_id"]:
    lines.append(f"  {k}: {len(collisions['grouping_id_collisions'].get(k,{}))} collisions")

  with open(out_txt, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(lines))
  with open(out_sum, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)
  with open(out_col, "w", encoding="utf-8") as f:
    json.dump(collisions, f, indent=2)

  print(out_txt)
  print(out_sum)
  print(out_col)
  return 0

if __name__ == "__main__":
  raise SystemExit(main())
