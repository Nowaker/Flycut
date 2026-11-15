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
- Every format of an item travels, not only its text: HTML, images, an app's own formats. Their data is
  stored on the server as blobs (/v1/blobs/<machine>/<sha256>), uploaded before the line that refers to
  them; MIME types are mapped to the macOS pasteboard types Flycut uses and back. An item without text
  (an image) is labelled the way Flycut labels it, e.g. "[image: PNG, 1920×1080, 1.2 MB]".
- Favorites are not synced. CopyQ's own ordering of older items is left alone. Deleting an item in
  CopyQ isn't shared.
- Only the tab's top rows are read: CopyQ reads its items one by one, about 0.7 ms each. Items are told
  apart by their text, or without text by the SHA-256 of their first format (by name).
- Credentials (credential-rules.json, shared with Flycut, kept next to this script) are sealed in the
  server log and in this bridge's state, with keys derived from the server token, as Flycut does
  (FlycutEngine/FlycutSyncCrypto.h), and so is a credential's pasteboard data. Sealing uses the `cryptography`
  package (python-cryptography).

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
MAX_ITEM_BYTES = 64 << 20  # an item's formats beyond this are dropped, largest first, never its text
UNREFERENCED_BLOB_SECONDS = 600
HISTORY_LIST = 0

# CopyQ's MIME formats and the macOS pasteboard types Flycut stores. Other formats travel under their MIME
# name; macOS types without a MIME equivalent (and the redundant text encodings) don't go into CopyQ.
MIME_TO_UTI = {
    "text/plain": "public.utf8-plain-text", "text/html": "public.html", "text/rtf": "public.rtf",
    "application/rtf": "public.rtf", "image/png": "public.png", "image/jpeg": "public.jpeg",
    "image/gif": "com.compuserve.gif", "image/tiff": "public.tiff", "image/bmp": "com.microsoft.bmp",
    "image/webp": "org.webmproject.webp", "image/svg+xml": "public.svg-image", "image/heic": "public.heic",
    "application/pdf": "com.adobe.pdf",
}
UTI_TO_MIME = {uti: mime for mime, uti in MIME_TO_UTI.items() if mime != "application/rtf"}
IMAGE_NAMES = {"image/png": "PNG", "image/jpeg": "JPEG", "image/gif": "GIF", "image/tiff": "TIFF", "image/bmp": "BMP",
               "image/webp": "WEBP", "image/svg+xml": "SVG", "image/heic": "HEIC"}
INTERNAL_FORMAT = "application/x-copyq-"
BLOB_NAME = re.compile(r"^[0-9a-f]{64}$")

log = logging.getLogger("flycut-copyq-bridge")


def now_ms():
    return int(time.time() * 1000)


def newer(at, machine, other_at, other_machine):
    if at != other_at:
        return at > other_at
    return (machine or "") > (other_machine or "")


def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def item_key(formats):
    """What tells CopyQ items apart, as CopyQ.KEY computes it: the text, or the hash of the first format."""
    text = formats.get("text/plain")
    if text:
        return text.decode("utf-8", "replace")
    names = sorted(name for name in formats if not name.startswith(INTERNAL_FORMAT))
    return "\x01" + sha256_hex(formats[names[0]]) if names else ""


def blob_addresses(lines):
    addresses = set()
    for line in lines.split(b"\n"):
        if b'"items"' not in line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        for item in event.get("items") or []:
            for representation in item if isinstance(item, list) else []:
                if isinstance(representation, dict) and BLOB_NAME.match(str(representation.get("b", ""))):
                    addresses.add(representation["b"])
    return addresses


def byte_count(n):
    """As macOS writes file sizes (NSByteCountFormatter, file style), so labels read the same everywhere."""
    if n < 1000:
        return f"{n} byte" if n == 1 else f"{n} bytes"
    for unit, scale, digits in (("KB", 1e3, 0), ("MB", 1e6, 1), ("GB", 1e9, 2)):
        if n < scale * 1000 or unit == "GB":
            text = f"{n / scale:.{digits}f}"
            return f"{text.rstrip('0').rstrip('.') if '.' in text else text} {unit}"


def png_info(data):
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big"), 1
    return None


def gif_info(data):
    if data[:4] != b"GIF8" or len(data) < 13:
        return None
    width, height = int.from_bytes(data[6:8], "little"), int.from_bytes(data[8:10], "little")
    at = 13 + (3 << ((data[10] & 7) + 1) if data[10] & 0x80 else 0)
    frames = 0
    while at < len(data):
        block = data[at]
        if block == 0x2C:  # image descriptor, then an optional local colour table and LZW data
            frames += 1
            if at + 10 > len(data):
                break
            flags = data[at + 9]
            at += 10 + (3 << ((flags & 7) + 1) if flags & 0x80 else 0) + 1
        elif block == 0x21:  # extension: label, then sub-blocks
            at += 2
        elif block == 0x3B:
            break
        else:
            return width, height, max(frames, 1)
        while at < len(data) and data[at]:
            at += data[at] + 1
        at += 1
    return width, height, max(frames, 1)


STANDARD_LUMINANCE = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
                      14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
                      49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]


def jpeg_info(data):
    """Size and estimated quality, as FlycutPasteboard.m works them out (libjpeg's table scaling, inverted)."""
    if data[:2] != b"\xff\xd8":
        return None
    at, width, height, quality = 2, 0, 0, -1
    while at + 4 <= len(data) and data[at] == 0xFF:
        marker, length = data[at + 1], int.from_bytes(data[at + 2:at + 4], "big")
        if marker == 0xDB and quality < 0 and at + 69 <= len(data) and data[at + 4] >> 4 == 0:
            scale = sum(data[at + 5:at + 69]) * 100 / sum(STANDARD_LUMINANCE)
            quality = round(max(1, min(100, (200 - scale) / 2 if scale <= 100 else 5000 / scale)))
        if marker in (0xC0, 0xC1, 0xC2) and at + 9 <= len(data):
            height, width = int.from_bytes(data[at + 5:at + 7], "big"), int.from_bytes(data[at + 7:at + 9], "big")
        if marker == 0xDA:
            break
        at += 2 + length
    return width, height, quality


def describe(formats):
    """Flycut's label for an item without text: "[image: PNG, 40×30, 2 KB]"."""
    names = [name for name in formats if not name.startswith(INTERNAL_FORMAT)]
    image = next((name for name in names if name.startswith("image/")), None)
    if image:
        data = formats[image]
        parts = [IMAGE_NAMES.get(image, image.split("/", 1)[1].upper())]
        info = png_info(data) or gif_info(data) or jpeg_info(data)
        frames, quality = 1, -1
        if info and image == "image/jpeg":
            quality = info[2]
        elif info:
            frames = info[2]
        if info and info[0] and info[1]:
            parts.append(f"{info[0]}×{info[1]}")
        parts.append(byte_count(len(data)))
        if quality > 0:
            parts.append(f"~{quality}% quality")
        if frames > 1:
            parts.append(f"{frames} frames")
        return f"[image: {', '.join(parts)}]"
    if "application/pdf" in formats:
        data = formats["application/pdf"]
        pages = len(re.findall(rb"/Type\s*/Page(?![s\w])", data))
        if pages:
            return f"[PDF: {pages} page{'' if pages == 1 else 's'}, {byte_count(len(data))}]"
        return f"[PDF: {byte_count(len(data))}]"
    if "text/uri-list" in formats:
        uris = [u for u in formats["text/uri-list"].decode("utf-8", "replace").splitlines() if u and not u.startswith("#")]
        if uris:
            return " ".join(f"[file: {os.path.basename(urllib.parse.unquote(urllib.parse.urlparse(u).path))}]"
                            if u.startswith("file:") else f"[link: {u}]" for u in uris)
    if names:
        return f"[object: {names[0]}, {byte_count(len(formats[names[0]]))}]"
    return None


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

    def _seal_bytes(self, data, nonce):
        ciphertext = self._ctr(nonce, data)
        return nonce + ciphertext + self._tag(nonce, ciphertext)

    def seal(self, plaintext):
        return "v1:" + base64.b64encode(self._seal_bytes(plaintext.encode("utf-8"), os.urandom(16))).decode("ascii")

    def seal_data(self, data):
        """Blobs: unencoded, with the nonce derived from the data, so equal data seals to the same blob."""
        return self._seal_bytes(data, hmac.new(self.mac_key, b"flycut-blob-v1" + data, hashlib.sha256).digest()[:16])

    def open_data(self, data):
        if len(data) < 48:
            return None
        nonce, ciphertext, tag = data[:16], data[16:-32], data[-32:]
        if not hmac.compare_digest(tag, self._tag(nonce, ciphertext)):
            return None
        return self._ctr(nonce, ciphertext)

    def open(self, sealed):
        if not isinstance(sealed, str) or not sealed.startswith("v1:"):
            return None
        try:
            data = base64.b64decode(sealed[3:], validate=True)
        except ValueError:
            return None
        opened = self.open_data(data)
        try:
            return opened.decode("utf-8") if opened is not None else None
        except UnicodeDecodeError:
            return None


class CopyQ:
    """A CopyQ tab, driven through `copyq eval`."""

    # The same key as item_key(): an item's text, or "\\x01" + the SHA-256 of its first non-internal format.
    # No backslashes in scripts: `copyq eval` rewrites escapes in its arguments, the script included.
    KEY = """function key(i) {
    var text = str(read("text/plain", i));
    if (text) return text;
    var names = str(read("?", i)).split(String.fromCharCode(10)).filter(function (f) { return f && f.indexOf("%s") != 0; }).sort();
    return names.length ? String.fromCharCode(1) + sha256sum(read(names[0], i)) : "";
}
""" % INTERNAL_FORMAT

    TOP = KEY + """tab(arguments[1]);
var out = [], n = Math.min(size(), Number(arguments[2]));
for (var i = 0; i < n; i++) out.push(key(i));
print(JSON.stringify(out));"""

    READ = KEY + """tab(arguments[1]);
var i = Number(arguments[2]), formats = {}, names = str(read("?", i)).split(String.fromCharCode(10));
for (var j = 0; j < names.length; j++)
    if (names[j] && names[j].indexOf("%s") != 0) formats[names[j]] = str(toBase64(read(names[j], i)));
print(JSON.stringify({key: key(i), formats: formats}));""" % INTERNAL_FORMAT

    # Items go in on stdin: CopyQ rewrites backslash escapes in command-line arguments, which breaks JSON.
    # Inserts [{key, top, formats: {mime: base64}}] (oldest first) unless one of the tab's top rows has the key.
    INSERT = KEY + """tab(arguments[1]);
var items = JSON.parse(str(input())), seen = {}, n = Math.min(size(), Number(arguments[2])), added = [];
for (var i = 0; i < n; i++) seen[key(i)] = true;
for (var j = 0; j < items.length; j++) {
    if (seen[items[j].key]) continue;
    var row = items[j].top ? 0 : size(), first = true;
    for (var name in items[j].formats) {
        var data = fromBase64(items[j].formats[name]);
        if (first) write(row, name, data); else change(row, name, data);
        first = false;
    }
    seen[items[j].key] = true;
    added.push(items[j].key);
}
print(JSON.stringify(added));"""

    REMOVE = KEY + """tab(arguments[1]);
var wanted = {}, keys = JSON.parse(str(input())), rows = [];
for (var j = 0; j < keys.length; j++) wanted[keys[j]] = true;
var n = Math.min(size(), Number(arguments[2]));
for (var i = 0; i < n; i++) {
    var k = key(i);
    if (wanted[k]) { rows.push(i); delete wanted[k]; }
}
for (var r = rows.length - 1; r >= 0; r--) remove(rows[r]);
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
        return [k or None for k in self.eval(self.TOP, self.tab, rows)]

    def read(self, row):
        """The row's key and every format but CopyQ's own, as {mime: bytes}."""
        result = self.eval(self.READ, self.tab, row)
        return result["key"], {name: base64.b64decode(data) for name, data in result["formats"].items()}

    def insert(self, items):
        """items: [(key, top, {mime: bytes})], oldest first. Returns the keys inserted."""
        payload = [{"key": key, "top": top, "formats": {name: base64.b64encode(data).decode("ascii") for name, data in formats.items()}}
                   for key, top, formats in items]
        return self.eval(self.INSERT, self.tab, DEDUPE_ROWS, stdin=json.dumps(payload)) if items else []

    def remove(self, keys):
        return self.eval(self.REMOVE, self.tab, SEARCH_ROWS, stdin=json.dumps(sorted(keys))) if keys else 0


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
        # ckey: the CopyQ key of a clipping without text (its contents only describe it); NULL when the text is the key.
        if "ckey" not in [row[1] for row in self.db.execute("PRAGMA table_info(clips)")]:
            self.db.execute("ALTER TABLE clips ADD COLUMN ckey TEXT")
        self.machine = self.meta("machine") or self.create_machine_id()
        self.own_log = os.path.join(self.state_dir, self.machine + ".jsonl")
        self.own_blobs = os.path.join(self.state_dir, "blobs", self.machine)
        os.makedirs(self.own_blobs, mode=0o700, exist_ok=True)
        self.last_local_at = 0
        self.watched = None
        self.just_inserted = set()
        self.export_existing = args.export_existing
        self.last_error = None
        self.seal_own_log()
        self.remove_unreferenced_blobs()

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
        """(at, machine, deleted, contents, ckey) or None."""
        row = self.db.execute("SELECT at, machine, deleted, contents, ckey FROM clips WHERE id = ?", (clip_id,)).fetchone()
        if not row:
            return None
        contents = self.crypto.open(row[3]) if row[3] and row[3].startswith("v1:") else row[3]
        return (*row[:3], contents, row[4])

    def live_id_for(self, key):
        row = self.db.execute("SELECT id FROM clips WHERE hash = ? AND deleted = 0 ORDER BY at DESC LIMIT 1",
                              (digest(key),)).fetchone()
        return row[0] if row else None

    # Credentials are kept sealed here too, so neither this state nor the server log shows them.
    def set_clip(self, clip_id, at, machine, deleted, contents, ckey=None):
        stored = self.crypto.seal(contents) if contents and not ckey and self.detector.is_credential(contents) else contents
        key = ckey or contents
        self.db.execute("INSERT OR REPLACE INTO clips (id, at, machine, deleted, hash, contents, ckey) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        (clip_id, at, machine, 1 if deleted else 0, digest(key) if key else None, stored, ckey))

    def seal_event(self, event):
        text = event.get("contents")
        if event.get("described") or not isinstance(text, str) or not self.detector.is_credential(text):
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
                    if isinstance(event, dict) and event.get("op") == "put" and "items" not in event and self.seal_event(event):
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
        for row in self.db.execute("SELECT id, at, machine, deleted, contents, ckey FROM clips").fetchall():
            if row[4] and not row[5] and not row[4].startswith("v1:") and self.detector.is_credential(row[4]):
                self.set_clip(*row)
        self.set_meta(done_key, str(sealed))
        self.db.commit()
        if sealed:
            log.info("sealed %d credential clipping(s) in %s", sealed, self.own_log)

    def clear_marker(self):
        parts = (self.meta("clear") or "").split(" ", 1)
        return (int(parts[0]), parts[1]) if len(parts) == 2 else (0, "")

    # Blobs

    def store_blob(self, data):
        address = sha256_hex(data)
        path = os.path.join(self.own_blobs, address)
        if not os.path.exists(path):
            temporary = f"{path}.{uuid.uuid4().hex}.partial"
            with open(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as f:
                f.write(data)
            os.replace(temporary, path)
        return address

    def remove_unreferenced_blobs(self):
        try:
            with open(self.own_log, "rb") as f:
                keep = blob_addresses(f.read())
        except FileNotFoundError:
            keep = set()
        cutoff = time.time() - UNREFERENCED_BLOB_SECONDS
        removed = 0
        for name in os.listdir(self.own_blobs):
            path = os.path.join(self.own_blobs, name)
            if name not in keep and os.path.getmtime(path) < cutoff:
                os.remove(path)
                removed += 1
        if removed:
            log.info("removed %d blob(s) no line of %s refers to", removed, self.own_log)

    def fetch_blob(self, machine, address):
        """The blob's bytes, or None if the server doesn't have it (blobs go up before their lines, so it's gone)."""
        status, _, data = self.server.request("GET", f"/v1/blobs/{urllib.parse.quote(machine)}/{address}")
        if status == 404:
            return None
        if status != 200 or sha256_hex(data) != address:
            raise RuntimeError(f"cannot download {machine}'s pasteboard data: HTTP {status}")
        return data

    def formats_of_event(self, event, machine, text):
        """The event's first item as CopyQ formats {mime: bytes}; types CopyQ has no use for are left out."""
        formats = {}
        items = event.get("items") or []
        first = items[0] if items and isinstance(items[0], list) else []
        for representation in first:
            if not isinstance(representation, dict) or not BLOB_NAME.match(str(representation.get("b", ""))):
                continue
            uti = str(representation.get("t", ""))
            mime = UTI_TO_MIME.get(uti) or (uti if "/" in uti else None)
            if not mime or mime in formats:
                continue
            data = self.fetch_blob(machine, representation["b"])
            if data is not None and representation.get("s"):
                data = self.crypto.open_data(data)
            if data is not None:
                formats[mime] = data
        if not event.get("described") or not formats:
            formats["text/plain"] = text.encode("utf-8")
        return formats

    # Local copies

    def next_local_at(self, seen):
        self.last_local_at = max(now_ms(), seen + 1, self.last_local_at + 1)
        return self.last_local_at

    def share_copy(self, formats):
        formats = {name: data for name, data in formats.items() if not name.startswith(INTERNAL_FORMAT)}
        text_bytes = formats.get("text/plain")
        text = text_bytes.decode("utf-8", "replace") if text_bytes else None
        if text is not None and len(text) > MAX_TEXT:
            return
        contents = text or describe(formats)
        if not contents:
            return
        described = text is None
        key = item_key(formats)
        sealed = not described and self.detector.is_credential(text)

        total = sum(len(data) for data in formats.values())
        while total > MAX_ITEM_BYTES:
            largest = max((name for name in formats if name != "text/plain"), key=lambda name: len(formats[name]), default=None)
            if largest is None:
                break
            total -= len(formats.pop(largest))
        items = None
        if set(formats) != {"text/plain"}:
            representations = []
            for name, data in formats.items():
                representation = {"t": MIME_TO_UTI.get(name, name), "b": self.store_blob(self.crypto.seal_data(data) if sealed else data), "n": len(data)}
                if sealed:
                    representation["s"] = True
                representations.append(representation)
            items = [representations]

        clip_id = self.live_id_for(key) or str(uuid.uuid4()).upper()
        known = self.clip(clip_id)
        at = self.next_local_at(max(known[0] if known else 0, self.clear_marker()[0]))
        self.set_clip(clip_id, at, self.machine, False, contents, key if described else None)
        host = socket.gethostname().split(".")[0]
        first_format = next(iter(formats))
        event = {"v": 1, "op": "put", "list": HISTORY_LIST, "id": clip_id, "at": at, "m": self.machine,
                 "rank": time.time(), "contents": contents, "type": "NSStringPboardType" if text else MIME_TO_UTI.get(first_format, first_format),
                 "app": host, "ts": int(time.time())}
        if described:
            event["described"] = True
        if items:
            event["items"] = items
        self.seal_event(event)
        with open(self.own_log, "a", encoding="utf-8") as f:
            f.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
        os.chmod(self.own_log, 0o600)

    def share_row(self, row, expected_key):
        key, formats = self.copyq.read(row)
        if key == expected_key:  # rows can move between reads; the next poll sees the item again if it did
            self.share_copy(formats)

    # New items above the previous top are new copies. An item that was lower and is now right above the
    # previous top was copied again (CopyQ moves it up). "Previous top" is the first earlier row still in
    # the tab, since the bridge or the user may have removed rows in between. Items the bridge itself
    # inserted are skipped. Rows are compared by key (item_key).
    def poll_copyq(self):
        rows = self.copyq.top()
        if self.watched is None:
            self.watched = rows
            if self.meta("exported") is None:
                for row in reversed(range(min(self.export_existing, len(rows)))):
                    if rows[row]:
                        self.share_row(row, rows[row])
                self.set_meta("exported", str(min(self.export_existing, len(rows))))
            return
        if rows == self.watched:
            return
        previous = set(k for k in self.watched if k)
        present = set(rows)
        still_there = [k for k in self.watched if k in present]
        copied = []
        for i, key in enumerate(rows):
            if key in previous:
                if still_there and key != still_there[0] and i + 1 < len(rows) and rows[i + 1] == still_there[0]:
                    copied.append((i, key))
                break
            copied.append((i, key))
        for row, key in reversed(copied):
            if not key:
                continue
            if key in self.just_inserted:
                self.just_inserted.discard(key)
                continue
            self.share_row(row, key)
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
                for clip_id, clip_at, clip_machine, contents, ckey in self.db.execute(
                        "SELECT id, at, machine, contents, ckey FROM clips WHERE deleted = 0").fetchall():
                    if newer(at, machine, clip_at, clip_machine):
                        if contents and contents.startswith("v1:"):
                            contents = self.crypto.open(contents)
                        self.set_clip(clip_id, clip_at, clip_machine, True, contents, ckey)
                        inserts.pop(clip_id, None)
                        removals.add(ckey or contents)
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
                formats = self.formats_of_event(event, machine, text)
                key = item_key(formats)
                self.set_clip(clip_id, at, machine, False, text, key if key != text else None)
                removals.discard(key)
                inserts[clip_id] = (float(event.get("rank") or 0), key, formats)
            elif op == "del":
                contents, ckey = (known[3], known[4]) if known else (None, None)
                self.set_clip(clip_id, at, machine, True, contents, ckey)
                inserts.pop(clip_id, None)
                key = ckey or contents
                if key and not self.live_id_for(key):
                    removals.add(key)

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
            self.upload_blobs(local[sent:], None)
            status, _, _ = self.server.request("POST", path, local[sent:], {"X-Log-Offset": str(sent)})
        if status != 204:
            self.upload_blobs(local, self.server_blobs() if blob_addresses(local) else set())
            status, _, body = self.server.request("PUT", path, local)
            if status != 204:
                raise RuntimeError(f"upload failed: HTTP {status} {body[:100]!r}")
        self.set_meta("sent", str(len(local)))

    def server_blobs(self):
        status, _, body = self.server.request("GET", f"/v1/blobs/{urllib.parse.quote(self.machine)}")
        if status != 200:
            raise RuntimeError(f"cannot list this machine's pasteboard data on the server: HTTP {status}")
        return set(json.loads(body))

    # Blobs go up before the lines that refer to them; known is what the server has, or None to ask per blob.
    def upload_blobs(self, lines, known):
        for address in blob_addresses(lines):
            if known is not None and address in known:
                continue
            path = f"/v1/blobs/{urllib.parse.quote(self.machine)}/{address}"
            if known is None and self.server.request("HEAD", path)[0] == 200:
                continue
            try:
                with open(os.path.join(self.own_blobs, address), "rb") as f:
                    data = f.read()
            except FileNotFoundError:
                continue  # gone here too; readers skip it
            status, _, body = self.server.request("PUT", path, data)
            if status == 413:  # too large for the server or its proxy: left out rather than retried forever
                log.warning("the server refused %d bytes of pasteboard data as too large; synced without it", len(data))
                continue
            if status != 204:
                raise RuntimeError(f"cannot upload pasteboard data: HTTP {status} {body[:100]!r}")

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
            items = [(key, rank >= recent, formats) for rank, key, formats in ordered]
            added = self.copyq.insert(items)
            self.just_inserted.update(set(added) & {key for key, top, _ in items if top})
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
