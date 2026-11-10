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
- Credentials (credential-rules.json, shared with Flycut, kept next to this script) are sealed in the
  server log and in this bridge's state, with keys derived from the server token, as Flycut does
  (FlycutEngine/FlycutSyncCrypto.h). Sealing uses the `cryptography` package (python-cryptography).

Usage: flycut-copyq-bridge.py --server http://desktop.example.ts.net:8742 --token-file ~/.local/share/flycut-sync-server/token
"""

import argparse
import base64
import hashlib
import hmac
import json
import logging
import math
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
from collections import Counter

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


def shannon_entropy(text):
    counts = Counter(text)
    return -sum(n / len(text) * math.log2(n / len(text)) for n in counts.values()) if text else 0.0


class CredentialDetector:
    """credential-rules.json, applied as FlycutCredentialDetector.m does."""

    def __init__(self, path):
        with open(path, encoding="utf-8") as f:
            config = json.load(f)
        self.version = config["version"]
        self.scan_limit = config.get("scanLimit", 65536)
        self.rules = [(rule["id"], re.compile(rule["regex"]), rule.get("keywords", []), rule.get("entropy", 0),
                       [re.compile(allow) for allow in rule.get("allowSecret", [])]) for rule in config["rules"]]
        self.standalone = config.get("standalone")
        self.allow = [re.compile(allow) for allow in self.standalone.get("allow", [])] if self.standalone else []

    def lone_random_word(self, word):
        s = self.standalone
        if not s["minLength"] <= len(word) <= s["maxLength"] or any(c.isspace() for c in word):
            return False
        if any(allow.search(word) for allow in self.allow):
            return False
        lower = any("a" <= c <= "z" for c in word)
        upper = any("A" <= c <= "Z" for c in word)
        digit = any("0" <= c <= "9" for c in word)
        other = any(not c.isascii() or not c.isalnum() for c in word)
        token_characters_only = all(c.isascii() and (c.isalnum() or c in "_+/=.-") for c in word)
        digit_runs = len(re.findall(r"[0-9]+", word))
        longest_run = max((len(run) for run in re.findall(r"[A-Za-z0-9]+", word)), default=0)
        entropy = shannon_entropy(word)
        if lower and upper and digit and other and entropy >= s["passwordEntropy"]:
            return True
        return (token_characters_only and (lower or upper) and digit and len(word) >= s["tokenMinLength"]
                and digit_runs >= s["tokenDigitRuns"] and longest_run >= s["tokenLongestRun"]
                and entropy >= s["tokenEntropy"])

    def rule_in(self, text):
        text = text[:self.scan_limit].strip()
        if not text:
            return None
        lowercase = text.lower()
        for rule_id, regex, keywords, entropy, allow_secret in self.rules:
            if keywords and not any(keyword in lowercase for keyword in keywords):
                continue
            for match in regex.finditer(text):
                secret = match.group(1) if regex.groups and match.group(1) is not None else match.group(0)
                if entropy and shannon_entropy(secret) < entropy:
                    continue
                if not any(allow.search(secret) for allow in allow_secret):
                    return rule_id
        if self.standalone and self.lone_random_word(text):
            return "standalone"
        return None

    def is_credential(self, text):
        return self.rule_in(text) is not None


class SyncCrypto:
    """The sealed format of FlycutEngine/FlycutSyncCrypto.h: "v1:" + base64(nonce || AES-256-CTR || HMAC-SHA256)."""

    def __init__(self, token):
        prk = hmac.new(b"flycut-sync", token.encode("utf-8"), hashlib.sha256).digest()
        okm, block = b"", b""
        for counter in (1, 2):
            block = hmac.new(prk, block + b"clipping contents v1" + bytes([counter]), hashlib.sha256).digest()
            okm += block
        self.encryption_key, self.mac_key = okm[:32], okm[32:]

    def _ctr(self, nonce, data):
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        cryptor = Cipher(algorithms.AES(self.encryption_key), modes.CTR(nonce)).encryptor()
        return cryptor.update(data) + cryptor.finalize()

    def _tag(self, nonce, ciphertext):
        return hmac.new(self.mac_key, b"flycut-v1" + nonce + ciphertext, hashlib.sha256).digest()

    def seal(self, plaintext):
        nonce = os.urandom(16)
        ciphertext = self._ctr(nonce, plaintext.encode("utf-8"))
        return "v1:" + base64.b64encode(nonce + ciphertext + self._tag(nonce, ciphertext)).decode("ascii")

    def open(self, sealed):
        if not isinstance(sealed, str) or not sealed.startswith("v1:"):
            return None
        try:
            data = base64.b64decode(sealed[3:], validate=True)
        except ValueError:
            return None
        if len(data) < 48:
            return None
        nonce, ciphertext, tag = data[:16], data[16:-32], data[-32:]
        if not hmac.compare_digest(tag, self._tag(nonce, ciphertext)):
            return None
        try:
            return self._ctr(nonce, ciphertext).decode("utf-8")
        except UnicodeDecodeError:
            return None


class CopyQ:
    """A CopyQ tab, driven through `copyq eval`."""

    TOP = """tab(arguments[1]);
var out = [], n = Math.min(size(), Number(arguments[2]));
for (var i = 0; i < n; i++) out.push(str(read("text/plain", i)));
print(JSON.stringify(out));"""

    # Clippings go in on stdin: CopyQ rewrites backslash escapes in command-line arguments, which breaks JSON.
    # Inserts [{text, top}] (oldest first) unless one of the tab's top rows already holds the text.
    INSERT = """tab(arguments[1]);
var items = JSON.parse(str(input())), seen = {}, n = Math.min(size(), Number(arguments[2])), added = [];
for (var i = 0; i < n; i++) seen[str(read("text/plain", i))] = true;
for (var j = 0; j < items.length; j++) {
    if (seen[items[j].text]) continue;
    insert(items[j].top ? 0 : size(), items[j].text);
    seen[items[j].text] = true;
    added.push(items[j].text);
}
print(JSON.stringify(added));"""

    REMOVE = """tab(arguments[1]);
var wanted = {}, texts = JSON.parse(str(input())), rows = [];
for (var j = 0; j < texts.length; j++) wanted[texts[j]] = true;
var n = Math.min(size(), Number(arguments[2]));
for (var i = 0; i < n; i++) {
    var t = str(read("text/plain", i));
    if (wanted[t]) { rows.push(i); delete wanted[t]; }
}
for (var k = rows.length - 1; k >= 0; k--) remove(rows[k]);
print(JSON.stringify(rows.length));"""

    def __init__(self, tab):
        self.tab = tab

    def eval(self, script, *args, stdin=None):
        result = subprocess.run(["copyq", "eval", script, *map(str, args)], input=stdin,
                                capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            raise RuntimeError(f"copyq eval failed: {result.stderr.strip()[:200]}")
        return json.loads(result.stdout)

    def top(self, rows=WATCHED_ROWS):
        return [text or None for text in self.eval(self.TOP, self.tab, rows)]

    def insert(self, items):
        return self.eval(self.INSERT, self.tab, DEDUPE_ROWS, stdin=json.dumps(items)) if items else []

    def remove(self, texts):
        return self.eval(self.REMOVE, self.tab, SEARCH_ROWS, stdin=json.dumps(sorted(texts))) if texts else 0


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
            token = f.read().strip()
        self.server = Server(args.server, token)
        self.crypto = SyncCrypto(token)
        self.detector = CredentialDetector(os.path.expanduser(args.rules))
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
        self.seal_own_log()

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
        row = self.db.execute("SELECT at, machine, deleted, contents FROM clips WHERE id = ?", (clip_id,)).fetchone()
        if row and row[3] and row[3].startswith("v1:"):
            row = (*row[:3], self.crypto.open(row[3]))
        return row

    def live_id_for(self, text):
        row = self.db.execute("SELECT id FROM clips WHERE hash = ? AND deleted = 0 ORDER BY at DESC LIMIT 1",
                              (digest(text),)).fetchone()
        return row[0] if row else None

    # Credentials are kept sealed here too, so neither this state nor the server log shows them.
    def set_clip(self, clip_id, at, machine, deleted, contents):
        stored = self.crypto.seal(contents) if contents and self.detector.is_credential(contents) else contents
        self.db.execute("INSERT OR REPLACE INTO clips (id, at, machine, deleted, hash, contents) VALUES (?, ?, ?, ?, ?, ?)",
                        (clip_id, at, machine, 1 if deleted else 0, digest(contents) if contents else None, stored))

    def seal_event(self, event):
        text = event.get("contents")
        if not isinstance(text, str) or not self.detector.is_credential(text):
            return False
        event["enc"] = self.crypto.seal(text)
        del event["contents"]
        return True

    # Seals credentials this bridge shared in plain text before, once per rules version, as Flycut does, and
    # makes the next upload replace the server's copy.
    def seal_own_log(self):
        done_key = f"sealed:{self.detector.version}"
        if self.meta(done_key) is not None:
            return
        sealed, lines = 0, []
        try:
            with open(self.own_log, encoding="utf-8") as f:
                for line in f:
                    line = line.rstrip("\n")
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                    except ValueError:
                        lines.append(line)
                        continue
                    if isinstance(event, dict) and event.get("op") == "put" and self.seal_event(event):
                        sealed += 1
                        line = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
                    lines.append(line)
        except FileNotFoundError:
            pass
        if sealed:
            temporary = self.own_log + ".rewriting"
            with open(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8") as f:
                f.write("".join(line + "\n" for line in lines))
            os.replace(temporary, self.own_log)
            self.set_meta("sent", "-1")
        for row in self.db.execute("SELECT id, at, machine, deleted, contents FROM clips").fetchall():
            if row[4] and not row[4].startswith("v1:") and self.detector.is_credential(row[4]):
                self.set_clip(*row)
        self.set_meta(done_key, str(sealed))
        self.db.commit()
        if sealed:
            log.info("sealed %d credential clipping(s) in %s", sealed, self.own_log)

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
        self.seal_event(event)
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
                if text is None and "enc" in event:
                    text = self.crypto.open(event["enc"])
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
    parser.add_argument("--server", required=True, help="flycut-sync-server address, e.g. http://desktop.example.ts.net:8742")
    parser.add_argument("--token-file", required=True, help="file holding the server's bearer token")
    parser.add_argument("--tab", default=None, help="CopyQ tab to sync (default: CopyQ's clipboard tab)")
    parser.add_argument("--state-dir", default="~/.local/share/flycut-copyq-bridge")
    parser.add_argument("--rules", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "credential-rules.json"),
                        help="credential rules shared with Flycut (default: credential-rules.json next to this script)")
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
