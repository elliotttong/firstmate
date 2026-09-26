#!/usr/bin/env python3
"""fm-notion.py - Notion REST engine behind bin/fm-notion.sh.

Run only through bin/fm-notion.sh, which resolves the credential and the
database ids from the home .env and passes them here in the environment so the
token never reaches argv. This file owns the wire format: every Notion request,
the narrow queries, and the conversion of a page's properties into plain
values. bin/fm-notion.sh's header owns the command surface and configuration.

Environment (set by the wrapper):
  NOTION_TOKEN            integration token (required, never printed)
  FM_NOTION_DB            REST database id the command addresses
  FM_NOTION_API_BASE      API base URL (default https://api.notion.com/v1);
                          tests point it at a local fake
  FM_NOTION_TIMEOUT       socket timeout in seconds (default 20)
  FM_NOTION_MAX_ROWS      hard ceiling on rows one query may return (default 200)

Exit status: 0 success, 1 a Notion or network failure (one "fm-notion: ..."
line on stderr naming the HTTP status and Notion's own error code), 2 usage.
"""

import json
import os
import sys
import urllib.error
import urllib.request

NOTION_VERSION = "2022-06-28"
PAGE_SIZE_MAX = 100


def die(message, status=1):
    sys.stderr.write("fm-notion: %s\n" % message)
    sys.exit(status)


def env_int(name, default, low, high):
    raw = os.environ.get(name, "")
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        die("%s must be a whole number, got %r" % (name, raw), 2)
    if value < low or value > high:
        die("%s must be from %d to %d, got %d" % (name, low, high, value), 2)
    return value


def api_base():
    return os.environ.get("FM_NOTION_API_BASE", "https://api.notion.com/v1").rstrip("/")


def request(method, path, body=None):
    token = os.environ.get("NOTION_TOKEN", "")
    if not token:
        die("NOTION_TOKEN is not set", 2)
    timeout = env_int("FM_NOTION_TIMEOUT", 20, 1, 120)
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(api_base() + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Notion-Version", NOTION_VERSION)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as err:
        code = ""
        detail = ""
        try:
            payload = json.loads(err.read().decode("utf-8") or "{}")
            code = payload.get("code", "")
            detail = payload.get("message", "")
        except (ValueError, OSError):
            pass
        hint = ""
        if err.code == 404 and path.startswith("/databases/"):
            # A data source id (the collection:// form other tools show) is not
            # a REST database id, and Notion answers it with a 404 that reads
            # like a sharing problem.
            hint = " (check the id is the REST database id, not a data source id, and that the database is shared with the integration)"
        die("HTTP %d %s %s: %s%s" % (err.code, method, path.split("?")[0], code or detail or "error", hint))
    except (urllib.error.URLError, OSError) as err:
        die("cannot reach Notion at %s: %s" % (api_base(), getattr(err, "reason", err)))
    except ValueError:
        die("Notion returned a response that is not JSON for %s %s" % (method, path))
    return None


def plain_text(items):
    return "".join(item.get("plain_text", "") for item in items or [])


def simplify(prop):
    """Turn one Notion property value into a plain JSON value."""
    kind = prop.get("type")
    value = prop.get(kind)
    if kind in ("title", "rich_text"):
        return plain_text(value)
    if kind in ("select", "status"):
        return value.get("name") if value else None
    if kind == "multi_select":
        return [option.get("name") for option in value or []]
    if kind == "checkbox":
        return bool(value)
    if kind == "date":
        return value.get("start") if value else None
    if kind in ("url", "email", "phone_number", "number", "created_time", "last_edited_time"):
        return value
    if kind == "relation":
        return [item.get("id") for item in value or []]
    if kind == "unique_id":
        if not value or value.get("number") is None:
            return None
        prefix = value.get("prefix")
        return "%s-%s" % (prefix, value["number"]) if prefix else str(value["number"])
    if kind == "formula":
        if not value:
            return None
        return value.get(value.get("type"))
    if kind == "rollup":
        if not value:
            return None
        inner = value.get("type")
        if inner == "array":
            return [simplify(item) for item in value.get("array") or []]
        if inner == "date":
            date = value.get("date")
            return date.get("start") if date else None
        return value.get(inner)
    if kind in ("people", "created_by", "last_edited_by"):
        if isinstance(value, list):
            return [person.get("id") for person in value]
        return value.get("id") if value else None
    return None


def simplify_page(page):
    return {
        "id": page.get("id"),
        "url": page.get("url"),
        "last_edited_time": page.get("last_edited_time"),
        "props": {name: simplify(prop) for name, prop in (page.get("properties") or {}).items()},
    }


def query(database, body, limit):
    """Run one filtered database query, following pagination up to limit rows."""
    rows = []
    cursor = None
    while len(rows) < limit:
        page_body = dict(body)
        page_body["page_size"] = min(PAGE_SIZE_MAX, limit - len(rows))
        if cursor:
            page_body["start_cursor"] = cursor
        result = request("POST", "/databases/%s/query" % database, page_body)
        rows.extend(result.get("results") or [])
        if not result.get("has_more"):
            return rows, False
        cursor = result.get("next_cursor")
        if not cursor:
            return rows, False
    return rows, True


def database_id():
    database = os.environ.get("FM_NOTION_DB", "")
    if not database:
        die("no database id resolved for this command", 2)
    return database


def read_stdin_json():
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        value = json.loads(raw)
    except ValueError as err:
        die("stdin is not JSON: %s" % err, 2)
    if not isinstance(value, dict):
        die("stdin must be a JSON object", 2)
    return value


def command_query(args):
    """query [--limit N]: stdin is {"filter": ..., "sorts": ...}; prints JSON lines."""
    ceiling = env_int("FM_NOTION_MAX_ROWS", 200, 1, 2000)
    limit = ceiling
    while args:
        flag = args.pop(0)
        if flag == "--limit" and args:
            try:
                limit = int(args.pop(0))
            except ValueError:
                die("--limit must be a whole number", 2)
        else:
            die("unknown query argument: %s" % flag, 2)
    if limit < 1 or limit > ceiling:
        die("--limit must be from 1 to %d" % ceiling, 2)
    spec = read_stdin_json()
    body = {}
    for key in ("filter", "sorts"):
        if key in spec:
            body[key] = spec[key]
    if "filter" not in body:
        # Narrow reads only: an unfiltered query is a whole-database fetch.
        die("query needs a filter; a whole-database read is refused", 2)
    rows, truncated = query(database_id(), body, limit)
    for page in rows:
        sys.stdout.write(json.dumps(simplify_page(page), sort_keys=True) + "\n")
    if truncated:
        sys.stderr.write("fm-notion: query stopped at %d rows; more matched\n" % limit)
    return 0


def command_whoami(args):
    if args:
        die("whoami takes no arguments", 2)
    me = request("GET", "/users/me")
    name = me.get("name") or ""
    kind = me.get("type") or ""
    sys.stdout.write("notion: %s %s\n" % (kind, name))
    return 0


# The Action Items fields this board needs, by owner. Firstmate writes the
# first group and the captain never does; the captain writes the second and
# firstmate never does. Status, Priority and Lane already exist and stay his.
# Every tag is a fixed option list so filters cannot silently miss a spelling.
DEV_STATUS = ["Queued", "Needs design", "Specced", "Building", "In review", "Done", "Failed"]
KINDS = ["ship", "scout", "captain", "task"]
SURFACES = ["Extension", "Web app", "Landing", "Mobile", "Business OS", "WordPress", "Backend", "Firstmate"]


def select_spec(options):
    return {"select": {"options": [{"name": name} for name in options]}}


def action_items_schema(repos, database=None):
    schema = {
        # firstmate-owned
        "Task ID": {"rich_text": {}},
        "Kind": select_spec(KINDS),
        "Dev status": select_spec(DEV_STATUS),
        "Last checked": {"date": {}},
        "Last activity": {"date": {}},
        "Needs you": {"checkbox": {}},
        "Question": {"rich_text": {}},
        "Repo": select_spec(repos),
        "PR": {"url": {}},
        "Report": {"rich_text": {}},
        "Worker": {"rich_text": {}},
        # captain-owned
        "Ready": {"checkbox": {}},
        "Answer": {"rich_text": {}},
        "Surface": select_spec(SURFACES),
        "Design handover": {"url": {}},
    }
    if database:
        # Dependencies, the smallest shape that shows "this unblocks three
        # others": a self-relation and a count. No score. Either side may
        # edit the relation; Unblocks is derived and never typed.
        schema["Blocked by"] = {"relation": {"database_id": database, "type": "dual_property",
                                             "dual_property": {"synced_property_name": "Blocks"}}}
    return schema


# Derived fields that depend on another property existing first.
def action_items_derived():
    return {
        "Unblocks": {"rollup": {"relation_property_name": "Blocks", "rollup_property_name": "Task ID",
                                "function": "count"}},
    }


def command_ensure_schema(args):
    """ensure-schema [--dry-run]: add missing Action Items properties.

    Additive only: a property that already exists is never retyped, renamed,
    or deleted, and its options are never replaced. An existing property of
    the wrong type is reported and the command exits 1 without writing.
    """
    dry_run = False
    for flag in args:
        if flag == "--dry-run":
            dry_run = True
        else:
            die("unknown ensure-schema argument: %s" % flag, 2)
    repos = [r for r in os.environ.get("FM_NOTION_REPOS", "").split(",") if r]
    if not repos:
        die("FM_NOTION_REPOS is empty; the wrapper passes the registered projects", 2)
    database = database_id()
    current = request("GET", "/databases/%s" % database).get("properties") or {}
    missing = {}
    conflicts = []
    for stage in ("base", "derived"):
        if stage == "derived":
            if conflicts:
                break
            if missing and not dry_run:
                request("PATCH", "/databases/%s" % database, {"properties": missing})
                current = request("GET", "/databases/%s" % database).get("properties") or {}
            missing = {}
        wanted = action_items_schema(repos, database) if stage == "base" else action_items_derived()
        for name, spec in wanted.items():
            kind = next(iter(spec))
            have = current.get(name)
            if have is None:
                missing[name] = spec
            elif have.get("type") != kind:
                conflicts.append("%s is %s, expected %s" % (name, have.get("type"), kind))
            else:
                sys.stdout.write("present: %s\n" % name)
        for name in missing:
            sys.stdout.write("%s: %s\n" % ("would add" if dry_run else "add", name))
    for line in conflicts:
        sys.stdout.write("conflict: %s\n" % line)
    if conflicts:
        die("%d property type conflict(s); nothing written" % len(conflicts))
    if missing and not dry_run:
        request("PATCH", "/databases/%s" % database, {"properties": missing})
    return 0


# Firstmate's lane on the board. Lane is a safety field: every other value,
# including an empty one and "Both", is not firstmate's, so a personal item
# can never be picked up by accident.
FIRSTMATE_LANE = "Claude"


def one_line(text, limit=160):
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[: limit - 3] + "..."


def command_down(args):
    """down: print what the captain has put on the board for firstmate.

    Two narrow reads of Action Items, never a whole-database fetch:
      ready  <page-id> <title>          in firstmate's lane, Ready ticked, and
                                        not yet taken (no Task ID)
      answer <task-id> <page-id> <answer>
                                        a row flagged Needs you that now carries
                                        an Answer
    A field can raise work or carry an answer; it never grants merge,
    destructive, irreversible or security-sensitive authority.
    """
    if args:
        die("down takes no arguments", 2)
    database = database_id()
    limit = env_int("FM_NOTION_MAX_ROWS", 200, 1, 2000)
    ready_filter = {"and": [
        {"property": "Lane", "select": {"equals": FIRSTMATE_LANE}},
        {"property": "Ready", "checkbox": {"equals": True}},
        {"property": "Task ID", "rich_text": {"is_empty": True}},
    ]}
    answer_filter = {"and": [
        {"property": "Needs you", "checkbox": {"equals": True}},
        {"property": "Answer", "rich_text": {"is_not_empty": True}},
    ]}
    rows, truncated = query(database, {"filter": ready_filter}, limit)
    for page in rows:
        simple = simplify_page(page)
        title = next((plain_text(p.get("title")) for p in (page.get("properties") or {}).values()
                      if p.get("type") == "title"), "")
        sys.stdout.write("ready %s %s\n" % (simple["id"], one_line(title)))
    if truncated:
        sys.stderr.write("fm-notion: ready read stopped at %d rows\n" % limit)
    rows, truncated = query(database, {"filter": answer_filter}, limit)
    for page in rows:
        props = simplify_page(page)["props"]
        task = props.get("Task ID") or "-"
        sys.stdout.write("answer %s %s %s\n" % (one_line(task, 64).replace(" ", "_"), page.get("id"),
                                                 one_line(props.get("Answer"))))
    if truncated:
        sys.stderr.write("fm-notion: answer read stopped at %d rows\n" % limit)
    return 0


def read_meta(path):
    meta = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                key, sep, value = line.rstrip("\n").partition("=")
                if sep:
                    meta[key] = value
    except OSError:
        pass
    return meta


def last_status_word(path):
    """The state word of a task's newest status event, or "" when none."""
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - 4096))
            lines = [ln for ln in handle.read().decode("utf-8", "replace").splitlines() if ln.strip()]
    except OSError:
        return ""
    if not lines:
        return ""
    return lines[-1].split(" ", 1)[0].split(":", 1)[0].strip()


TOON_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}
TRUNCATION_SENTINEL = "\n... (truncated"


def toon_fields(line):
    """Split one TOON tabular row: comma-separated, quoted with backslash escapes."""
    fields = []
    current = []
    quoted = False
    i = 0
    while i < len(line):
        ch = line[i]
        if quoted:
            if ch == "\\" and i + 1 < len(line):
                current.append(TOON_ESCAPES.get(line[i + 1], line[i + 1]))
                i += 2
                continue
            if ch == '"':
                quoted = False
            else:
                current.append(ch)
        elif ch == '"':
            quoted = True
        elif ch == ",":
            fields.append("".join(current))
            current = []
        else:
            current.append(ch)
        i += 1
    fields.append("".join(current))
    return fields


def parse_backlog_listing(path):
    """Parse the TOON rows of `tasks-axi list --fields hold_kind,hold_reason`."""
    rows = []
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    header = None
    for line in text.splitlines():
        if line.startswith("tasks["):
            header = line[line.index("{") + 1:line.index("}")].split(",")
            continue
        if header is None or not line.startswith("  "):
            continue
        fields = toon_fields(line.strip())
        if len(fields) != len(header):
            continue
        row = dict(zip(header, fields))
        for key, value in row.items():
            cut = value.find(TRUNCATION_SENTINEL)
            if cut >= 0:
                row[key] = value[:cut].rstrip() + "..."
        rows.append(row)
    return rows


def dev_status_for(task, meta, status_word):
    """Derive a board Dev status from firstmate's own records alone."""
    state = task.get("state")
    if state == "done":
        return "Done"
    if state == "queued":
        return "Queued"
    if status_word == "failed":
        return "Failed"
    if status_word == "done":
        return "In review"
    return "Building"


def last_event_age_days(state_dir, tid, now_epoch):
    """Days since the task's status log (or, lacking one, its meta) last changed."""
    for name in (tid + ".status", tid + ".meta"):
        try:
            return (now_epoch - os.stat(os.path.join(state_dir, name)).st_mtime) / 86400.0
        except OSError:
            continue
    return None


def last_activity_day(state_dir, tid):
    """UTC day of the task's newest status event, or "" with no record."""
    import datetime
    for name in (tid + ".status", tid + ".meta"):
        try:
            mtime = os.stat(os.path.join(state_dir, name)).st_mtime
        except OSError:
            continue
        return datetime.datetime.fromtimestamp(mtime, datetime.timezone.utc).strftime("%Y-%m-%d")
    return ""


def local_view(state_dir, listing_path, now_epoch, stale_days):
    view = {}
    for task in parse_backlog_listing(listing_path):
        tid = task.get("id")
        if not tid:
            continue
        meta = read_meta(os.path.join(state_dir, tid + ".meta"))
        word = last_status_word(os.path.join(state_dir, tid + ".status"))
        held = task.get("hold_kind") == "captain"
        repo = task.get("repo") if task.get("repo") not in ("", "-") else ""
        stale = ""
        if task.get("state") == "in_flight" and not held:
            age = last_event_age_days(state_dir, tid, now_epoch)
            if not meta:
                stale = "no live record"
            elif age is not None and age >= stale_days and word not in ("done", "paused"):
                stale = "quiet for %d days" % int(age)
        view[tid] = {
            "title": task.get("title") or tid,
            "Dev status": dev_status_for(task, meta, word),
            "Kind": task.get("kind") if task.get("kind") not in ("", "-") else "",
            "Repo": repo,
            "Needs you": held,
            "Question": one_line(task.get("hold_reason"), 1900) if held else "",
            "PR": meta.get("pr") or None,
            "Worker": meta.get("harness", ""),
            "Last activity": last_activity_day(state_dir, tid),
            "_stale": stale,
        }
    return view


# Stages the reconciler cannot derive from local records. A queued row the
# board already carries in one of these keeps it: firstmate sets them by hand.
PRE_BUILD = ("Needs design", "Specced")
SYNCED = ("Dev status", "Kind", "Repo", "Needs you", "Question", "PR", "Worker", "Last activity")


def rich(text):
    return {"rich_text": [{"type": "text", "text": {"content": text}}] if text else []}


def to_property(name, value):
    if name in ("Dev status", "Kind", "Repo"):
        return {"select": {"name": value} if value else None}
    if name == "Needs you":
        return {"checkbox": bool(value)}
    if name == "PR":
        return {"url": value or None}
    if name in ("Last checked", "Last activity"):
        return {"date": {"start": value} if value else None}
    return rich(value or "")


def command_up(args):
    """up [--apply] [--max-writes N]: bring the board into line with firstmate.

    Reads firstmate's records (FM_NOTION_STATE_DIR metas and status logs, and
    the backlog listing at FM_NOTION_BACKLOG_LISTING) and every board row that
    carries a Task ID. Prints one line per difference:
      create <task-id> <dev-status> <title>
      update <task-id> <field>: <board> -> <local>
      refresh <task-id>                         Last checked is older than the window
      orphan <task-id> <page-id>                on the board, not in firstmate's records
      stale <task-id> <why>                     in flight, not held for the captain,
                                                with no record or a status log quiet for
                                                FM_NOTION_STALE_DAYS (default 2) and not
                                                ending in done or paused
    Report-only by default. --apply writes creates, updates and refreshes, at
    most --max-writes pages per pass (default 20) so one pass fits inside the
    watcher's check bound; the next pass continues. Orphan and stale lines are
    reported, never resolved: picking a winner would hide the drift. Only
    firstmate-owned fields are ever written.
    """
    apply = False
    max_writes = 20
    while args:
        flag = args.pop(0)
        if flag == "--apply":
            apply = True
        elif flag == "--max-writes" and args:
            try:
                max_writes = int(args.pop(0))
            except ValueError:
                die("--max-writes must be a whole number", 2)
        else:
            die("unknown up argument: %s" % flag, 2)
    if max_writes < 1 or max_writes > 200:
        die("--max-writes must be from 1 to 200", 2)
    state_dir = os.environ.get("FM_NOTION_STATE_DIR", "")
    listing = os.environ.get("FM_NOTION_BACKLOG_LISTING", "")
    if not state_dir or not listing:
        die("FM_NOTION_STATE_DIR and FM_NOTION_BACKLOG_LISTING are required", 2)
    refresh_hours = env_int("FM_NOTION_REFRESH_HOURS", 6, 1, 168)
    stale_days = env_int("FM_NOTION_STALE_DAYS", 2, 1, 60)
    now = os.environ.get("FM_NOTION_NOW", "")
    import datetime
    if now:
        current = datetime.datetime.fromisoformat(now.replace("Z", "+00:00"))
    else:
        current = datetime.datetime.now(datetime.timezone.utc)
    stamp = current.strftime("%Y-%m-%dT%H:%M:%S.000+00:00")

    local = local_view(state_dir, listing, current.timestamp(), stale_days)
    database = database_id()
    rows, truncated = query(database, {"filter": {"property": "Task ID", "rich_text": {"is_not_empty": True}}}, 2000)
    if truncated:
        die("board read hit the 2000-row ceiling; refusing to reconcile a partial board")
    board = {}
    for page in rows:
        simple = simplify_page(page)
        tid = (simple["props"].get("Task ID") or "").strip()
        if tid:
            board.setdefault(tid, simple)

    plan = []  # (sort key, line, write)
    for tid, want in sorted(local.items()):
        if want["_stale"]:
            plan.append((1, "stale %s %s" % (tid, want["_stale"]), None))
        have = board.get(tid)
        if have is None:
            props = {"Task ID": rich(tid), "Lane": {"select": {"name": FIRSTMATE_LANE}},
                     "Last checked": to_property("Last checked", stamp)}
            title_prop = "Action Item"
            props[title_prop] = {"title": [{"type": "text", "text": {"content": one_line(want["title"], 200)}}]}
            for name in SYNCED:
                if want[name] not in ("", None, False):
                    props[name] = to_property(name, want[name])
            plan.append((2, "create %s %s %s" % (tid, want["Dev status"], one_line(want["title"], 80)),
                         ("POST", "/pages", {"parent": {"database_id": database}, "properties": props})))
            continue
        hp = have["props"]
        changes = {}
        lines = []
        for name in SYNCED:
            board_value = hp.get(name)
            local_value = want[name]
            if name == "Dev status" and local_value == "Queued" and board_value in PRE_BUILD:
                continue
            if name == "Needs you":
                board_value = bool(board_value)
            if name == "Last activity" and board_value:
                board_value = board_value[:10]
            if (board_value or None) != (local_value or None):
                changes[name] = to_property(name, local_value)
                lines.append("update %s %s: %s -> %s" % (tid, name, one_line(board_value, 40) or "-",
                                                          one_line(local_value, 40) or "-"))
        checked = hp.get("Last checked")
        fresh = False
        if checked:
            try:
                seen = datetime.datetime.fromisoformat(checked.replace("Z", "+00:00"))
                if seen.tzinfo is None:
                    seen = seen.replace(tzinfo=datetime.timezone.utc)
                fresh = (current - seen).total_seconds() < refresh_hours * 3600
            except ValueError:
                fresh = False
        if not changes and fresh:
            continue
        changes["Last checked"] = to_property("Last checked", stamp)
        if not lines:
            lines.append("refresh %s" % tid)
        plan.append((3, "\n".join(lines), ("PATCH", "/pages/%s" % have["id"], {"properties": changes})))
    for tid, have in sorted(board.items()):
        if tid not in local:
            plan.append((0, "orphan %s %s" % (tid, have["id"]), None))

    plan.sort(key=lambda item: item[0])
    writes = 0
    deferred = 0
    for _, line, write in plan:
        sys.stdout.write(line + "\n")
        if write is None or not apply:
            continue
        if writes >= max_writes:
            deferred += 1
            continue
        request(*write)
        writes += 1
    if apply:
        sys.stdout.write("applied %d write(s); %d deferred to the next pass\n" % (writes, deferred))
    else:
        pending = sum(1 for _, _, write in plan if write is not None)
        sys.stdout.write("report only: %d write(s) pending; rerun with --apply\n" % pending)
    return 0


# Initiative fields added to the captain's existing Projects database. It
# already carries Rating (five stars), Review Date, Next Action and Status,
# and those are used as they are. Additions only: nothing there is retyped,
# renamed or removed. Last worked is derived from the most recent related
# Action Item and is never typed; Numbers is a pointer to where the stats
# live, never copied metrics.
AUTOMATION_LEVELS = ["Fully automated", "Needs a human", "Manual"]


def projects_schema():
    return {
        "Automation level": select_spec(AUTOMATION_LEVELS),
        "Numbers": {"url": {}},
    }


def projects_derived(relation):
    return {
        "Last worked": {"rollup": {"relation_property_name": relation,
                                   "rollup_property_name": "Last activity",
                                   "function": "latest_date"}},
    }


def ensure(database, stages, dry_run):
    """Add missing properties stage by stage; never touch existing ones."""
    current = request("GET", "/databases/%s" % database).get("properties") or {}
    for index, wanted in enumerate(stages):
        if index and not dry_run:
            current = request("GET", "/databases/%s" % database).get("properties") or {}
        missing = {}
        conflicts = []
        for name, spec in wanted.items():
            kind = next(iter(spec))
            have = current.get(name)
            if have is None:
                missing[name] = spec
            elif have.get("type") != kind:
                conflicts.append("%s is %s, expected %s" % (name, have.get("type"), kind))
            else:
                sys.stdout.write("present: %s\n" % name)
        for line in conflicts:
            sys.stdout.write("conflict: %s\n" % line)
        if conflicts:
            die("%d property type conflict(s); nothing more written" % len(conflicts))
        for name in missing:
            sys.stdout.write("%s: %s\n" % ("would add" if dry_run else "add", name))
        if missing and not dry_run:
            request("PATCH", "/databases/%s" % database, {"properties": missing})


def command_ensure_projects(args):
    """ensure-projects [--dry-run]: add the initiative fields to Projects.

    Needs FM_NOTION_DB (Projects) and FM_NOTION_ACTIONS_DB (Action Items).
    Last worked rolls up Action Items' Last activity (which ensure-schema adds
    and `up` stamps only on a real change, never on a Last checked refresh)
    through the existing Action Items relation.
    """
    dry_run = False
    for flag in args:
        if flag == "--dry-run":
            dry_run = True
        else:
            die("unknown ensure-projects argument: %s" % flag, 2)
    projects = database_id()
    actions = os.environ.get("FM_NOTION_ACTIONS_DB", "")
    if not actions:
        die("FM_NOTION_ACTIONS_DB is required", 2)
    props = request("GET", "/databases/%s" % projects).get("properties") or {}
    relation = next((name for name, p in props.items() if p.get("type") == "relation"
                     and (p.get("relation") or {}).get("database_id", "").replace("-", "")
                     == actions.replace("-", "")), None)
    if relation is None:
        die("Projects has no relation to Action Items; nothing written")
    have = request("GET", "/databases/%s" % actions).get("properties") or {}
    if (have.get("Last activity") or {}).get("type") != "date":
        die("Action Items has no Last activity date; run ensure-schema first")
    ensure(projects, [projects_schema(), projects_derived(relation)], dry_run)
    return 0


COMMANDS = {
    "down": command_down,
    "ensure-projects": command_ensure_projects,
    "ensure-schema": command_ensure_schema,
    "query": command_query,
    "up": command_up,
    "whoami": command_whoami,
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        die("usage: fm-notion.py {%s} ..." % "|".join(sorted(COMMANDS)), 2)
    return COMMANDS[argv[0]](list(argv[1:]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
