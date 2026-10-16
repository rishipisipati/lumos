#!/usr/bin/env python3
import argparse
import json
import mimetypes
import os
import sqlite3
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

from query import build_search_sql, parse_query

HOST = "127.0.0.1"
DEFAULT_PORT = 7788
APP_SUPPORT = Path(os.environ.get("LUMOS_HOME", str(Path.home() / "Library" / "Application Support" / "Lumos")))
DB_PATH = APP_SUPPORT / "index.sqlite"
PID_PATH = APP_SUPPORT / "indexer.pid"


def here_dir():
    return Path(__file__).resolve().parent


def web_dir():
    candidates = [here_dir() / "web", here_dir().parent / "web"]
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    raise FileNotFoundError("Lumos web UI folder is missing.")


def indexer_path():
    env = os.environ.get("LUMOS_INDEXER")
    if env:
        return Path(env)
    candidates = [
        here_dir().parent / "build" / "lumos-index",
        here_dir() / "lumos-index",
        Path("/usr/local/bin/lumos-index"),
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise FileNotFoundError("lumos-index binary is missing. Run make first.")


def open_db():
    if not DB_PATH.exists():
        return None
    connection = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only = ON")
    return connection


def meta_map(connection):
    if connection is None:
        return {}
    rows = connection.execute("SELECT key, value FROM meta").fetchall()
    return {row["key"]: row["value"] for row in rows}


def object_count(connection):
    if connection is None:
        return 0
    return int(connection.execute("SELECT COUNT(*) FROM files").fetchone()[0])


def indexer_running():
    if not PID_PATH.exists():
        return False
    try:
        pid = int(PID_PATH.read_text().strip())
    except ValueError as error:
        raise RuntimeError("Indexer pid file is invalid.") from error
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def start_indexer():
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    if indexer_running():
        return
    binary = indexer_path()
    process = subprocess.Popen(
        [str(binary), "--watch"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    PID_PATH.write_text(str(process.pid))


def format_size(size, is_dir):
    if is_dir:
        return ""
    if size < 1024:
        return str(size) + " B"
    units = ["KB", "MB", "GB", "TB"]
    value = float(size)
    unit_index = -1
    while value >= 1024.0 and unit_index < len(units) - 1:
        value /= 1024.0
        unit_index += 1
    if unit_index < 0:
        return str(size) + " B"
    if value >= 100:
        return str(int(round(value))) + " " + units[unit_index]
    if value >= 10:
        return "{:.1f} {}".format(value, units[unit_index])
    return "{:.2f} {}".format(value, units[unit_index])


def format_date(timestamp):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(timestamp))


def search(query_text, limit, offset, show_hidden):
    connection = open_db()
    if connection is None:
        return [], 0, 0
    started = time.perf_counter()
    parsed = parse_query(query_text)
    sql, params = build_search_sql(parsed, limit, offset, show_hidden)
    rows = connection.execute(sql, params).fetchall()
    elapsed_ms = int((time.perf_counter() - started) * 1000)
    results = []
    for row in rows:
        results.append(
            {
                "name": row["name"],
                "path": row["path"],
                "parent": row["parent"],
                "size": row["size"],
                "size_label": format_size(row["size"], row["is_dir"] == 1),
                "modified": row["modified"],
                "modified_label": format_date(row["modified"]),
                "is_dir": row["is_dir"] == 1,
                "ext": row["ext"],
                "is_hidden": row["is_hidden"] == 1,
            }
        )
    count = object_count(connection)
    connection.close()
    return results, count, elapsed_ms


def status_payload():
    connection = open_db()
    meta = meta_map(connection)
    count = object_count(connection)
    if connection is not None:
        connection.close()
    return {
        "objects": count,
        "indexing": meta.get("indexing", "0") == "1",
        "visited": int(meta.get("visited", "0")),
        "skipped": int(meta.get("skipped", "0")),
        "message": meta.get("message", "Starting…"),
    }


def open_path(path, reveal):
    if not path:
        raise ValueError("Missing path.")
    if not os.path.exists(path):
        raise FileNotFoundError("The file no longer exists: " + path)
    if reveal:
        subprocess.run(["open", "-R", path], check=True)
        return
    subprocess.run(["open", path], check=True)


class LumosHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/search":
            self.handle_search(parsed)
            return
        if parsed.path == "/api/status":
            self.write_json(200, status_payload())
            return
        self.serve_static(parsed.path)

    def do_POST(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
        payload = json.loads(body) if body else {}
        if parsed.path == "/api/open":
            try:
                open_path(payload.get("path", ""), False)
                self.write_json(200, {"ok": True})
            except Exception as error:
                self.write_json(400, {"error": str(error)})
            return
        if parsed.path == "/api/reveal":
            try:
                open_path(payload.get("path", ""), True)
                self.write_json(200, {"ok": True})
            except Exception as error:
                self.write_json(400, {"error": str(error)})
            return
        self.write_json(404, {"error": "Not found"})

    def handle_search(self, parsed):
        query = parse_qs(parsed.query)
        text = query.get("q", [""])[0]
        limit = int(query.get("limit", ["200"])[0])
        offset = int(query.get("offset", ["0"])[0])
        show_hidden = query.get("hidden", ["0"])[0] == "1"
        if limit < 1 or limit > 500:
            self.write_json(400, {"error": "limit must be between 1 and 500"})
            return
        try:
            results, count, elapsed_ms = search(text, limit, offset, show_hidden)
            self.write_json(
                200,
                {
                    "results": results,
                    "objects": count,
                    "elapsed_ms": elapsed_ms,
                    "limit": limit,
                    "offset": offset,
                },
            )
        except Exception as error:
            self.write_json(500, {"error": str(error)})

    def serve_static(self, path):
        relative = unquote(path)
        if relative == "/":
            relative = "/index.html"
        root = web_dir().resolve()
        target = (root / relative.lstrip("/")).resolve()
        if not str(target).startswith(str(root)) or not target.is_file():
            self.write_json(404, {"error": "Not found"})
            return
        content_type = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        data = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def write_json(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


def main():
    parser = argparse.ArgumentParser(description="Lumos local search server")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--open", action="store_true")
    parser.add_argument("--no-index", action="store_true")
    args = parser.parse_args()
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    if not args.no_index:
        start_indexer()
    server = ThreadingHTTPServer((HOST, args.port), LumosHandler)
    url = "http://{}:{}/".format(HOST, args.port)
    sys.stderr.write("Lumos is at {}\n".format(url))
    if args.open:
        subprocess.run(["open", url], check=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
