"""Durable immutable event ingestion and insertion-sequence paging."""

import base64
import binascii
import json
import sqlite3
from contextlib import closing
from pathlib import Path
from uuid import uuid4

from SyncService.protocol import Event, Failure, JSON, MAX_CLOCK


class Store:
    def __init__(self, path: Path, collections: tuple[str, ...]) -> None:
        self.path = path
        with closing(self.connect()) as db, db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            db.execute("INSERT OR IGNORE INTO metadata VALUES ('identity', ?)", (str(uuid4()),))
            db.execute("CREATE TABLE IF NOT EXISTS collections (id TEXT PRIMARY KEY)")
            db.execute("CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY AUTOINCREMENT, collection TEXT NOT NULL REFERENCES collections(id), event_id TEXT NOT NULL, json TEXT NOT NULL, UNIQUE(collection,event_id))")
            db.execute("CREATE INDEX IF NOT EXISTS collection_sequence ON events(collection, seq)")
            db.executemany("INSERT OR IGNORE INTO collections VALUES (?)", [(c,) for c in collections])
            self.identity: str = db.execute("SELECT value FROM metadata WHERE key='identity'").fetchone()[0]

    def connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=10)
        db.execute("PRAGMA synchronous=FULL")
        db.execute("PRAGMA foreign_keys=ON")
        return db

    def rotate_cursor_identity(self) -> None:
        identity = str(uuid4())
        with closing(self.connect()) as db, db:
            db.execute("UPDATE metadata SET value=? WHERE key='identity'", (identity,))
        self.identity = identity

    def ingest(self, events: list[Event]) -> int:
        inserted = 0
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            for event in events:
                old = db.execute("SELECT json FROM events WHERE collection=? AND event_id=?", (event.collection_id, event.event_id)).fetchone()
                if old is not None:
                    if old[0] != event.encoded:
                        raise Failure(409, "conflicting_event")
                    continue
                db.execute("INSERT INTO events(collection,event_id,json) VALUES (?,?,?)",
                           (event.collection_id, event.event_id, event.encoded))
                inserted += 1
        return inserted

    def cursor(self, collection: str, sequence: int) -> str:
        raw = f"1:{self.identity}:{collection}:{sequence}".encode("ascii")
        return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

    def page(self, collection: str, after: str, limit: int) -> dict[str, JSON]:
        sequence = 0
        if after:
            try:
                raw = base64.b64decode(after + "=" * (-len(after) % 4), altchars=b"-_", validate=True).decode("ascii")
                version, identity, cursor_collection, number = raw.split(":")
                sequence = int(number)
                if version != "1" or identity != self.identity or cursor_collection != collection or not 0 <= sequence <= MAX_CLOCK or str(sequence) != number:
                    raise Failure(400, "invalid_cursor")
                if after != self.cursor(collection, sequence):
                    raise Failure(400, "invalid_cursor")
            except (ValueError, UnicodeError, binascii.Error):
                raise Failure(400, "invalid_cursor") from None
        with closing(self.connect()) as db:
            if sequence and db.execute("SELECT 1 FROM events WHERE collection=? AND seq=?", (collection, sequence)).fetchone() is None:
                raise Failure(400, "invalid_cursor")
            rows = db.execute("SELECT seq,json FROM events WHERE collection=? AND seq>? ORDER BY seq LIMIT ?",
                              (collection, sequence, limit + 1)).fetchall()
        visible = rows[:limit]
        return {"events": [json.loads(row[1]) for row in visible],
                "next_cursor": self.cursor(collection, visible[-1][0] if visible else sequence),
                "has_more": len(rows) > limit}
