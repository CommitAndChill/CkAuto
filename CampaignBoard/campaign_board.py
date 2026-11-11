#!/usr/bin/env python3
"""Campaign board: reads the status header of every PROGRESS.md and serves one dashboard.

The header contract is in README.md beside this file. Standard library only.
The project is the folder that holds CkAuto (override with --root); a project may
tune the scan with an optional CampaignBoard.json at its root.

    python CkAuto/CampaignBoard/campaign_board.py serve
    python CkAuto/CampaignBoard/campaign_board.py scan
    python CkAuto/CampaignBoard/campaign_board.py validate [files...]
    python CkAuto/CampaignBoard/campaign_board.py set-header <PROGRESS.md> <header.json> [--keep-mtime]
    python CkAuto/CampaignBoard/campaign_board.py strip <files...> | --all
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import posixpath
import re
import subprocess
import sys
import threading
import time
from fnmatch import fnmatch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent
CONFIG_NAME = "CampaignBoard.json"
DEFAULTS = {
    "roots": ["docs", "Tools"],
    "exclude": ["*/evidence/*"],
    "stale_days": 7,
    "port": 8766,
    "output": "Saved/CampaignBoard/campaigns.json",
}


def load_config(root):
    """Defaults, then the project's optional CampaignBoard.json; the name comes from the .uproject."""
    config = dict(DEFAULTS)
    override = root / CONFIG_NAME
    if override.is_file():
        config.update(json.loads(override.read_text(encoding="utf-8-sig")))

    if "project" not in config:
        projects = sorted(root.glob("*.uproject"))
        config["project"] = projects[0].stem if projects else root.name

    return config


ROOT = TOOL_DIR.parents[1]
CONFIG = load_config(ROOT)

SCHEMA = 1
STATUSES = ("active", "awaiting-review", "parked", "done", "superseded")
PHASE_STATES = ("done", "active", "next", "pending", "blocked", "skipped")
KEY_ORDER = ("campaign", "status", "updated", "phases", "next", "blocked_on",
             "owed_by_maintainer", "commits", "superseded_by")
PHASE_KEYS = ("id", "title", "state", "commit")
OPEN_PHASE_STATES = ("active", "next", "blocked")

NAME_RE = re.compile(r"(?i)^progress([_-].+)?\.md$")
SUFFIX_RE = re.compile(r"(?i)^progress[_-](.+)\.md$")
HEADER_RE = re.compile(rb"---[ \t]*\r?\n(\{.*?\})[ \t]*\r?\n---[ \t]*(?:\r?\n|$)", re.S)
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SHA_RE = re.compile(r"\b[0-9a-f]{7,40}\b")
PRUNE_DIRS = {"node_modules", "__pycache__"}
BOM = b"\xef\xbb\xbf"
HEAD_BYTES = 262144


# ---- header: split, validate, format --------------------------------------------------------

def split_header(data):
    """Returns (header text or None, body bytes, eol bytes, bom bytes)."""
    bom = BOM if data.startswith(BOM) else b""
    rest = data[len(bom):]
    eol = b"\r\n" if rest.count(b"\r\n") * 2 > rest.count(b"\n") else b"\n"
    match = HEADER_RE.match(rest)
    if not match:
        return None, rest, eol, bom

    return match.group(1).decode("utf-8", "replace"), rest[match.end():], eol, bom


def validate_header(header):
    """Returns a list of problems; empty means the header is valid."""
    if not isinstance(header, dict):
        return ["the header must be one JSON object"]

    errors = []
    for key in header:
        if key not in KEY_ORDER:
            errors.append(f"unknown key '{key}'")

    def is_text(value):
        return isinstance(value, str) and value.strip() != ""

    if not is_text(header.get("campaign")):
        errors.append("'campaign' must be a non-empty string")

    status = header.get("status")
    if status not in STATUSES:
        errors.append(f"'status' must be one of {', '.join(STATUSES)}")

    updated = header.get("updated")
    if not (isinstance(updated, str) and DATE_RE.match(updated)):
        errors.append("'updated' must be a YYYY-MM-DD date")
    else:
        try:
            dt.date.fromisoformat(updated)
        except ValueError:
            errors.append("'updated' is not a real date")

    phases = header.get("phases")
    if not isinstance(phases, list):
        errors.append("'phases' must be a list (empty when the campaign has no phases)")
        phases = []

    seen = set()
    for index, phase in enumerate(phases):
        where = f"phases[{index}]"
        if not isinstance(phase, dict):
            errors.append(f"{where} must be an object")
            continue

        for key in phase:
            if key not in PHASE_KEYS:
                errors.append(f"{where} has unknown key '{key}'")

        if not is_text(phase.get("id")):
            errors.append(f"{where}.id must be a non-empty string")
        elif phase["id"] in seen:
            errors.append(f"{where}.id '{phase['id']}' is repeated")
        else:
            seen.add(phase["id"])

        if phase.get("state") not in PHASE_STATES:
            errors.append(f"{where}.state must be one of {', '.join(PHASE_STATES)}")

        for key in ("title", "commit"):
            if key in phase and not is_text(phase[key]):
                errors.append(f"{where}.{key} must be a non-empty string when present")

    for key in ("next", "blocked_on", "superseded_by"):
        if header.get(key) is not None and not is_text(header[key]):
            errors.append(f"'{key}' must be a non-empty string or null")

    for key in ("owed_by_maintainer", "commits"):
        value = header.get(key, [])
        if not (isinstance(value, list) and all(is_text(item) for item in value)):
            errors.append(f"'{key}' must be a list of non-empty strings")

    if status in ("active", "awaiting-review") and header.get("next") is None:
        errors.append(f"a campaign that is {status} must say what happens 'next'")

    if status == "done":
        if header.get("owed_by_maintainer"):
            errors.append("a done campaign owes nothing; use awaiting-review while something is owed")

        if any(isinstance(p, dict) and p.get("state") in OPEN_PHASE_STATES for p in phases):
            errors.append("a done campaign has no active, next or blocked phase")

    if status == "superseded" and header.get("superseded_by") is None:
        errors.append("a superseded campaign must name 'superseded_by'")

    return errors


def format_header(header):
    """One canonical layout: keys in a fixed order, one phase per line."""
    def dump(value):
        return json.dumps(value, ensure_ascii=False)

    lines = []
    for key in KEY_ORDER:
        if key not in header:
            continue

        value = header[key]
        if key == "phases" and value:
            rows = [dump({k: phase[k] for k in PHASE_KEYS if k in phase}) for phase in value]
            lines.append('  "phases": [\n    ' + ",\n    ".join(rows) + "\n  ]")
        elif isinstance(value, list) and value:
            lines.append(f'  "{key}": [\n    ' + ",\n    ".join(dump(item) for item in value) + "\n  ]")
        else:
            lines.append(f'  "{key}": {dump(value)}')

    return "{\n" + ",\n".join(lines) + "\n}"


def write_header(path, header, keep_mtime):
    raw = path.read_bytes()
    stat = path.stat()
    _, body, eol, bom = split_header(raw)
    block = format_header(header).replace("\n", eol.decode()).encode("utf-8")
    path.write_bytes(bom + b"---" + eol + block + eol + b"---" + eol + eol + body.lstrip(b"\r\n"))
    if keep_mtime:
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))


# ---- scan -----------------------------------------------------------------------------------

def find_files():
    found = []
    for root in CONFIG["roots"]:
        for dirpath, dirnames, filenames in os.walk(ROOT / root):
            dirnames[:] = [d for d in dirnames if d not in PRUNE_DIRS and not d.startswith(".")]
            for name in filenames:
                if not NAME_RE.match(name):
                    continue

                path = Path(dirpath) / name
                rel = path.relative_to(ROOT).as_posix()
                if not any(fnmatch(rel, pattern) for pattern in CONFIG.get("exclude", [])):
                    found.append(path)

    return sorted(found)


def campaign_id(rel):
    directory, name = posixpath.split(rel)
    suffix = SUFFIX_RE.match(name)
    return f"{directory}#{suffix.group(1)}" if suffix else directory


def load_entry(path):
    """Returns (kind, entry) where kind is 'campaign', 'unheadered' or 'invalid'."""
    rel = path.relative_to(ROOT).as_posix()
    modified = dt.date.fromtimestamp(path.stat().st_mtime)
    entry = {"id": campaign_id(rel), "file": rel, "modified": modified.isoformat()}

    with open(path, "rb") as handle:
        header_text = split_header(handle.read(HEAD_BYTES))[0]

    if header_text is None:
        return "unheadered", entry

    try:
        header = json.loads(header_text)
    except json.JSONDecodeError as error:
        entry["errors"] = [f"the header is not valid JSON: {error.msg} (header line {error.lineno})"]
        return "invalid", entry

    errors = validate_header(header)
    if errors:
        entry["errors"] = errors
        return "invalid", entry

    today = dt.date.today()
    updated = dt.date.fromisoformat(header["updated"])
    phases = [{"id": p["id"], "title": p.get("title"), "state": p["state"], "commit": p.get("commit")}
              for p in header["phases"]]
    counted = [p for p in phases if p["state"] != "skipped"]
    days = (today - updated).days

    entry.update({
        "name": header["campaign"],
        "status": header["status"],
        "updated": header["updated"],
        "days_since_update": days,
        "phases": phases,
        "phases_done": sum(1 for p in counted if p["state"] == "done"),
        "phases_total": len(counted),
        "next": header.get("next"),
        "blocked_on": header.get("blocked_on"),
        "owed_by_maintainer": header.get("owed_by_maintainer", []),
        "commits": header.get("commits", []),
        "superseded_by": header.get("superseded_by"),
        "flags": {
            "stale": header["status"] == "active" and days > CONFIG.get("stale_days", 7),
            "header_behind": modified > updated,
        },
    })
    return "campaign", entry


def entry_shas(entry):
    text = " ".join([p["commit"] or "" for p in entry["phases"]] + entry["commits"])
    return list(dict.fromkeys(SHA_RE.findall(text)))


def run_git(repo, args, stdin=None):
    try:
        result = subprocess.run(["git", "-C", str(repo), *args], input=stdin, capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None

    return result.stdout.decode("utf-8", "replace") if result.returncode == 0 else None


def git_repos():
    repos = [(CONFIG.get("project", ROOT.name), ROOT)]
    modules = ROOT / ".gitmodules"
    if modules.is_file():
        for match in re.finditer(r"(?m)^\s*path\s*=\s*(.+?)\s*$", modules.read_text(encoding="utf-8", errors="replace")):
            path = ROOT / match.group(1)
            if (path / ".git").exists():
                repos.append((path.name, path))

    return repos


def git_lookup(shas):
    """Maps each commit that exists in the project or a submodule to {'repo', 'pushed'}."""
    result = {}
    if not shas:
        return result

    request = ("\n".join(shas) + "\n").encode()
    for name, repo in git_repos():
        output = run_git(repo, ["cat-file", "--batch-check"], stdin=request)
        if output is None:
            continue

        found = {}
        for sha, line in zip(shas, output.splitlines()):
            parts = line.split()
            if len(parts) >= 2 and parts[1] == "commit":
                found[sha] = parts[0]

        if not any(sha not in result for sha in found):
            continue

        ahead = run_git(repo, ["rev-list", "HEAD", "--branches", "--not", "--remotes"])
        unpushed = set(ahead.split()) if ahead is not None else None
        for sha, full in found.items():
            if sha not in result:
                result[sha] = {"repo": name, "pushed": None if unpushed is None else full not in unpushed}

    return result


def build(files=None, lookup=git_lookup):
    """Scans every PROGRESS file and returns the board as a dict (the campaigns.json contract)."""
    campaigns, unheadered, invalid = [], [], []
    for path in files if files is not None else find_files():
        try:
            kind, entry = load_entry(path)
        except OSError:
            continue

        {"campaign": campaigns, "unheadered": unheadered, "invalid": invalid}[kind].append(entry)

    open_campaigns = [c for c in campaigns if c["status"] not in ("done", "superseded")]
    wanted = list(dict.fromkeys(sha for c in open_campaigns for sha in entry_shas(c)))
    known = lookup(wanted)
    for campaign in campaigns:
        shas = entry_shas(campaign) if campaign in open_campaigns else []
        campaign["git"] = {
            "unpushed": [{"sha": s, "repo": known[s]["repo"]} for s in shas if s in known and known[s]["pushed"] is False],
            "missing": [s for s in shas if s not in known],
        }

    order = {status: index for index, status in enumerate(STATUSES)}
    campaigns.sort(key=lambda c: c["name"].lower())
    campaigns.sort(key=lambda c: c["updated"], reverse=True)
    campaigns.sort(key=lambda c: order[c["status"]])

    board = {
        "schema": SCHEMA,
        "project": CONFIG.get("project", ROOT.name),
        "summary": {
            **{status.replace("-", "_"): sum(1 for c in campaigns if c["status"] == status) for status in STATUSES},
            "owed_items": sum(len(c["owed_by_maintainer"]) for c in open_campaigns),
            "unpushed": sum(1 for c in campaigns if c["git"]["unpushed"]),
            "stale": sum(1 for c in campaigns if c["flags"]["stale"]),
            "invalid": len(invalid),
            "unheadered": len(unheadered),
        },
        "campaigns": campaigns,
        "invalid": invalid,
        "unheadered": unheadered,
    }
    board["version"] = hashlib.sha1(json.dumps(board, sort_keys=True).encode()).hexdigest()[:12]
    return board


def write_output(board):
    target = ROOT / CONFIG.get("output", "Saved/CampaignBoard/campaigns.json")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(board, indent=2, ensure_ascii=False), encoding="utf-8")
    return target


# ---- serve ----------------------------------------------------------------------------------

class LiveBoard:
    WALK_SECONDS = 15
    GIT_SECONDS = 60
    POLL_SECONDS = 2

    def __init__(self):
        self.lock = threading.Lock()
        self.payload = b"{}"
        self.files = []
        self.signature = None
        self.version = None
        self.changed_at = None
        self.walked_at = 0.0
        self.git_at = 0.0
        self.git_cache = {}

    def lookup(self, shas):
        missing = [sha for sha in shas if sha not in self.git_cache]
        if missing or time.time() - self.git_at > self.GIT_SECONDS:
            found = git_lookup(shas)
            self.git_cache = {sha: found.get(sha) for sha in shas}
            self.git_at = time.time()

        return {sha: state for sha, state in self.git_cache.items() if state is not None}

    def refresh(self):
        now = time.time()
        if now - self.walked_at > self.WALK_SECONDS:
            self.files = find_files()
            self.walked_at = now

        stamps = []
        for path in self.files:
            try:
                stat = path.stat()
                stamps.append((str(path), stat.st_mtime_ns, stat.st_size))
            except OSError:
                self.walked_at = 0.0

        signature = (tuple(stamps), dt.date.today().isoformat())
        if signature == self.signature and now - self.git_at <= self.GIT_SECONDS:
            return

        self.signature = signature
        board = build(self.files, self.lookup)
        if board["version"] != self.version:
            self.version = board["version"]
            self.changed_at = dt.datetime.now().astimezone().isoformat(timespec="seconds")
            write_output(board)

        board["changed_at"] = self.changed_at
        with self.lock:
            self.payload = json.dumps(board, ensure_ascii=False).encode("utf-8")

    def loop(self):
        while True:
            try:
                self.refresh()
            except Exception as error:  # the watcher must outlive one bad scan
                print(f"scan failed: {error}", file=sys.stderr)

            time.sleep(self.POLL_SECONDS)


def make_handler(live):
    class Handler(BaseHTTPRequestHandler):
        def send(self, code, kind, body):
            self.send_response(code)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            route = self.path.split("?", 1)[0]
            if route == "/campaigns.json":
                with live.lock:
                    body = live.payload

                self.send(200, "application/json; charset=utf-8", body)
            elif route in ("/", "/index.html"):
                page = TOOL_DIR / "index.html"
                if page.is_file():
                    self.send(200, "text/html; charset=utf-8", page.read_bytes())
                else:
                    self.send(404, "text/plain; charset=utf-8", b"index.html is missing beside campaign_board.py")
            else:
                self.send(404, "text/plain; charset=utf-8", b"not found")

        def log_message(self, *args):
            pass

    return Handler


# ---- commands -------------------------------------------------------------------------------

def cmd_serve(args):
    live = LiveBoard()
    live.refresh()
    threading.Thread(target=live.loop, daemon=True).start()
    port = args.port or CONFIG.get("port", 8766)
    server = ThreadingHTTPServer(("127.0.0.1", port), make_handler(live))
    print(f"Campaign board: http://127.0.0.1:{port}/  (Ctrl+C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass

    return 0


def cmd_scan(args):
    board = build()
    target = write_output(board)
    summary = board["summary"]
    print(f"{len(board['campaigns'])} campaigns: " + ", ".join(f"{summary[s.replace('-', '_')]} {s}" for s in STATUSES))
    print(f"{summary['owed_items']} owed items, {summary['unpushed']} with unpushed commits, {summary['stale']} stale, "
          f"{summary['invalid']} invalid headers, {summary['unheadered']} files without a header")
    for campaign in board["campaigns"]:
        if campaign["status"] in ("done", "superseded") and not args.all:
            continue

        print(f"  {campaign['status']:<16}{campaign['phases_done']:>2}/{campaign['phases_total']:<3} {campaign['name']}  ({campaign['file']})")

    for entry in board["invalid"]:
        print(f"  INVALID  {entry['file']}: " + "; ".join(entry["errors"]))

    print(f"Wrote {target}")
    return 0


def cmd_validate(args):
    files = [Path(f).resolve() for f in args.files] if args.files else find_files()
    bad = 0
    for path in files:
        kind, entry = load_entry(path)
        if kind == "invalid":
            bad += 1
            print(f"INVALID  {entry['file']}")
            for error in entry["errors"]:
                print(f"    {error}")
        elif kind == "unheadered" and args.files:
            bad += 1
            print(f"NO HEADER  {entry['file']}")
        elif args.files:
            print(f"ok  {entry['file']}")

    if not bad:
        print(f"{len(files)} files checked, no invalid headers")

    return 1 if bad else 0


def cmd_set_header(args):
    path = Path(args.file).resolve()
    header = json.loads(Path(args.header).read_text(encoding="utf-8-sig"))
    if isinstance(header, dict) and "updated" not in header:
        day = dt.date.fromtimestamp(path.stat().st_mtime) if args.keep_mtime else dt.date.today()
        header["updated"] = day.isoformat()

    errors = validate_header(header)
    if errors:
        print(f"REFUSED  {path}")
        for error in errors:
            print(f"    {error}")

        return 1

    write_header(path, header, args.keep_mtime)
    print(f"ok  {path.relative_to(ROOT).as_posix()}  ({header['status']}, updated {header['updated']})")
    return 0


def cmd_strip(args):
    files = find_files() if args.all else [Path(f).resolve() for f in args.files]
    for path in files:
        raw = path.read_bytes()
        stat = path.stat()
        header_text, body, _, bom = split_header(raw)
        if header_text is None:
            continue

        path.write_bytes(bom + body.lstrip(b"\r\n"))
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        print(f"stripped  {path.relative_to(ROOT).as_posix()}")

    return 0


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description="Campaign board for PROGRESS.md status headers")
    parser.add_argument("--root", help="project root (default: the folder that holds CkAuto)")
    commands = parser.add_subparsers(dest="command", required=True)

    serve = commands.add_parser("serve", help="serve the live dashboard on 127.0.0.1")
    serve.add_argument("--port", type=int)
    serve.set_defaults(run=cmd_serve)

    scan = commands.add_parser("scan", help="write campaigns.json once and print a summary")
    scan.add_argument("--all", action="store_true", help="also list done and superseded campaigns")
    scan.set_defaults(run=cmd_scan)

    validate = commands.add_parser("validate", help="check headers; with no files, checks every PROGRESS file")
    validate.add_argument("files", nargs="*")
    validate.set_defaults(run=cmd_validate)

    set_header = commands.add_parser("set-header", help="insert or replace the header of one PROGRESS file")
    set_header.add_argument("file")
    set_header.add_argument("header", help="a JSON file holding the header object")
    set_header.add_argument("--keep-mtime", action="store_true",
                            help="keep the file's modified time; a missing 'updated' is filled from it")
    set_header.set_defaults(run=cmd_set_header)

    strip = commands.add_parser("strip", help="remove the header again")
    strip.add_argument("files", nargs="*")
    strip.add_argument("--all", action="store_true")
    strip.set_defaults(run=cmd_strip)

    args = parser.parse_args()
    if args.root:
        global ROOT, CONFIG
        ROOT = Path(args.root).resolve()
        CONFIG = load_config(ROOT)

    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
