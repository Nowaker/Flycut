"""Run: python3 -m SyncService.server --help (Python 3.10+, stdlib only)."""

import argparse
import hmac
import ipaddress
import json
import os
import sqlite3
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from SyncService.protocol import Failure, JSON, PROTOCOL, parse_batch, parse_json, uuid_string
from SyncService.storage import Store


def load_grants(path: Path, collections: tuple[str, ...]) -> dict[str, tuple[str, ...]]:
    if path.name != ".env":
        raise Failure(400, "auth_file_must_be_dotenv")
    if path.stat().st_mode & 0o077:
        raise Failure(400, "auth_file_requires_mode_600")
    lines = path.read_text(encoding="utf-8").splitlines()
    entries = [line.removeprefix("FLYCUT_SYNC_GRANTS=").strip() for line in lines if line.startswith("FLYCUT_SYNC_GRANTS=")]
    if len(entries) != 1:
        raise Failure(400, "missing_or_duplicate_grants")
    text = entries[0]
    if text.startswith("'") and text.endswith("'"):
        text = text[1:-1]
    raw = parse_json(text)
    if not isinstance(raw, dict) or not raw:
        raise Failure(400, "invalid_grants")
    grants: dict[str, tuple[str, ...]] = {}
    for token, allowed in raw.items():
        if len(token) < 32 or not token.isascii() or any(c.isspace() for c in token):
            raise Failure(400, "invalid_grants")
        if not isinstance(allowed, list) or not allowed:
            raise Failure(400, "invalid_grants")
        ids = tuple(uuid_string(value) for value in allowed)
        if not set(ids) <= set(collections):
            raise Failure(400, "grant_collection_not_configured")
        grants[token] = ids
    return grants


def manifest(collection: str) -> dict[str, JSON]:
    return {"protocol": PROTOCOL, "version": 1, "collection_id": collection}


def handler(store: Store, grants: dict[str, tuple[str, ...]]) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "FlycutSync/1"

        def log_message(self, format: str, *args: str) -> None:
            # HTTP paths, bodies, headers and exception details must never enter logs.
            return

        def setup(self) -> None:
            super().setup()
            self.connection.settimeout(15)

        def respond(self, status: int, body: dict[str, JSON]) -> None:
            encoded = json.dumps(body, ensure_ascii=True, allow_nan=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Cache-Control", "no-store")
            if status == 401:
                self.send_header("WWW-Authenticate", "Bearer")
            self.end_headers()
            self.wfile.write(encoded)

        def do_GET(self) -> None:
            self.dispatch()

        def do_POST(self) -> None:
            self.dispatch()

        def dispatch(self) -> None:
            try:
                headers = self.headers.get_all("Authorization", [])
                if len(headers) != 1 or not headers[0].startswith("Bearer "):
                    raise Failure(401, "unauthenticated")
                token = headers[0][7:]
                allowed: tuple[str, ...] = ()
                for secret, collections in grants.items():
                    if hmac.compare_digest(token.encode("utf-8"), secret.encode("ascii")):
                        allowed = collections
                if not allowed:
                    raise Failure(401, "unauthenticated")
                url = urlsplit(self.path)
                parts = url.path.split("/")
                if url.path == "/v1/collections" and self.command == "GET" and not url.query:
                    self.respond(200, {"collections": [manifest(c) for c in sorted(allowed)]})
                    return
                if len(parts) not in (4, 5) or parts[:3] != ["", "v1", "collections"]:
                    raise Failure(404, "not_found")
                collection = uuid_string(parts[3])
                if collection not in allowed:
                    raise Failure(403, "unauthorized_collection")
                if len(parts) == 4 and self.command == "GET" and not url.query:
                    self.respond(200, manifest(collection))
                    return
                if len(parts) != 5 or parts[4] != "events":
                    raise Failure(404, "not_found")
                if self.command == "POST":
                    if url.query or self.headers.get_content_type() != "application/json" or self.headers.get("Transfer-Encoding"):
                        raise Failure(400, "invalid_request")
                    lengths = self.headers.get_all("Content-Length", [])
                    if len(lengths) != 1 or not lengths[0].isascii() or not lengths[0].isdigit():
                        raise Failure(411, "content_length_required")
                    size = int(lengths[0])
                    if not 1 <= size <= 8 * 1024 * 1024:
                        raise Failure(413, "batch_too_large")
                    raw = self.rfile.read(size)
                    if len(raw) != size:
                        raise Failure(400, "incomplete_body")
                    events = parse_batch(raw, collection)
                    inserted = store.ingest(events)
                    self.respond(200, {"accepted": len(events), "inserted": inserted})
                    return
                query = parse_qs(url.query, keep_blank_values=True, max_num_fields=2)
                if set(query) - {"after", "limit"} or any(len(v) != 1 for v in query.values()):
                    raise Failure(400, "invalid_query")
                after = query.get("after", [""])[0]
                limit_text = query.get("limit", ["200"])[0]
                if not limit_text.isascii() or not limit_text.isdigit() or len(limit_text) > 4:
                    raise Failure(400, "invalid_limit")
                limit = int(limit_text)
                if not 1 <= limit <= 1000 or len(after) > 256:
                    raise Failure(400, "invalid_query")
                self.respond(200, store.page(collection, after, limit))
            except Failure as error:
                body: dict[str, JSON] = {"error": error.code}
                if error.code == "invalid_cursor":
                    body["replay_required"] = True
                self.respond(error.status, body)
            except ValueError:
                self.respond(400, {"error": "invalid_request"})
            except sqlite3.Error:
                self.respond(503, {"error": "storage_unavailable"})
            except (OSError, TimeoutError):
                self.close_connection = True

    return Handler


def main() -> int:
    parser = argparse.ArgumentParser(description="Authenticated immutable Flycut event sync (stdlib Python 3.10+).",
        epilog="Provision: --collection UUID (repeatable). Configure root .env mode 600 with FLYCUT_SYNC_GRANTS='{" +
        '\"<random-bearer-token-32+-characters>\":[\"<collection-uuid>\"]}' +
        "'. GET /v1/collections discovers authorized manifests. POST events accepts 1..1000 events / 8 MiB. " +
        "GET events pages after opaque cursor, limit 1..1000 (default 200). Invalid cursor: explicitly replay without after. " +
        "Put TLS reverse proxy in front for public deployment; disable proxy body/header logging. " +
        "Back up SQLite using its online backup API, not by copying a live database. Never prune events/tombstones.")
    parser.add_argument("--bind", default="127.0.0.1", help="IPv4 address; defaults to loopback, never wildcard")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--database", type=Path, required=True, help="Persistent SQLite path, parent must exist")
    parser.add_argument("--env-file", type=Path, default=Path(".env"), help="Root .env containing token grants (mode 600)")
    parser.add_argument("--collection", action="append", required=True, help="Provisioned lowercase UUID; repeat for each collection")
    parser.add_argument("--secured-tailnet", action="store_true", help="Explicitly allow binding a secured tailnet IPv4 address")
    parser.add_argument("--rotate-cursor-identity", action="store_true", help="After restoring a backup, run while service is stopped; invalidate old cursors and exit")
    args = parser.parse_args()
    try:
        address = ipaddress.IPv4Address(args.bind)
        if address.is_unspecified or not (address.is_loopback or (args.secured_tailnet and address in ipaddress.IPv4Network("100.64.0.0/10"))):
            raise Failure(400, "bind_requires_loopback_or_secured_tailnet")
        if not 0 <= args.port <= 65535:
            raise Failure(400, "invalid_port")
        collections = tuple(uuid_string(value) for value in args.collection)
        grants = load_grants(args.env_file, collections)
        os.umask(0o077)
        store = Store(args.database, collections)
        if args.rotate_cursor_identity:
            store.rotate_cursor_identity()
            print("Cursor identity rotated; clients must explicitly replay.")
            return 0
        with ThreadingHTTPServer((str(address), args.port), handler(store, grants)) as server:
            print(f"Flycut sync listening on {address}:{server.server_port}", flush=True)
            server.serve_forever()
    except (Failure, OSError, ValueError, sqlite3.Error) as error:
        code = error.code if isinstance(error, Failure) else "startup_failed"
        print(f"Flycut sync: {code}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
