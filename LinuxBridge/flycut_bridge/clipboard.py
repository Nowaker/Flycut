"""Manager-independent explicit copy/import and local observation suppression."""

import time
from typing import Final, Literal, Protocol, assert_never

from .archive import OPTIONAL_STRINGS, Archive
from .dbus import Bus
from .gpaste import GPaste
from .klipper import Klipper
from .protocol import BridgeError, CreatePayload, Model
from .query import item_text

ManagerName = Literal["auto", "gpaste", "klipper"]


class Manager(Protocol):
    @property
    def name(self) -> str: ...

    @property
    def source_id(self) -> str: ...

    def current(self) -> str: ...
    def history(self) -> list[str]: ...
    def write(self, text: str) -> None: ...


class Selection(Model):
    text: str
    expires_at_ms: int


def manager(choice: ManagerName) -> Manager:
    match choice:
        case "gpaste":
            if not Bus.owns("org.gnome.GPaste"):
                raise BridgeError("GPaste is not running on this desktop session bus")
            return GPaste()
        case "klipper":
            if not Bus.owns("org.kde.klipper"):
                raise BridgeError("Klipper is not running on this desktop session bus")
            return Klipper()
        case "auto":
            if Bus.owns("org.gnome.GPaste"):
                return GPaste()
            if Bus.owns("org.kde.klipper"):
                return Klipper()
            raise BridgeError("no supported running clipboard manager; GPaste2 or Klipper required")
        case _:
            assert_never(choice)


def select(archive: Archive, desktop: Manager, item_id: str, *, moves_to_top: bool = False) -> None:
    text = item_text(archive, item_id)
    pending = Selection(text=text, expires_at_ms=time.time_ns() // 1000000 + 10000)
    with archive.transaction() as db:
        archive.set_meta(db, "selection", pending.model_dump_json())
    try:
        desktop.write(text)
    except BridgeError:
        with archive.transaction() as db:
            db.execute("DELETE FROM metadata WHERE key='selection' AND value=?", (pending.model_dump_json(),))
        raise
    if moves_to_top:
        archive.action(item_id, "touch")


def import_history(archive: Archive, desktop: Manager) -> int:
    """Explicit one-time history import, never a startup or sync side effect."""
    marker = f"manager_import:{desktop.source_id}"
    with archive.transaction() as db:
        if db.execute("SELECT 1 FROM metadata WHERE key=?", (marker,)).fetchone():
            raise BridgeError("this manager's history was already imported into this archive")
        history = desktop.history()
        for text in reversed(history):
            if text:
                payload = CreatePayload(text=text, content_type="text/plain", captured_at_ms=None,
                                        source_app=desktop.name, source_id=desktop.source_id, favorite=False)
                archive.allocate(db, payload, ("create", None))
        archive.set_meta(db, marker, "1")
        return sum(bool(text) for text in history)


class Observer:
    """Mutable, local-only previous value; imports never update this capture state."""

    def __init__(self, archive: Archive, initial: str, desktop: Manager | None = None) -> None:
        self.archive: Final = archive
        self.previous: str = initial
        self.desktop: Final = desktop
        with archive.transaction() as db:
            db.execute("DELETE FROM metadata WHERE key='selection'")

    def observe(self, text: str) -> str | None:
        captured = None
        with self.archive.transaction() as db:
            row = OPTIONAL_STRINGS.validate_python(
                db.execute("SELECT value FROM metadata WHERE key='selection'").fetchone())
            pending = Selection.model_validate_json(row[0]) if row is not None else None
            suppress = (pending is not None and pending.text == text
                        and pending.expires_at_ms >= time.time_ns() // 1000000)
            if pending is not None and (suppress or pending.expires_at_ms < time.time_ns() // 1000000
                                         or self.previous != text):
                db.execute("DELETE FROM metadata WHERE key='selection'")
            if suppress:
                captured = None
            elif self.previous == text:
                return None
            elif text:
                payload = CreatePayload(text=text, content_type="text/plain", captured_at_ms=time.time_ns() // 1000000,
                                        source_app=self.desktop.name if self.desktop else None,
                                        source_id=self.desktop.source_id if self.desktop else None, favorite=False)
                captured = self.archive.allocate(db, payload, ("create", None)).item_id
        self.previous = text
        return captured
