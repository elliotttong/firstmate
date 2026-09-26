#!/usr/bin/env python3
"""notion-fake.py - a tiny local stand-in for the Notion REST API.

Used by tests/fm-notion*.test.sh through FM_NOTION_API_BASE. It serves one
in-memory world loaded from a JSON fixture and records every request it gets,
so a test can assert both what the client printed and what it sent.

Usage: notion-fake.py <world.json> <port-file> <request-log>

World shape:
  {"databases": {"<db-id>": {"properties": {...}, "pages": [<page>, ...]}},
   "users_me": {...}}
A page is a Notion page object ({"id", "url", "properties", ...}).

Behaviour:
  GET  /v1/users/me                 -> users_me
  GET  /v1/databases/<id>           -> the database object
  PATCH /v1/databases/<id>          -> merges "properties" into the schema
  POST /v1/databases/<id>/query     -> pages whose properties satisfy the
                                       filter subset this fake understands
                                       (checkbox equals, select equals,
                                       rich_text is_not_empty / equals, and/or),
                                       paginated by page_size
  PATCH /v1/pages/<id>              -> merges "properties" into the page
  POST /v1/pages                    -> appends a new page to its database
Anything else answers 404 {"code": "object_not_found"}.
A missing or wrong bearer token answers 401 {"code": "unauthorized"}.
The fake writes the listening port to <port-file> once it is ready.
"""

import json
import sys
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = "fake-notion-token"


def value_of(prop):
    kind = prop.get("type")
    return kind, prop.get(kind)


def text_of(items):
    return "".join(item.get("plain_text", item.get("text", {}).get("content", "")) for item in items or [])


def matches(page, flt):
    if not flt:
        return True
    if "and" in flt:
        return all(matches(page, sub) for sub in flt["and"])
    if "or" in flt:
        return any(matches(page, sub) for sub in flt["or"])
    name = flt.get("property")
    prop = (page.get("properties") or {}).get(name)
    if prop is None:
        return False
    kind, value = value_of(prop)
    if "checkbox" in flt:
        return bool(value) == flt["checkbox"].get("equals")
    if "select" in flt:
        cond = flt["select"]
        current = value.get("name") if value else None
        if "equals" in cond:
            return current == cond["equals"]
        if "does_not_equal" in cond:
            return current != cond["does_not_equal"]
        if cond.get("is_empty"):
            return current is None
        if cond.get("is_not_empty"):
            return current is not None
    if "rich_text" in flt:
        cond = flt["rich_text"]
        current = text_of(value)
        if cond.get("is_not_empty"):
            return current != ""
        if cond.get("is_empty"):
            return current == ""
        if "equals" in cond:
            return current == cond["equals"]
    return False


def to_stored(prop):
    """Turn a write-shaped property value into the read shape the API returns."""
    out = dict(prop)
    for kind in ("title", "rich_text"):
        if kind in out:
            out["type"] = kind
            out[kind] = [
                {"plain_text": item.get("text", {}).get("content", item.get("plain_text", ""))}
                for item in out[kind]
            ]
            return out
    for kind in ("select", "status", "checkbox", "date", "url", "number", "multi_select", "relation"):
        if kind in out:
            out["type"] = kind
            return out
    return out


class Handler(BaseHTTPRequestHandler):
    world = {}
    log_path = ""

    def log_message(self, *args):
        return

    def reply(self, status, body):
        data = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        return json.loads(raw.decode("utf-8") or "{}")

    def record(self, body):
        with open(self.log_path, "a", encoding="utf-8") as log:
            log.write(json.dumps({"method": self.command, "path": self.path, "body": body}, sort_keys=True) + "\n")

    def authorized(self):
        return self.headers.get("Authorization") == "Bearer " + TOKEN

    def handle_any(self):
        body = self.body() if self.command in ("POST", "PATCH") else None
        self.record(body)
        if not self.authorized():
            return self.reply(401, {"object": "error", "code": "unauthorized", "message": "API token is invalid."})
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        if parts[:1] != ["v1"]:
            return self.reply(404, {"code": "object_not_found"})
        parts = parts[1:]
        dbs = self.world.setdefault("databases", {})
        if self.command == "GET" and parts == ["users", "me"]:
            return self.reply(200, self.world.get("users_me", {"type": "bot", "name": "fake"}))
        if len(parts) >= 2 and parts[0] == "databases" and parts[1] in dbs:
            db = dbs[parts[1]]
            if len(parts) == 2 and self.command == "GET":
                return self.reply(200, {"object": "database", "id": parts[1], "properties": db.get("properties", {})})
            if len(parts) == 2 and self.command == "PATCH":
                props = db.setdefault("properties", {})
                for name, spec in (body.get("properties") or {}).items():
                    if spec is None:
                        props.pop(name, None)
                    else:
                        merged = dict(props.get(name, {}))
                        merged.update(spec)
                        merged.setdefault("name", name)
                        kinds = [k for k in spec if k not in ("name", "type", "description")]
                        if kinds:
                            merged["type"] = kinds[0]
                        props[name] = merged
                return self.reply(200, {"object": "database", "id": parts[1], "properties": props})
            if parts[2:] == ["query"] and self.command == "POST":
                rows = [p for p in db.get("pages", []) if matches(p, body.get("filter"))]
                start = int(body.get("start_cursor") or 0)
                size = int(body.get("page_size") or 100)
                chunk = rows[start:start + size]
                more = start + size < len(rows)
                return self.reply(200, {"results": chunk, "has_more": more,
                                        "next_cursor": str(start + size) if more else None})
        if parts[:1] == ["pages"]:
            if self.command == "POST" and len(parts) == 1:
                parent = (body.get("parent") or {}).get("database_id")
                if parent not in dbs:
                    return self.reply(404, {"code": "object_not_found"})
                page = {"id": str(uuid.uuid4()), "url": "https://notion.so/fake",
                        "properties": {n: to_stored(v) for n, v in (body.get("properties") or {}).items()}}
                dbs[parent].setdefault("pages", []).append(page)
                return self.reply(200, page)
            if self.command == "PATCH" and len(parts) == 2:
                for db in dbs.values():
                    for page in db.get("pages", []):
                        if page.get("id") == parts[1]:
                            props = page.setdefault("properties", {})
                            for name, value in (body.get("properties") or {}).items():
                                props[name] = to_stored(value)
                            return self.reply(200, page)
        if len(parts) >= 2 and parts[0] == "databases":
            return self.reply(404, {"object": "error", "code": "object_not_found", "message": "Could not find database."})
        return self.reply(404, {"code": "object_not_found"})

    do_GET = handle_any
    do_POST = handle_any
    do_PATCH = handle_any


def main():
    world_path, port_file, log_path = sys.argv[1:4]
    with open(world_path, encoding="utf-8") as handle:
        Handler.world = json.load(handle)
    Handler.log_path = log_path
    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(port_file + ".tmp", "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
    import os
    os.replace(port_file + ".tmp", port_file)
    server.serve_forever()


if __name__ == "__main__":
    main()
