
# shortcut_client.py
# BeeAI ⇄ Shortcut bootstrapper (idempotent upserts via external_id)
#
# Usage:
#   export SHORTCUT_TOKEN=<your token>
#   python shortcut_client.py --config beeai_shortcut_config.yaml bootstrap
#
# Optional:
#   python shortcut_client.py --config beeai_shortcut_config.yaml dry-run
#
# Requires: requests, pyyaml, python-dateutil

import argparse
import os
import sys
import time
import json
from datetime import datetime, timedelta, date
from typing import Any, Dict, Optional, List, Tuple

import requests
import yaml
from dateutil import tz
from dateutil.relativedelta import relativedelta

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
            sleep = min(2 ** (attempt-1) * 0.5, 8.0)
            time.sleep(sleep)
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
    # get Monday of current ISO week
    monday = now - timedelta(days=now.weekday())
    start = datetime(monday.year, monday.month, monday.day, tzinfo=now.tzinfo)
    end = start + timedelta(days=iteration_length_days-1)
    return start.date().isoformat(), end.date().isoformat()

# -------- Entity helpers (naive list+filter fallbacks) --------

def find_project_by_external_id(external_id: str) -> Optional[dict]:
    r = _req("GET", "/projects")
    if r.status_code != 200: _die(r, "list projects")
    for p in r.json():
        if p.get("external_id") == external_id:
            return p
    return None

def create_project(payload: dict) -> dict:
    r = _req("POST", "/projects", payload)
    if r.status_code not in (200,201): _die(r, "create project")
    return r.json()

def upsert_project(p: dict) -> dict:
    found = find_project_by_external_id(p["external_id"])
    if found: return found
    return create_project({
        "name": p["name"],
        "description": p.get("description",""),
        "external_id": p["external_id"]
    })

def get_milestones() -> List[dict]:
    r = _req("GET", "/milestones")
    if r.status_code != 200: _die(r, "list milestones")
    return r.json()

def find_milestone_by_external_id(external_id: str) -> Optional[dict]:
    for m in get_milestones():
        if m.get("external_id") == external_id:
            return m
    return None

def create_milestone(payload: dict) -> dict:
    r = _req("POST", "/milestones", payload)
    if r.status_code not in (200,201): _die(r, "create milestone")
    return r.json()

def update_milestone(mid: int, patch: dict) -> dict:
    r = _req("PUT", f"/milestones/{mid}", patch)
    if r.status_code != 200: _die(r, "update milestone")
    return r.json()

def upsert_milestone(m: dict) -> dict:
    found = find_milestone_by_external_id(m["external_id"])
    payload = {
        "name": m["name"],
        "description": m.get("description",""),
        "state": m.get("state","to_do"),
        "external_id": m["external_id"]
    }
    if found:
        return update_milestone(found["id"], payload)
    return create_milestone(payload)

def list_epics() -> List[dict]:
    r = _req("GET", "/epics")
    if r.status_code != 200: _die(r, "list epics")
    return r.json()

def find_epic_by_external_id(external_id: str) -> Optional[dict]:
    for e in list_epics():
        if e.get("external_id") == external_id:
            return e
    return None

def create_epic(payload: dict) -> dict:
    r = _req("POST", "/epics", payload)
    if r.status_code not in (200,201): _die(r, "create epic")
    return r.json()

def update_epic(eid: int, patch: dict) -> dict:
    r = _req("PUT", f"/epics/{eid}", patch)
    if r.status_code != 200: _die(r, "update epic")
    return r.json()

def upsert_epic(e: dict, milestone_id: int) -> dict:
    found = find_epic_by_external_id(e["external_id"])
    payload = {
        "name": e["name"],
        "description": e.get("description",""),
        "milestone_id": milestone_id,
        "labels": e.get("labels", []),
        "external_id": e["external_id"]
    }
    if found:
        return update_epic(found["id"], payload)
    return create_epic(payload)

def list_iterations() -> List[dict]:
    r = _req("GET", "/iterations")
    if r.status_code != 200: _die(r, "list iterations")
    return r.json()

def find_iteration_by_external_id(external_id: str) -> Optional[dict]:
    for it in list_iterations():
        if it.get("external_id") == external_id:
            return it
    return None

def create_iteration(payload: dict) -> dict:
    r = _req("POST", "/iterations", payload)
    if r.status_code not in (200,201): _die(r, "create iteration")
    return r.json()

def update_iteration(iid: int, patch: dict) -> dict:
    r = _req("PUT", f"/iterations/{iid}", patch)
    if r.status_code != 200: _die(r, "update iteration")
    return r.json()

def upsert_iteration(i: dict) -> dict:
    found = find_iteration_by_external_id(i["external_id"])
    payload = {
        "name": i["name"],
        "start_date": i.get("start_date"),
        "end_date": i.get("end_date"),
        "external_id": i["external_id"]
    }
    # Remove None to avoid API date parse issues
    payload = {k:v for k,v in payload.items() if v}
    if found:
        return update_iteration(found["id"], payload)
    return create_iteration(payload)

def list_stories() -> List[dict]:
    r = _req("GET", "/stories")
    if r.status_code != 200: _die(r, "list stories")
    return r.json()

def find_story_by_external_id(external_id: str) -> Optional[dict]:
    for s in list_stories():
        if s.get("external_id") == external_id:
            return s
    return None

def create_story(payload: dict) -> dict:
    r = _req("POST", "/stories", payload)
    if r.status_code not in (200,201): _die(r, "create story")
    return r.json()

def update_story(story_id: int, patch: dict) -> dict:
    r = _req("PUT", f"/stories/{story_id}", patch)
    if r.status_code != 200: _die(r, "update story")
    return r.json()

def upsert_story(s: dict) -> dict:
    found = find_story_by_external_id(s["external_id"])
    if found:
        return update_story(found["id"], s)
    return create_story(s)

def create_task(payload: dict) -> dict:
    r = _req("POST", "/tasks", payload)
    if r.status_code not in (200,201): _die(r, "create task")
    return r.json()

# -------- Bootstrap orchestration --------

def bootstrap(cfg: dict, dry_run: bool=False):
    # Projects
    name_to_project: Dict[str, dict] = {}
    for p in cfg.get("projects", []):
        if dry_run:
            print(f"[dry-run] upsert project: {p['name']} ({p['external_id']})")
            name_to_project[p["name"]] = {"id": 0}
        else:
            proj = upsert_project(p)
            name_to_project[p["name"]] = proj
            print(f"[ok] project: {proj['name']} id={proj['id']}")

    # Milestone
    ms_cfg = cfg["milestone"]
    if dry_run:
        milestone = {"id": 0}
        print(f"[dry-run] upsert milestone: {ms_cfg['name']}")
    else:
        milestone = upsert_milestone(ms_cfg)
        print(f"[ok] milestone: {milestone['name']} id={milestone['id']}")

    # Epics
    name_to_epic: Dict[str, dict] = {}
    for e in cfg.get("epics", []):
        if dry_run:
            ep = {"id": 0}
            print(f"[dry-run] upsert epic: {e['name']}")
        else:
            ep = upsert_epic(e, milestone_id=milestone["id"])
            print(f"[ok] epic: {ep['name']} id={ep['id']}")
        name_to_epic[e["name"]] = ep

    # Iteration
    it_cfg = cfg.get("iteration", {})
    if it_cfg:
        start = it_cfg.get("start_date")
        end = it_cfg.get("end_date")
        if not start or not end:
            tzname = cfg.get("org", {}).get("timezone", "UTC")
            days = int(cfg.get("org", {}).get("iteration_length_days", 7))
            start, end = _iso_week_dates(tzname, days)
        it_payload = {
            "name": it_cfg["name"],
            "start_date": start,
            "end_date": end,
            "external_id": it_cfg["external_id"]
        }
        if dry_run:
            iteration = {"id": 0}
            print(f"[dry-run] upsert iteration: {it_payload['name']} {start}..{end}")
        else:
            iteration = upsert_iteration(it_payload)
            print(f"[ok] iteration: {iteration['name']} id={iteration['id']}")
    else:
        iteration = None

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
            print(f"[dry-run] upsert story: {s['name']} (proj '{s['project']}', epic '{s['epic']}')")
        else:
            story = upsert_story(story_payload)
            print(f"[ok] story: {story['name']} id={story['id']}")

        # Tasks
        for idx, t in enumerate(s.get("tasks", []), start=1):
            task_payload = {
                "description": t,
                "story_id": story["id"],
                "external_id": f"beeai:task:{s['external_id']}:{idx}"
            }
            if dry_run:
                print(f"[dry-run]   task: {t}")
            else:
                task = create_task(task_payload)
                print(f"[ok]   task id={task['id']} - {t}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True, help="Path to beeai_shortcut_config.yaml")
    ap.add_argument("command", choices=["bootstrap","dry-run"])
    args = ap.parse_args()

    with open(args.config, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    if args.command == "dry-run":
        bootstrap(cfg, dry_run=True)
    else:
        bootstrap(cfg, dry_run=False)

if __name__ == "__main__":
    main()
