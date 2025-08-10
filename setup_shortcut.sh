#!/usr/bin/env bash
set -euo pipefail

# setup_shortcut.sh
# One-command setup for BeeAI ⇄ Shortcut bootstrap
#
# Usage:
#   ./setup_shortcut.sh [--bootstrap | --dry-run] [--token YOUR_TOKEN] [--dir PATH]
# Defaults:
#   mode: --dry-run
#   dir:  ./beeai-shortcut

MODE="dry-run"
TARGET_DIR="./beeai-shortcut"
TOKEN="${SHORTCUT_TOKEN:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap) MODE="bootstrap"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --dir) TARGET_DIR="${2:-}"; shift 2 ;;
    -h|--help)
      grep -E '^(# |Usage:|Defaults:)' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

# Write files if missing
write_if_missing() {
  local path="$1"
  shift
  if [[ -f "$path" ]]; then
    echo "[skip] $path exists"
  else
    echo "[write] $path"
    cat > "$path" <<'EOF'
$CONTENTS$
EOF
  fi
}

# Inject file contents
python3 - "$@" <<'PYEOF'
import os, sys
from pathlib import Path

client = r'''
# shortcut_client.py
import argparse
import os
import sys
import time
from datetime import datetime, timedelta
from typing import Optional, List, Dict, Tuple

import requests
import yaml
from dateutil import tz

API_BASE = os.environ.get("SHORTCUT_API_BASE", "https://api.app.shortcut.com/api/v3")

def _hdrs():
    tok = os.environ.get("SHORTCUT_TOKEN")
    if not tok:
        print("ERROR: SHORTCUT_TOKEN env var is required.", file=sys.stderr)
        sys.exit(2)
    return {"Shortcut-Token": tok, "Content-Type": "application/json"}

def _req(method: str, path: str, payload: Optional[dict]=None, retry:int=5) -> requests.Response:
    url = f"{API_BASE}{path}"
    for attempt in range(1, retry+1):
        resp = requests.request(method, url, headers=_hdrs(), json=payload, timeout=30)
        if resp.status_code in (429, 500, 502, 503, 504):
            time.sleep(min(2 ** (attempt-1) * 0.5, 8.0))
            continue
        return resp
    return resp

def _die(resp: requests.Response, context:str):
    try:
        body = resp.json()
    except Exception:
        body = resp.text
    print(f"ERROR during {context}: HTTP {resp.status_code} {body}", file=sys.stderr)
    sys.exit(2)

def _iso_week_dates(tzname: str, iteration_length_days: int) -> Tuple[str,str]:
    now = datetime.now(tz.gettz(tzname))
    monday = now - timedelta(days=now.weekday())
    start = datetime(monday.year, monday.month, monday.day, tzinfo=now.tzinfo)
    end = start + timedelta(days=iteration_length_days-1)
    return start.date().isoformat(), end.date().isoformat()

def _list(path: str) -> List[dict]:
    r = _req("GET", path)
    if r.status_code != 200: _die(r, f"list {path}")
    return r.json()

def _find_by_external_id(path: str, external_id: str) -> Optional[dict]:
    for item in _list(path):
        if item.get("external_id") == external_id:
            return item
    return None

def _create(path: str, payload: dict, context: str) -> dict:
    r = _req("POST", path, payload)
    if r.status_code not in (200,201): _die(r, f"create {context}")
    return r.json()

def _update(path: str, payload: dict, context: str) -> dict:
    r = _req("PUT", path, payload)
    if r.status_code != 200: _die(r, f"update {context}")
    return r.json()

def upsert_project(p: dict) -> dict:
    found = _find_by_external_id("/projects", p["external_id"])
    if found: return found
    return _create("/projects", {"name": p["name"], "description": p.get("description",""), "external_id": p["external_id"]}, "project")

def upsert_milestone(m: dict) -> dict:
    found = _find_by_external_id("/milestones", m["external_id"])
    payload = {"name": m["name"], "description": m.get("description",""), "state": m.get("state","to_do"), "external_id": m["external_id"]}
    if found: return _update(f"/milestones/{found['id']}", payload, "milestone")
    return _create("/milestones", payload, "milestone")

def upsert_epic(e: dict, milestone_id: int) -> dict:
    found = _find_by_external_id("/epics", e["external_id"])
    payload = {"name": e["name"], "description": e.get("description",""), "milestone_id": milestone_id, "labels": e.get("labels", []), "external_id": e["external_id"]}
    if found: return _update(f"/epics/{found['id']}", payload, "epic")
    return _create("/epics", payload, "epic")

def upsert_iteration(i: dict) -> dict:
    found = _find_by_external_id("/iterations", i["external_id"])
    payload = {"name": i["name"], "start_date": i.get("start_date"), "end_date": i.get("end_date"), "external_id": i["external_id"]}
    payload = {k:v for k,v in payload.items() if v}
    if found: return _update(f"/iterations/{found['id']}", payload, "iteration")
    return _create("/iterations", payload, "iteration")

def upsert_story(s: dict) -> dict:
    found = _find_by_external_id("/stories", s["external_id"])
    if found:
        return _update(f"/stories/{found['id']}", s, "story")
    return _create("/stories", s, "story")

def create_task(t: dict) -> dict:
    return _create("/tasks", t, "task")

def bootstrap(cfg: dict, dry_run: bool=False):
    # Projects
    name_to_project: Dict[str, dict] = {}
    for p in cfg.get("projects", []):
        if dry_run:
            print(f"[dry-run] project: {p['name']}")
            name_to_project[p["name"]] = {"id": 0}
        else:
            proj = upsert_project(p)
            name_to_project[p["name"]] = proj
            print(f"[ok] project: {proj['name']} id={proj['id']}")

    # Milestone
    ms_cfg = cfg["milestone"]
    milestone = {"id": 0} if dry_run else upsert_milestone(ms_cfg)
    print(f"[ok] milestone: {ms_cfg['name']} id={milestone.get('id',0)}")

    # Epics
    name_to_epic: Dict[str, dict] = {}
    for e in cfg.get("epics", []):
        ep = {"id": 0} if dry_run else upsert_epic(e, milestone_id=milestone.get("id"))
        print(f"[ok] epic: {e['name']} id={ep.get('id',0)}")
        name_to_epic[e["name"]] = ep

    # Iteration: compute dates if blank
    it_cfg = cfg.get("iteration", {})
    iteration = None
    if it_cfg:
        start = it_cfg.get("start_date")
        end = it_cfg.get("end_date")
        if not start or not end:
            tzname = cfg.get("org", {}).get("timezone", "UTC")
            days = int(cfg.get("org", {}).get("iteration_length_days", 7))
            start, end = _iso_week_dates(tzname, days)
        it_payload = {"name": it_cfg["name"], "start_date": start, "end_date": end, "external_id": it_cfg["external_id"]}
        iteration = {"id": 0} if dry_run else upsert_iteration(it_payload)
        print(f"[ok] iteration: {it_payload['name']} {start}..{end} id={iteration.get('id',0)}")

    # Stories + Tasks
    for s in cfg.get("stories", []):
        proj = name_to_project.get(s["project"])
        epic = name_to_epic.get(s["epic"])
        if not proj or not epic:
            print(f"ERROR: Missing project or epic for story '{s['name']}'", file=sys.stderr)
            sys.exit(2)
        story_payload = {
            "name": s["name"],
            "description": s.get("description",""),
            "story_type": s.get("story_type","feature"),
            "project_id": proj["id"],
            "epic_id": epic["id"],
            "estimate": s.get("estimate", 1),
            "labels": s.get("labels", []),
            "external_id": s["external_id"]
        }
        if iteration:
            story_payload["iteration_id"] = iteration["id"]

        if dry_run:
            story = {"id": 0}
            print(f"[dry-run] story: {s['name']}")
        else:
            story = upsert_story(story_payload)
            print(f"[ok] story: {story['name']} id={story['id']}")

        for idx, t in enumerate(s.get("tasks", []), start=1):
            task_payload = {"description": t, "story_id": story["id"], "external_id": f"beeai:task:{s['external_id']}:{idx}"}
            if dry_run:
                print(f"[dry-run]   task: {t}")
            else:
                task = create_task(task_payload)
                print(f"[ok]   task id={task['id']} - {t}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("command", choices=["bootstrap","dry-run"])
    args = ap.parse_args()
    with open(args.config, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    bootstrap(cfg, dry_run=(args.command=="dry-run"))

if __name__ == "__main__":
    main()
'''
yamlc  = r'''
# beeai_shortcut_config.yaml
org:
  timezone: "America/Chicago"
  iteration_length_days: 7

projects:
  - name: "Data Pipeline"
    description: "ETL/ELT pipeline work"
    external_id: "beeai:project:data-pipeline"
  - name: "Modeling"
    description: "ML modeling, training, evaluation"
    external_id: "beeai:project:modeling"
  - name: "Dashboards"
    description: "BI dashboards and UX"
    external_id: "beeai:project:dashboards"
  - name: "Platform"
    description: "Infra, tooling, registries, observability"
    external_id: "beeai:project:platform"
  - name: "QA/Validation"
    description: "Testing, validation, governance"
    external_id: "beeai:project:qa-validation"

labels:
  area: ["pipeline","model","viz","platform","qa","ops"]
  comp: ["ingest","transform","feature-store","training","eval","serving","dash"]
  risk: ["high","medium","low"]
  owner: ["po","tl","ds1","ds2","mle","de","sdet"]
  data: ["pii","pci","public","confidential"]
  ml: ["offline","batch","realtime","ab-test"]
  infra: ["duckdb","postgres","minio","dbt","spark","great-expectations","fastapi"]
  lifecycle: ["backlog","ready","progress","review","blocked","done"]

workflow_states:
  - "Backlog"
  - "Ready"
  - "In Progress"
  - "In Review"
  - "Blocked"
  - "Done"

milestone:
  name: "M01: MVP"
  description: "MVP delivering ingestion→model→dashboards"
  state: "to_do"
  external_id: "beeai:milestone:m01-mvp"

epics:
  - name: "E01: Data Pipeline"
    description: "Source→Bronze→Silver; contracts & quality gates"
    labels: ["area:pipeline","comp:ingest","owner:de","risk:medium"]
    external_id: "beeai:epic:m01-mvp:e01-data-pipeline"
  - name: "E02: Model Training & MLOps"
    description: "Training, eval, registry, release process"
    labels: ["area:model","comp:training","owner:ds1","risk:medium"]
    external_id: "beeai:epic:m01-mvp:e02-model-training-mlops"
  - name: "E03: Evaluation & Monitoring"
    description: "Metrics, drift, alerting, dashboards"
    labels: ["area:model","comp:eval","owner:mle","risk:medium"]
    external_id: "beeai:epic:m01-mvp:e03-eval-monitoring"
  - name: "E04: Dashboard v1"
    description: "Stakeholder KPIs and model insights"
    labels: ["area:viz","comp:dash","owner:ds2","risk:low"]
    external_id: "beeai:epic:m01-mvp:e04-dashboard-v1"

iteration:
  name: "S2025W33: Data Quality"
  start_date: ""
  end_date: ""
  external_id: "beeai:iteration:2025w33"

stories:
  - name: "[Feature] Load raw_transactions to Bronze — schema & null checks"
    description: |
      AC:
      - Create source→bronze mapping (YAML)
      - Implement reader (chunked), write parquet (lz4, partition by txn_date)
      - Great Expectations: 95% column coverage; null rate alerts > threshold
      - Emit row counts & lag metrics to observability
      DoR: Spec + source schema attached
      DoD: PR merged; tests ≥ 80%; dashboard freshness tile updated
    story_type: "feature"
    project: "Data Pipeline"
    epic: "E01: Data Pipeline"
    estimate: 2
    labels: ["area:pipeline","comp:ingest","owner:de","lifecycle:ready"]
    external_id: "beeai:story:m01-mvp:e01-data-pipeline:load-raw-transactions"
    tasks:
      - "Create source-to-bronze mapping YAML"
      - "Implement chunked reader; write lz4 parquet partitioned by txn_date"
      - "Author GE suite; add CI step"
      - "Emit row counts & lag metrics"
  - name: "[Feature] Train XGBoost v0.1 — baseline"
    description: |
      AC:
      - Feature view spec; split strategy; seed fixed
      - Metrics: AUROC, AUPRC, KS; report saved to artifacts
      - Model + params logged to registry; reproducible run script
      DoR: Clean feature set; target leakage check documented
      DoD: PR merged; model card published; evaluation dashboard refreshed
    story_type: "feature"
    project: "Modeling"
    epic: "E02: Model Training & MLOps"
    estimate: 3
    labels: ["area:model","comp:training","owner:ds1","lifecycle:ready"]
    external_id: "beeai:story:m01-mvp:e02-model-training-mlops:train-xgboost-v0-1"
    tasks:
      - "Define feature view & split strategy"
      - "Train baseline; log metrics (AUROC, AUPRC, KS)"
      - "Log model+params to registry"
      - "Write model card v0.1"
  - name: "[Feature] Churn Risk dashboard — v1 tiles"
    description: |
      AC:
      - Tiles: volume, freshness, churn-rate, top drivers
      - SLO: load < 2s, last refresh < 2h
      - Access: RBAC set for stakeholders
      DoD: UX review by PO; visual QA by SDET
    story_type: "feature"
    project: "Dashboards"
    epic: "E04: Dashboard v1"
    estimate: 2
    labels: ["area:viz","comp:dash","owner:ds2","lifecycle:ready"]
    external_id: "beeai:story:m01-mvp:e04-dashboard-v1:churn-risk-dashboard-v1"
    tasks:
      - "Create base tiles and layout"
      - "Wire data refresh & freshness indicator"
      - "Set RBAC and share with stakeholders"
'''

def write_if_missing(path, contents):
    p = Path(path)
    if p.exists():
        print(f"[skip] {path} exists")
        return
    print(f"[write] {path}")
    p.write_text(contents, encoding="utf-8")

write_if_missing("shortcut_client.py", client)
write_if_missing("beeai_shortcut_config.yaml", yamlc)
PYEOF

# venv & deps
if [[ -z "${PYTHON:-}" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON=python3
  elif command -v python >/dev/null 2>&1; then PYTHON=python
  else echo "ERROR: python is required"; exit 2; fi
fi

if [[ ! -d ".venv" ]]; then
  echo "[venv] creating .venv"
  "$PYTHON" -m venv .venv
else
  echo "[venv] using existing .venv"
fi

# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install --upgrade pip >/dev/null
pip install -q requests pyyaml python-dateutil

# token
if [[ -z "${TOKEN}" ]]; then
  read -r -p "Enter your Shortcut API token: " TOKEN
fi
export SHORTCUT_TOKEN="$TOKEN"

# run
echo "[run] python shortcut_client.py --config beeai_shortcut_config.yaml ${MODE}"
python shortcut_client.py --config beeai_shortcut_config.yaml "${MODE}"
echo "[done] ${MODE} completed."
