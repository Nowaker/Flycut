"""Atomic durable event ingestion and the shared last-writer-wins reducer."""

import sqlite3
import time
from collections.abc import Generator, Sequence
from contextlib import closing, contextmanager
from pathlib import Path
from typing import Literal, assert_never
from uuid import uuid4

from pydantic import TypeAdapter

from .protocol import (
    EVENT,
    MAX_CLOCK,
    PROTOCOL,
    BridgeError,
    CreateEvent,
    CreatePayload,
    DeleteEvent,
    EmptyPayload,
    Event,
    FavoriteEvent,
    FavoritePayload,
    TouchEvent,
    identifier,
)

STRINGS = TypeAdapter(tuple[str, ...])
OPTIONAL_STRINGS = TypeAdapter(tuple[str, ...] | None)
INTEGER = TypeAdapter(tuple[int])


def string_rows(cursor: sqlite3.Cursor) -> Generator[tuple[str, ...]]:
    while row := OPTIONAL_STRINGS.validate_python(cursor.fetchone()):
        yield row


class Archive:
    """One SQLite connection owner; every mutation is a FULL-synchronous transaction."""

    def __init__(self, path: Path) -> None:
        self.path: Path = path
        if not path.is_file():
            raise BridgeError("archive missing; run init with an explicit collection UUID")
        with self.transaction() as db:
            if self.meta(db, "schema") != "1":
                raise BridgeError("unsupported archive schema")

    @staticmethod
    def initialize(path: Path, collection: str) -> None:
        collection = identifier(collection)
        if path.exists():
            raise BridgeError("archive already exists")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with path.open("xb"):
            path.chmod(0o600)
        with closing(sqlite3.connect(path)) as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA synchronous=FULL")
            db.executescript(Path(__file__).with_name("schema.sql").read_text())
            with db:
                db.executemany("INSERT INTO metadata VALUES (?,?)", [
                    ("schema", "1"), ("collection", collection),
                    ("device", str(uuid4())), ("clock", "0"),
                ])

    @contextmanager
    def transaction(self, *, write: bool = True) -> Generator[sqlite3.Connection]:
        with closing(sqlite3.connect(self.path, timeout=10)) as db:
            db.execute("PRAGMA synchronous=FULL")
            if not write:
                db.execute("PRAGMA query_only=ON")
            db.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            with db:
                yield db

    @staticmethod
    def meta(db: sqlite3.Connection, key: str) -> str:
        row = OPTIONAL_STRINGS.validate_python(db.execute("SELECT value FROM metadata WHERE key=?", (key,)).fetchone())
        if row is None:
            raise BridgeError("required archive metadata missing")
        return STRINGS.validate_python(row)[0]

    @staticmethod
    def set_meta(db: sqlite3.Connection, key: str, value: str) -> None:
        db.execute("INSERT OR REPLACE INTO metadata VALUES (?,?)", (key, value))

    def ingest(self, db: sqlite3.Connection, event: Event) -> bool:
        if event.collection_id != self.meta(db, "collection"):
            raise BridgeError("collection mismatch; explicit join is required")
        row = OPTIONAL_STRINGS.validate_python(
            db.execute("SELECT json FROM events WHERE event_id=?", (event.event_id,)).fetchone())
        if row is not None:
            if EVENT.validate_json(STRINGS.validate_python(row)[0]) != event:
                raise BridgeError("conflicting reuse of event_id")
            return False
        db.execute("INSERT INTO events(event_id,device_id,clock,op,item_id,json) VALUES (?,?,?,?,?,?)",
                   (event.event_id, event.device_id, int(event.clock), event.op,
                    event.item_id, event.model_dump_json()))
        self.set_meta(db, "clock", str(max(int(self.meta(db, "clock")), int(event.clock))))
        db.execute("INSERT OR IGNORE INTO items(item_id) VALUES (?)", (event.item_id,))
        stamp = (int(event.clock), event.device_id, event.event_id)
        match event:
            case CreateEvent():
                db.execute("""UPDATE items SET payload=?,create_clock=?,create_device=?,create_event=?
                           WHERE item_id=?""", (event.payload.model_dump_json(), *stamp, event.item_id))
                self.register(db, event)
            case FavoriteEvent():
                self.register(db, event)
            case TouchEvent():
                self.register(db, event)
            case DeleteEvent():
                db.execute("UPDATE items SET deleted=1 WHERE item_id=?", (event.item_id,))
            case _:
                assert_never(event)
        return True

    @staticmethod
    def register(db: sqlite3.Connection, event: CreateEvent | FavoriteEvent | TouchEvent) -> None:
        stamp = (int(event.clock), event.device_id, event.event_id)
        match event:
            case CreateEvent():
                favorite_value, recent = int(event.payload.favorite), True
            case FavoriteEvent():
                favorite_value, recent = int(event.payload.value), False
            case TouchEvent():
                favorite_value, recent = None, True
            case _:
                assert_never(event)
        if favorite_value is not None:
            db.execute("""UPDATE items SET favorite=?,favorite_clock=?,favorite_device=?,favorite_event=?
                       WHERE item_id=? AND (favorite_clock,favorite_device,favorite_event)<(?,?,?)""",
                       (favorite_value, *stamp, event.item_id, *stamp))
        if recent:
            db.execute("""UPDATE items SET recent_clock=?,recent_device=?,recent_event=?
                       WHERE item_id=? AND (recent_clock,recent_device,recent_event)<(?,?,?)""",
                       (*stamp, event.item_id, *stamp))

    def allocate(self, db: sqlite3.Connection, payload: CreatePayload | FavoritePayload | EmptyPayload,
                 target: tuple[Literal["create", "favorite", "touch", "delete"], str | None]) -> Event:
        clock = int(self.meta(db, "clock")) + 1
        if clock > MAX_CLOCK:
            raise BridgeError("Lamport clock exhausted")
        event_id = str(uuid4())
        op, item_id = target
        fields = {"protocol": PROTOCOL, "version": 1, "collection_id": self.meta(db, "collection"),
                  "device_id": self.meta(db, "device"), "clock": str(clock), "event_id": event_id,
                  "item_id": item_id or event_id, "op": op, "payload": payload.model_dump()}
        event = EVENT.validate_python(fields)
        self.ingest(db, event)
        return event

    def capture(self, text: str) -> str:
        payload = CreatePayload(text=text, content_type="text/plain", captured_at_ms=time.time_ns() // 1000000,
                                source_app=None, source_id=None, favorite=False)
        with self.transaction() as db:
            return self.allocate(db, payload, ("create", None)).item_id

    def action(self, item_id: str, action: Literal["favorite", "touch", "delete"],
               favorite: bool = False) -> None:
        item_id = identifier(item_id)
        with self.transaction() as db:
            if db.execute("SELECT 1 FROM items WHERE item_id=? AND payload IS NOT NULL AND deleted=0",
                          (item_id,)).fetchone() is None:
                raise BridgeError("live archive item not found")
            payload = FavoritePayload(value=favorite) if action == "favorite" else EmptyPayload()
            self.allocate(db, payload, (action, item_id))

    def clear(self) -> int:
        with self.transaction() as db:
            count = 0
            rows = db.execute("SELECT item_id FROM items WHERE deleted=0 AND favorite=0 AND payload IS NOT NULL")
            for row in string_rows(rows):
                self.allocate(db, EmptyPayload(), ("delete", STRINGS.validate_python(row)[0]))
                count += 1
            return count

    def import_events(self, events: Sequence[Event]) -> int:
        with self.transaction() as db:
            return sum(self.ingest(db, event) for event in events)

    def events_after(self, sequence: int, limit: int = 200) -> list[tuple[int, Event]]:
        with self.transaction(write=False) as db:
            rows = db.execute("""SELECT CAST(ingest_seq AS TEXT),json FROM events WHERE ingest_seq>?
                              ORDER BY ingest_seq LIMIT ?""", (sequence, limit))
            result: list[tuple[int, Event]] = []
            for row in string_rows(rows):
                seq, raw = STRINGS.validate_python(row)
                result.append((int(seq), EVENT.validate_json(raw)))
            return result

    def join(self, collection: str) -> None:
        """Explicitly share the whole local event log, preserving item IDs atomically."""
        collection = identifier(collection)
        with self.transaction() as db:
            db.execute("UPDATE events SET json=json_set(json,'$.collection_id',?)", (collection,))
            self.set_meta(db, "collection", collection)
            db.execute("DELETE FROM checkpoints")

    def checkpoint(self, backend: str) -> tuple[int, str]:
        with self.transaction() as db:
            active = OPTIONAL_STRINGS.validate_python(
                db.execute("SELECT value FROM metadata WHERE key='backend'").fetchone())
            if active is None or STRINGS.validate_python(active)[0] != backend:
                db.execute("DELETE FROM checkpoints")
                self.set_meta(db, "backend", backend)
            db.execute("INSERT OR IGNORE INTO checkpoints VALUES (?,0,'')", (backend,))
            row = STRINGS.validate_python(db.execute(
                "SELECT CAST(uploaded AS TEXT),cursor FROM checkpoints WHERE backend=?", (backend,)).fetchone())
            seq, cursor = STRINGS.validate_python(row)
            return int(seq), cursor
