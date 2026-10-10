"""Descriptor-pinned immutable folder transport with durable directory publication."""

import os
import stat
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from uuid import uuid4

from pydantic import ValidationError

from .archive import Archive
from .protocol import EVENT, PROTOCOL, BridgeError, Event, Manifest


@contextmanager
def directory(path: Path) -> Generator[int]:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        yield fd
    finally:
        os.close(fd)


@contextmanager
def child(parent: int, name: str) -> Generator[int]:
    created = False
    try:
        os.mkdir(name, mode=0o700, dir_fd=parent)
        created = True
    except FileExistsError:
        created = False
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    try:
        if created:
            os.fsync(fd)
            os.fsync(parent)
        yield fd
    finally:
        os.close(fd)


def read_file(parent: int, name: str) -> bytes:
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise BridgeError("folder event/manifest must be a regular file")
        return stream.read()


def publish(parent: int, name: str, raw: bytes) -> None:
    """Publish relative to a pinned directory, never following/replacing a destination."""
    temporary = f".flycut-{uuid4()}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
        os.fsync(parent)
    finally:
        os.unlink(temporary, dir_fd=parent)


class Folder:
    def __init__(self, root: Path) -> None:
        self.root: Path = root.resolve(strict=True)
        with directory(self.root) as fd:
            self.manifest: Manifest = Manifest.model_validate_json(read_file(fd, "manifest.json"))

    @staticmethod
    def initialize(root: Path, collection: str) -> None:
        resolved = root.resolve()
        manifest = Manifest(protocol=PROTOCOL, version=1, collection_id=collection)
        parent = Path(resolved.anchor)
        for part in resolved.parts[1:]:
            with directory(parent) as fd, child(fd, part):
                parent = parent / part
        with directory(resolved) as fd:
            publish(fd, "manifest.json", manifest.model_dump_json().encode())

    @staticmethod
    def upload(root: int, event: Event) -> None:
        with child(root, "events") as events, child(events, event.event_id[:2]) as shard:
            name = f"{event.event_id}.json"
            try:
                publish(shard, name, event.model_dump_json().encode())
            except FileExistsError:
                if EVENT.validate_json(read_file(shard, name)) != event:
                    raise BridgeError("conflicting immutable folder event") from None
                os.fsync(shard)

    @staticmethod
    def incoming(root: int) -> Generator[Event | None]:
        with child(root, "events") as events, os.scandir(events) as shards:
            for entry in shards:
                if entry.is_symlink():
                    raise BridgeError("folder symlinks are not supported")
                if not entry.is_dir(follow_symlinks=False):
                    continue
                with child(events, entry.name) as shard, os.scandir(shard) as files:
                    for file in files:
                        if not file.name.endswith(".json"):
                            continue
                        try:
                            event = EVENT.validate_json(read_file(shard, file.name))
                        except (FileNotFoundError, ValidationError, UnicodeError):
                            yield None
                            continue
                        if file.name != f"{event.event_id}.json" or entry.name != event.event_id[:2]:
                            raise BridgeError("folder event path does not match event_id")
                        yield event

    def sync(self, archive: Archive) -> tuple[int, int, int]:
        backend = f"folder:{self.root}"
        uploaded, _ = archive.checkpoint(backend)
        sent, received, deferred = 0, 0, 0
        with directory(self.root) as root:
            manifest = Manifest.model_validate_json(read_file(root, "manifest.json"))
            with archive.transaction() as db:
                if archive.meta(db, "collection") != manifest.collection_id:
                    raise BridgeError("folder collection mismatch; explicit join is required")
            while events := archive.events_after(uploaded):
                for sequence, event in events:
                    if event.collection_id != manifest.collection_id:
                        raise BridgeError("collection changed during sync; restart sync")
                    self.upload(root, event)
                    with archive.transaction() as db:
                        db.execute("UPDATE checkpoints SET uploaded=? WHERE backend=?", (sequence, backend))
                    uploaded = sequence
                    sent += 1
            batch: list[Event] = []
            for event in self.incoming(root):
                if event is None:
                    deferred += 1
                    continue
                batch.append(event)
                if len(batch) == 200:
                    received += archive.import_events(batch)
                    batch.clear()
            received += archive.import_events(batch)
        return sent, received, deferred
