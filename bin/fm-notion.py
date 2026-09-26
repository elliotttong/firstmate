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


def action_items_schema(repos):
    return {
        # firstmate-owned
        "Task ID": {"rich_text": {}},
        "Kind": select_spec(KINDS),
        "Dev status": select_spec(DEV_STATUS),
        "Last checked": {"date": {}},
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
    wanted = action_items_schema(repos)
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
    for name in missing:
        sys.stdout.write("%s: %s\n" % ("would add" if dry_run else "add", name))
    if conflicts:
        die("%d property type conflict(s); nothing written" % len(conflicts))
    if missing and not dry_run:
        request("PATCH", "/databases/%s" % database, {"properties": missing})
    return 0


COMMANDS = {
    "ensure-schema": command_ensure_schema,
    "query": command_query,
    "whoami": command_whoami,
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        die("usage: fm-notion.py {%s} ..." % "|".join(sorted(COMMANDS)), 2)
    return COMMANDS[argv[0]](list(argv[1:]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
