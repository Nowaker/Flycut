"""Bounded SQL archive search with revision-bound keyset cursors."""

import base64
import binascii
from typing import Annotated

from pydantic import Field

from .archive import INTEGER, OPTIONAL_STRINGS, STRINGS, Archive, string_rows
from .protocol import BridgeError, CreatePayload, Model


class Search(Model):
    text: str = ""
    favorites: bool = False
    duplicates: bool = True
    limit: Annotated[int, Field(ge=1, le=1000)] = 100
    cursor: str | None = None


class Cursor(Model):
    revision: int
    text: str
    favorites: bool
    duplicates: bool
    stamp: tuple[int, str, str, str]


class Item(Model):
    item_id: str
    payload: CreatePayload
    favorite: bool
    recent_clock: int
    recent_device: str
    recent_event: str


class Page(Model):
    items: list[Item]
    next_cursor: str | None
    revision: int


def search(archive: Archive, request: Search) -> Page:
    with archive.transaction(write=False) as db:
        revision = INTEGER.validate_python(db.execute(
            "SELECT COALESCE(MAX(ingest_seq),0) FROM events").fetchone())[0]
        stamp: tuple[int, str, str, str] = (9223372036854775807, "~", "~", "~")
        if request.cursor:
            try:
                cursor = Cursor.model_validate_json(base64.b64decode(request.cursor, validate=True))
            except (binascii.Error, ValueError) as error:
                raise BridgeError("invalid search cursor") from error
            if (cursor.revision, cursor.text, cursor.favorites, cursor.duplicates) != (
                    revision, request.text, request.favorites, request.duplicates):
                raise BridgeError("archive or query changed; refresh from the first page")
            stamp = cursor.stamp
        if request.duplicates:
            query = """SELECT json_object('item_id',item_id,'payload',json(payload),
              'favorite',json(CASE favorite WHEN 1 THEN 'true' ELSE 'false' END),
              'recent_clock',recent_clock,'recent_device',recent_device,'recent_event',recent_event)
            FROM items WHERE deleted=0 AND payload IS NOT NULL AND (?=0 OR favorite=1)
              AND contains_folded(json_extract(payload,'$.text'),?)=1
              AND (recent_clock,recent_device,recent_event,item_id)<(?,?,?,?)
            ORDER BY recent_clock DESC,recent_device DESC,recent_event DESC,item_id DESC LIMIT ?"""
        else:
            query = """WITH ranked AS (
              SELECT *, ROW_NUMBER() OVER (PARTITION BY json_extract(payload,'$.text')
              ORDER BY recent_clock DESC,recent_device DESC,recent_event DESC,item_id DESC) AS representative
              FROM items WHERE deleted=0 AND payload IS NOT NULL AND (?=0 OR favorite=1))
            SELECT json_object('item_id',item_id,'payload',json(payload),'favorite',json(CASE favorite
              WHEN 1 THEN 'true' ELSE 'false' END),'recent_clock',recent_clock,'recent_device',recent_device,
              'recent_event',recent_event)
            FROM ranked WHERE contains_folded(json_extract(payload,'$.text'),?)=1
              AND representative=1 AND (recent_clock,recent_device,recent_event,item_id)<(?,?,?,?)
            ORDER BY recent_clock DESC,recent_device DESC,recent_event DESC,item_id DESC LIMIT ?"""
        rows = db.execute(query, (int(request.favorites), request.text, *stamp, request.limit + 1))
        items = [Item.model_validate_json(row[0]) for row in string_rows(rows)]
        next_cursor = None
        if len(items) > request.limit:
            items = items[:request.limit]
            last = items[-1]
            token = Cursor(revision=revision, text=request.text, favorites=request.favorites,
                           duplicates=request.duplicates,
                           stamp=(last.recent_clock, last.recent_device, last.recent_event, last.item_id))
            next_cursor = base64.b64encode(token.model_dump_json().encode()).decode("ascii")
        return Page(items=items, next_cursor=next_cursor, revision=revision)


def item_text(archive: Archive, item_id: str) -> str:
    with archive.transaction(write=False) as db:
        row = OPTIONAL_STRINGS.validate_python(db.execute(
                         "SELECT payload FROM items WHERE item_id=? AND deleted=0 AND payload IS NOT NULL",
                         (item_id,)).fetchone())
        if row is None:
            raise BridgeError("live archive item not found")
        return CreatePayload.model_validate_json(STRINGS.validate_python(row)[0]).text
