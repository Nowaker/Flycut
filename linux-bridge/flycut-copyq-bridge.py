#!/usr/bin/env python3
"""Shares a Linux machine's CopyQ clipboard history with Flycut through flycut-sync-server.

The bridge is one more machine in the sync: it appends put/del events to its own log on the
server, in the same JSON-lines format Flycut writes, and applies the other machines' events to a
CopyQ tab. For every clipping the event with the greatest (at, machine) wins, as in Flycut.

What it does and doesn't carry, given what CopyQ offers:
- A text newly copied on this machine, or copied again, is shared as the newest clipping.
- A clipping copied elsewhere is inserted into the tab: on top if it was copied within the last
  hour, at the bottom if it is older (on first sync with a long Mac history).
- A clipping deleted elsewhere is removed from the tab if it is among its top rows.
- Favorites, images and other non-text items are not synced. CopyQ's own ordering of older items
  is left alone. Deleting an item in CopyQ isn't shared.
- Only the tab's top rows are read: CopyQ reads its items one by one, about 0.7 ms each.

Usage: flycut-copyq-bridge.py --server http://100.x.y.z:8742 --token-file ~/.local/share/flycut-sync-server/token
"""

import argparse
import hashlib
import json
import logging
import os
import re
import socket
import sqlite3
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

TAIL = 32  # bytes of a log kept to recognise it was rewritten
WATCHED_ROWS = 20  # top rows compared between polls to find new copies
DEDUPE_ROWS = 500  # top rows checked before inserting a clipping CopyQ already has
SEARCH_ROWS = 5000  # rows searched for a clipping to remove
RECENT_SECONDS = 3600
MAX_TEXT = 1_000_000
HISTORY_LIST = 0

log = logging.getLogger("flycut-copyq-bridge")


def now_ms():
    return int(time.time() * 1000)


def newer(at, machine, other_at, other_machine):
    if at != other_at:
        return at > other_at
    return (machine or "") > (other_machine or "")


def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class CopyQ:
    """A CopyQ tab, driven through `copyq eval`."""

    TOP = """tab(arguments[1]);
var out = [], n = Math.min(size(), Number(arguments[2]));
for (var i = 0; i < n; i++) out.push(str(read("text/plain", i)));
print(JSON.stringify(out));"""

    # Inserts [{text, top}] (oldest first) unless one of the tab's top rows already holds the text.
    INSERT = """tab(arguments[1]);
var items = JSON.parse(arguments[2]), seen = {}, n = Math.min(size(), Number(arguments[3])), added = [];
for (var i = 0; i < n; i++) seen[str(read("text/plain", i))] = true;
for (var j = 0; j < items.length; j++) {
    if (seen[items[j].text]) continue;
    insert(items[j].top ? 0 : size(), items[j].text);
    seen[items[j].text] = true;
    added.push(items[j].text);
}
print(JSON.stringify(added));"""

    REMOVE = """tab(arguments[1]);
var wanted = {}, texts = JSON.parse(arguments[2]), rows = [];
for (var j = 0; j < texts.length; j++) wanted[texts[j]] = true;
var n = Math.min(size(), Number(arguments[3]));
for (var i = 0; i < n; i++) {
    var t = str(read("text/plain", i));
    if (wanted[t]) { rows.push(i); delete wanted[t]; }
}
for (var k = rows.length - 1; k >= 0; k--) remove(rows[k]);
print(JSON.stringify(rows.length));"""

    def __init__(self, tab):
        self.tab = tab

    def eval(self, script, *args):
        result = subprocess.run(["copyq", "eval", script, *map(str, args)],
                                capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            raise RuntimeError(f"copyq eval failed: {result.stderr.strip()[:200]}")
        return json.loads(result.stdout)

    def top(self, rows=WATCHED_ROWS):
        return [text or None for text in self.eval(self.TOP, self.tab, rows)]

    def insert(self, items):
        return self.eval(self.INSERT, self.tab, json.dumps(items), DEDUPE_ROWS) if items else []

    def remove(self, texts):
        return self.eval(self.REMOVE, self.tab, json.dumps(sorted(texts)), SEARCH_ROWS) if texts else 0


class Server:
    def __init__(self, url, token):
        self.url = url.rstrip("/")
        self.token = token

    def request(self, method, path, body=None, headers=None):
        req = urllib.request.Request(self.url + path, data=body, method=method)
        req.add_header("Authorization", "Bearer " + self.token)
        for name, value in (headers or {}).items():
            req.add_header(name, value)
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                return resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as err:
            return err.code, err.headers, err.read()


class Bridge:
    def __init__(self, args):
        self.copyq = CopyQ(args.tab)
        with open(os.path.expanduser(args.token_file)) as f:
            self.server = Server(args.server, f.read().strip())
        self.state_dir = os.path.expanduser(args.state_dir)
        os.makedirs(self.state_dir, mode=0o700, exist_ok=True)
        self.db = sqlite3.connect(os.path.join(self.state_dir, "state.sqlite"))
        os.chmod(os.path.join(self.state_dir, "state.sqlite"), 0o600)
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS clips (id TEXT PRIMARY KEY, at INTEGER NOT NULL, machine TEXT NOT NULL,
                deleted INTEGER NOT NULL, hash TEXT, contents TEXT);
            CREATE INDEX IF NOT EXISTS clips_by_hash ON clips (hash);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        """)
        self.machine = self.meta("machine") or self.create_machine_id()
        self.own_log = os.path.join(self.state_dir, self.machine + ".jsonl")
        self.last_local_at = 0
        self.watched = None
        self.just_inserted = set()
        self.export_existing = args.export_existing
        self.last_error = None

    # State

    def meta(self, key):
        row = self.db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return row[0] if row else None

    def set_meta(self, key, value):
        self.db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", (key, value))

    def create_machine_id(self):
        host = re.sub(r"[^a-z0-9-]", "", socket.gethostname().split(".")[0].lower()) or "linux"
        machine = f"{host}-copyq-{uuid.uuid4().hex[:8]}"
        self.set_meta("machine", machine)
        self.db.commit()
        return machine

    def clip(self, clip_id):
        return self.db.execute("SELECT at, machine, deleted, contents FROM clips WHERE id = ?", (clip_id,)).fetchone()

    def live_id_for(self, text):
        row = self.db.execute("SELECT id FROM clips WHERE hash = ? AND deleted = 0 ORDER BY at DESC LIMIT 1",
                              (digest(text),)).fetchone()
        return row[0] if row else None

    def set_clip(self, clip_id, at, machine, deleted, contents):
        self.db.execute("INSERT OR REPLACE INTO clips (id, at, machine, deleted, hash, contents) VALUES (?, ?, ?, ?, ?, ?)",
                        (clip_id, at, machine, 1 if deleted else 0, digest(contents) if contents else None, contents))

    def clear_marker(self):
        parts = (self.meta("clear") or "").split(" ", 1)
        return (int(parts[0]), parts[1]) if len(parts) == 2 else (0, "")

    # Local copies

    def next_local_at(self, seen):
        self.last_local_at = max(now_ms(), seen + 1, self.last_local_at + 1)
        return self.last_local_at

    def share_copy(self, text):
        clip_id = self.live_id_for(text) or str(uuid.uuid4()).upper()
        known = self.clip(clip_id)
        at = self.next_local_at(max(known[0] if known else 0, self.clear_marker()[0]))
        self.set_clip(clip_id, at, self.machine, False, text)
        host = socket.gethostname().split(".")[0]
        event = {"v": 1, "op": "put", "list": HISTORY_LIST, "id": clip_id, "at": at, "m": self.machine,
                 "rank": time.time(), "contents": text, "type": "NSStringPboardType", "app": host,
                 "ts": int(time.time())}
        with open(self.own_log, "a", encoding="utf-8") as f:
            f.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
        os.chmod(self.own_log, 0o600)

    # New items above the previous top are new copies. An item that was lower and is now right above the
    # previous top was copied again (CopyQ moves it up). "Previous top" is the first earlier row still in
    # the tab, since the bridge or the user may have removed rows in between. Items the bridge itself
    # inserted are skipped.
    def poll_copyq(self):
        rows = self.copyq.top()
        if self.watched is None:
            self.watched = rows
            if self.meta("exported") is None:
                for text in reversed(rows[:self.export_existing]):
                    if text and len(text) <= MAX_TEXT:
                        self.share_copy(text)
                self.set_meta("exported", str(min(self.export_existing, len(rows))))
            return
        if rows == self.watched:
            return
        previous = set(t for t in self.watched if t)
        present = set(rows)
        still_there = [t for t in self.watched if t in present]
        copied = []
        for i, text in enumerate(rows):
            if text in previous:
                if still_there and text != still_there[0] and i + 1 < len(rows) and rows[i + 1] == still_there[0]:
                    copied.append(text)
                break
            copied.append(text)
        for text in reversed(copied):
            if not text or len(text) > MAX_TEXT:
                continue
            if text in self.just_inserted:
                self.just_inserted.discard(text)
                continue
            self.share_copy(text)
        self.watched = rows

    # Other machines

    def apply_events(self, events, inserts, removals):
        for event in events:
            if not isinstance(event, dict) or event.get("v") != 1 or event.get("list") != HISTORY_LIST:
                continue
            machine, at, op = event.get("m"), event.get("at"), event.get("op")
            if not isinstance(machine, str) or machine == self.machine or not isinstance(at, int):
                continue
            cleared = self.clear_marker()
            if op == "clear":
                if not newer(at, machine, *cleared):
                    continue
                self.set_meta("clear", f"{at} {machine}")
                for clip_id, clip_at, clip_machine, contents in self.db.execute(
                        "SELECT id, at, machine, contents FROM clips WHERE deleted = 0").fetchall():
                    if newer(at, machine, clip_at, clip_machine):
                        self.set_clip(clip_id, clip_at, clip_machine, True, contents)
                        inserts.pop(clip_id, None)
                        removals.add(contents)
                continue
            clip_id = event.get("id")
            if not isinstance(clip_id, str) or not clip_id or not newer(at, machine, *cleared):
                continue
            known = self.clip(clip_id)
            if known and not newer(at, machine, known[0], known[1]):
                continue
            if op == "put":
                text = event.get("contents")
                if not isinstance(text, str) or not text or len(text) > MAX_TEXT:
                    continue
                self.set_clip(clip_id, at, machine, False, text)
                removals.discard(text)
                inserts[clip_id] = (float(event.get("rank") or 0), text)
            elif op == "del":
                contents = known[3] if known else None
                self.set_clip(clip_id, at, machine, True, contents)
                inserts.pop(clip_id, None)
                if contents and not self.live_id_for(contents):
                    removals.add(contents)

    def fetch_log(self, machine, size):
        position = (self.meta("read:" + machine) or "").split(" ")
        offset = int(position[0]) if len(position) == 2 else 0
        tail = bytes.fromhex(position[1]) if len(position) == 2 else b""
        if offset == size:
            return None
        start = offset - len(tail) if offset <= size else 0
        status, headers, data = self.server.request("GET", f"/v1/logs/{urllib.parse.quote(machine)}?from={start}")
        if status != 200 or int(headers.get("X-Log-Size", -1)) != start + len(data):
            return None
        if start > 0 and data[:len(tail)] != tail:
            # Rewritten (compacted) since the last read: read it all again; applying an event twice changes nothing.
            start = 0
            status, headers, data = self.server.request("GET", f"/v1/logs/{urllib.parse.quote(machine)}?from=0")
            if status != 200 or int(headers.get("X-Log-Size", -1)) != len(data):
                return None
        end = data.rfind(b"\n") + 1
        if end <= (len(tail) if start > 0 else 0):
            return None
        events = []
        for line in data[len(tail) if start > 0 else 0:end].split(b"\n"):
            if line:
                try:
                    events.append(json.loads(line))
                except ValueError:
                    log.warning("skipping an unreadable line in %s", machine)
        self.set_meta("read:" + machine, f"{start + end} {data[max(0, end - TAIL):end].hex()}")
        return events

    def upload_own_log(self, server_size):
        try:
            with open(self.own_log, "rb") as f:
                local = f.read()
        except FileNotFoundError:
            return
        local = local[:local.rfind(b"\n") + 1]
        sent = int(self.meta("sent") or -1)
        if server_size == len(local) == sent:
            return
        path = f"/v1/logs/{urllib.parse.quote(self.machine)}"
        status = None
        if server_size == sent and 0 <= sent < len(local):
            status, _, _ = self.server.request("POST", path, local[sent:], {"X-Log-Offset": str(sent)})
        if status != 204:
            status, _, body = self.server.request("PUT", path, local)
            if status != 204:
                raise RuntimeError(f"upload failed: HTTP {status} {body[:100]!r}")
        self.set_meta("sent", str(len(local)))

    def sync_server(self):
        status, _, body = self.server.request("GET", "/v1/logs")
        if status == 401:
            raise RuntimeError("the server refused the token")
        if status != 200:
            raise RuntimeError(f"unexpected answer from the server: HTTP {status}")
        inserts, removals = {}, set()
        own_size = -1
        for entry in json.loads(body):
            machine, size = entry.get("machine"), entry.get("size", 0)
            if machine == self.machine:
                own_size = size
                continue
            events = self.fetch_log(machine, size)
            if events:
                self.apply_events(events, inserts, removals)
        self.upload_own_log(own_size)

        if removals:
            log.info("removing %d clipping(s) deleted elsewhere", self.copyq.remove(removals))
        if inserts:
            recent = time.time() - RECENT_SECONDS
            ordered = sorted(inserts.values(), key=lambda item: item[0])
            items = [{"text": text, "top": rank >= recent} for rank, text in ordered]
            added = self.copyq.insert(items)
            self.just_inserted.update(set(added) & {item["text"] for item in items if item["top"]})
            log.info("inserted %d clipping(s) from other machines", len(added))
        self.db.commit()

    def run(self, interval):
        log.info("bridging CopyQ tab %r as %s with %s", self.copyq.tab, self.machine, self.server.url)
        while True:
            try:
                self.poll_copyq()
                self.db.commit()
                self.sync_server()
                if self.last_error:
                    log.info("working again")
                self.last_error = None
            except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as err:
                if str(err) != self.last_error:
                    log.error("%s", err)
                self.last_error = str(err)
                self.db.rollback()
            time.sleep(interval)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--server", required=True, help="flycut-sync-server address, e.g. http://100.x.y.z:8742")
    parser.add_argument("--token-file", required=True, help="file holding the server's bearer token")
    parser.add_argument("--tab", default=None, help="CopyQ tab to sync (default: CopyQ's clipboard tab)")
    parser.add_argument("--state-dir", default="~/.local/share/flycut-copyq-bridge")
    parser.add_argument("--interval", type=float, default=2.0, help="seconds between checks")
    parser.add_argument("--export-existing", type=int, default=0, metavar="N",
                        help="on the very first run, also share the tab's top N items (at most %d)" % WATCHED_ROWS)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    if args.tab is None:
        args.tab = json.loads(subprocess.run(["copyq", "eval", 'print(JSON.stringify(config("clipboard_tab")))'],
                                             capture_output=True, text=True, check=True).stdout)
    Bridge(args).run(args.interval)


if __name__ == "__main__":
    main()
