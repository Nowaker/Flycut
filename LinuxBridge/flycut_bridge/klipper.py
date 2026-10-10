"""Klipper DBus text adapter and consecutive-local-value capture suppression."""

import shutil
import subprocess
import time
from typing import Literal

from pydantic import TypeAdapter

from .archive import OPTIONAL_STRINGS, Archive
from .protocol import BridgeError, CreatePayload, Model
from .query import item_text


class BusResult(Model):
    type: str
    data: list[str | list[str]]


class Selection(Model):
    text: str
    expires_at_ms: int


class Klipper:
    """Uses KDE's org.kde.klipper.klipper text API, not raw clipboard MIME."""

    def __init__(self) -> None:
        executable = shutil.which("busctl")
        if executable is None:
            raise BridgeError("busctl required; install systemd DBus tools on Linux")
        self.executable: str = executable

    def call(self, method: Literal["getClipboardContents", "getClipboardHistoryMenu", "setClipboardContents"],
             text: str | None = None) -> str:
        arguments = [self.executable, "--user", "--json=short", "--timeout=5", "call",
                     "org.kde.klipper", "/klipper", "org.kde.klipper.klipper", method]
        if text is not None:
            arguments.extend(["s", text])
        try:
            result = subprocess.run(arguments, capture_output=True, text=True, check=False, timeout=6)  # noqa: S603 - argv uses verified busctl and fixed methods, without a shell.
        except (OSError, subprocess.TimeoutExpired) as error:
            raise BridgeError("Klipper DBus unavailable; verify your logged-in KDE user session") from error
        if result.returncode:
            raise BridgeError("Klipper DBus unavailable; start Klipper in the logged-in KDE session")
        return result.stdout

    def current(self) -> str:
        result = BusResult.model_validate_json(self.call("getClipboardContents"))
        return TypeAdapter(str).validate_python(result.data[0])

    def history(self) -> list[str]:
        result = BusResult.model_validate_json(self.call("getClipboardHistoryMenu"))
        return TypeAdapter(list[str]).validate_python(result.data[0])

    def select(self, archive: Archive, item_id: str, moves_to_top: bool = False) -> None:
        """Only this explicit action writes Clipboard and PRIMARY Selection."""
        text = item_text(archive, item_id)
        selection = Selection(text=text, expires_at_ms=time.time_ns() // 1000000 + 10000)
        with archive.transaction() as db:
            archive.set_meta(db, "selection", selection.model_dump_json())
        try:
            self.call("setClipboardContents", text)
        except BridgeError:
            with archive.transaction() as db:
                db.execute("DELETE FROM metadata WHERE key='selection' AND value=?", (selection.model_dump_json(),))
            raise
        if moves_to_top:
            archive.action(item_id, "touch")

    def import_history(self, archive: Archive) -> int:
        """One-time explicit import of Klipper's display strings, oldest first."""
        with archive.transaction() as db:
            if db.execute("SELECT 1 FROM metadata WHERE key='klipper_import'").fetchone():
                raise BridgeError("Klipper history was already imported into this archive")
            history = self.history()
            for text in reversed(history):
                if text:
                    payload = CreatePayload(text=text, content_type="text/plain", captured_at_ms=None,
                                            source_app="Klipper", source_id="org.kde.klipper", favorite=False)
                    archive.allocate(db, payload, ("create", None))
            archive.set_meta(db, "klipper_import", "1")
            return sum(bool(text) for text in history)


class Observer:
    """Mutable observer state is local-only and seeded before any import/capture."""

    def __init__(self, archive: Archive, initial: str) -> None:
        self.archive: Archive = archive
        self.previous: str = initial
        with archive.transaction() as db:
            db.execute("DELETE FROM metadata WHERE key='selection'")

    def observe(self, text: str) -> str | None:
        captured = None
        with self.archive.transaction() as db:
            row = OPTIONAL_STRINGS.validate_python(
                db.execute("SELECT value FROM metadata WHERE key='selection'").fetchone())
            selection = Selection.model_validate_json(row[0]) if row is not None else None
            suppress = (selection is not None and selection.text == text
                        and selection.expires_at_ms >= time.time_ns() // 1000000)
            if selection is not None and (suppress or selection.expires_at_ms < time.time_ns() // 1000000
                                           or self.previous != text):
                db.execute("DELETE FROM metadata WHERE key='selection'")
            if suppress:
                captured = None
            elif self.previous == text:
                return None
            elif text:
                payload = CreatePayload(text=text, content_type="text/plain", captured_at_ms=time.time_ns() // 1000000,
                                        source_app="Klipper", source_id="org.kde.klipper", favorite=False)
                captured = self.archive.allocate(db, payload, ("create", None)).item_id
        self.previous = text
        return captured
