# /// script
# requires-python = ">=3.12"
# dependencies = ["pydantic>=2.10,<3", "jeepney>=0.9,<0.10"]
# ///
# Run: uv run LinuxBridge/qa.py /path/to/shared/archive-v1.json
"""Portable real-SQLite/folder driver; consumes the shared reducer fixture unchanged."""

import json
import os
import sys
import time
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Annotated

from pydantic import Field, JsonValue, TypeAdapter, ValidationError

from flycut_bridge.archive import INTEGER, Archive
from flycut_bridge.clipboard import Observer, Selection
from flycut_bridge.folder import Folder, child, directory, publish, read_file
from flycut_bridge.protocol import EVENT, BridgeError, CreatePayload, Event, Model
from flycut_bridge.query import Search, search


class Expected(CreatePayload):
    item_id: str
    recent_clock: str
    recent_device: str
    recent_event: str


class Case(Model):
    name: str
    events: list[Annotated[Event, Field(discriminator="op")]]
    deliveries: list[list[int]]
    expected_items: list[Expected]
    expected_hidden_ids: list[str]
    expected_event_count: int


class Invalid(Model):
    name: str
    base_case: int
    base_event: int
    replace: dict[str, JsonValue] = Field(default_factory=dict)
    payload_replace: dict[str, JsonValue] = Field(default_factory=dict)


class Fixture(Model):
    protocol: str
    version: int
    collection_id: str
    cases: list[Case]
    invalid_variants: list[Invalid]


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise BridgeError(reason)


def fixtures(root: Path, fixture: Fixture) -> None:
    deliveries = 0
    for case in fixture.cases:
        for index, order in enumerate(case.deliveries):
            path = root / f"{case.name}-{index}.sqlite3"
            Archive.initialize(path, fixture.collection_id)
            archive = Archive(path)
            for event_index in order:
                archive.import_events([case.events[event_index]])
            page = search(Archive(path), Search())
            actual = [Expected(item_id=item.item_id, recent_clock=str(item.recent_clock),
                               recent_device=item.recent_device, recent_event=item.recent_event,
                               text=item.payload.text, content_type=item.payload.content_type,
                               captured_at_ms=item.payload.captured_at_ms, source_app=item.payload.source_app,
                               source_id=item.payload.source_id, favorite=item.favorite) for item in page.items]
            require(actual == case.expected_items, f"fixture projection mismatch: {case.name}")
            with archive.transaction() as db:
                count = INTEGER.validate_python(db.execute("SELECT COUNT(*) FROM events").fetchone())[0]
                require(count == case.expected_event_count, "fixture retry idempotence mismatch")
                for item_id in case.expected_hidden_ids:
                    require(db.execute("SELECT 1 FROM items WHERE item_id=? AND deleted=1",
                                       (item_id,)).fetchone() is not None,
                            "fixture tombstone missing")
            deliveries += 1
    for invalid in fixture.invalid_variants:
        event = TypeAdapter(dict[str, JsonValue]).validate_json(
            fixture.cases[invalid.base_case].events[invalid.base_event].model_dump_json())
        event.update(invalid.replace)
        payload = TypeAdapter(dict[str, JsonValue]).validate_python(event["payload"])
        payload.update(invalid.payload_replace)
        event["payload"] = payload
        try:
            EVENT.validate_json(json.dumps(event))
        except (ValidationError, BridgeError):
            continue
        raise BridgeError(f"invalid fixture accepted: {invalid.name}")
    print(f"Shared fixtures: {deliveries} delivery orders, {len(fixture.invalid_variants)} invalid variants passed.")


def portable(root: Path, collection: str) -> None:
    a_path, b_path = root / "a.sqlite3", root / "b.sqlite3"
    Archive.initialize(a_path, collection)
    Archive.initialize(b_path, collection)
    a, b = Archive(a_path), Archive(b_path)
    initial = a.capture("seeded")
    observer = Observer(a, "seeded")
    require(observer.observe("seeded") is None, "startup must not recapture")
    Folder.initialize(root / "shared", collection)
    folder = Folder(root / "shared")
    remote = b.capture("remote-only\nexact 😀")
    b.action(remote, "favorite", True)
    folder.sync(b)
    folder.sync(a)
    require(observer.observe("seeded") is None, "remote imports must not echo")
    local = observer.observe("remote-only\nexact 😀")
    require(local is not None and local != remote, "intentional matching local copy must create a separate ID")
    require(observer.observe("remote-only\nexact 😀") is None, "consecutive local observation must suppress")
    with a.transaction() as db:
        a.set_meta(db, "selection", Selection(
            text="seeded", expires_at_ms=time.time_ns() // 1000000 + 10000).model_dump_json())
    require(observer.observe("seeded") is None, "explicit selection must not recapture")
    with a.transaction() as db:
        a.set_meta(db, "selection", Selection(
            text="missed selection", expires_at_ms=time.time_ns() // 1000000 + 10000).model_dump_json())
    require(observer.observe("intervening capture") is not None, "intervening selection value must capture")
    require(observer.observe("missed selection") is not None, "stale selection must not suppress a later real copy")
    page = search(a, Search(limit=1))
    require(page.next_cursor is not None, "keyset continuation absent")
    continuation = search(a, Search(limit=1, cursor=page.next_cursor))
    require(continuation.items[0].item_id != page.items[0].item_id, "keyset repeats previous item")
    a.action(initial, "touch")
    try:
        search(a, Search(limit=1, cursor=page.next_cursor))
    except BridgeError:
        pass
    else:
        raise BridgeError("stale revision cursor accepted")
    event = a.events_after(0)[0][1]
    conflicting = EVENT.validate_json(event.model_dump_json().replace('"seeded"', '"corruption"'))
    before = len(a.events_after(0))
    try:
        a.import_events([b.events_after(0)[0][1], conflicting])
    except BridgeError:
        pass
    else:
        raise BridgeError("conflicting event overwrite accepted")
    require(len(a.events_after(0)) == before, "conflict batch was not atomic")
    require(a.clear() >= 1, "clear did not tombstone known nonfavorites")
    require([item.item_id for item in search(a, Search()).items] == [remote], "clear must preserve favorites")
    folder.sync(a)
    folder.sync(b)
    require(search(a, Search()).items == search(b, Search()).items, "folder peers did not converge")
    late = b.capture("late offline clip")
    event = b.events_after(0)[-1][1]
    path = root / "shared" / "events" / event.event_id[:2] / f"{event.event_id}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("{")
    require(folder.sync(a)[2] == 1, "partial file must be deferred")
    path.write_text(event.model_dump_json())
    folder.sync(a)
    require(search(a, Search(text="late offline")).items[0].item_id == late, "delayed file was permanently skipped")
    outside = root / "outside"
    outside.mkdir()
    link = root / "shared" / "events" / "escape"
    link.symlink_to(outside, target_is_directory=True)
    try:
        folder.sync(a)
    except BridgeError:
        pass
    else:
        raise BridgeError("folder symlink escape accepted")
    link.unlink()
    a.join("10000000-0000-0000-0000-000000000099")
    require(a.events_after(0)[0][1].collection_id == "10000000-0000-0000-0000-000000000099",
            "collection join did not rewrite envelope collection")
    require(a.events_after(0)[0][1].item_id == initial, "join changed local item identity")
    unicode_item = a.capture("CAFÉ Straße\0tail")
    require(search(a, Search(text="café strasse\0TAIL")).items[0].item_id == unicode_item,
            "Unicode casefold or embedded-NUL literal search failed")
    print("Portable SQLite/folder/observer QA passed: durable reopen, seed, no echo, conflict rollback, " +
          "clear/favorites, cursors, delayed files, symlink rejection, explicit join, Unicode/NUL search.")


def main() -> None:
    fixture = Fixture.model_validate_json(Path(sys.argv[1]).read_bytes())
    with TemporaryDirectory(prefix="flycut-linux-qa-") as temporary:
        root = Path(temporary)
        fixtures(root, fixture)
        portable(root, fixture.collection_id)
        pinned_folder(root)


def pinned_folder(root: Path) -> None:
    selected, outside = root / "pinned", root / "race-outside"
    selected.mkdir()
    outside.mkdir()
    with directory(selected) as fd, child(fd, "events") as events, child(events, "ab") as shard:
        os.rename("ab", "parked", src_dir_fd=events, dst_dir_fd=events)
        os.symlink(str(outside), "ab", dir_fd=events)
        publish(shard, "probe.json", b"synthetic pinned directory")
        require(not (outside / "probe.json").exists(), "race redirected publication outside root")
        require(read_file(shard, "probe.json") == b"synthetic pinned directory", "pinned publication missing")
        (outside / "outside.json").write_text("outside synthetic file")
        os.symlink(str(outside / "outside.json"), "substituted.json", dir_fd=shard)
        try:
            read_file(shard, "substituted.json")
        except OSError:
            pass
        else:
            raise BridgeError("substituted file symlink followed outside root")
    print("Pinned-folder race QA passed: renamed shard cannot redirect publication; substituted file cannot escape.")


if __name__ == "__main__":
    main()
