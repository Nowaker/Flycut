"""GPaste2 history adapter; actual clipboard reads use X11/Wayland, never history head."""

import os
import shutil
import subprocess
from typing import Final

from pydantic import TypeAdapter

from .dbus import Bus, Result
from .protocol import BridgeError

PAIRS: Final = TypeAdapter(tuple[list[tuple[str, str]]])
TEXT: Final = TypeAdapter(tuple[str])


class GPaste:
    def __init__(self) -> None:
        self.name: Final = "GPaste"
        self.source_id: Final = "org.gnome.GPaste"
        self.bus: Bus = Bus(self.source_id, "org.gnome.GPaste2", "/org/gnome/GPaste")
        if os.environ.get("WAYLAND_DISPLAY"):
            reader, writer = shutil.which("wl-paste"), shutil.which("wl-copy")
            if reader is None or writer is None:
                raise BridgeError("GPaste on Wayland requires wl-clipboard (wl-paste and wl-copy)")
            self.reader: tuple[str, ...] = (reader, "--no-newline", "--type", "text")
            self.writer: tuple[str, ...] = (writer, "--type", "text/plain;charset=utf-8")
        else:
            reader, writer = shutil.which("xclip"), shutil.which("xsel")
            if reader is None or writer is None or not os.environ.get("DISPLAY"):
                raise BridgeError("GPaste on X11 requires xclip, xsel, and the logged-in session DISPLAY/XAUTHORITY")
            self.reader = (reader, "-selection", "clipboard", "-out", "-target", "UTF8_STRING")
            self.writer = (writer, "--clipboard", "--input")

    def current(self) -> str:
        try:
            result = subprocess.run(self.reader, capture_output=True,  # noqa: S603 - fixed resolved clipboard reader argv, no shell.
                                    check=False, timeout=6)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise BridgeError("desktop clipboard reader unavailable") from error
        if result.returncode:
            if b"not available" in result.stderr or b"Nothing is copied" in result.stderr:
                return ""
            raise BridgeError("desktop clipboard read failed; verify DISPLAY/Wayland session authorization")
        return result.stdout.decode("utf-8")

    def history(self) -> list[str]:
        result = Result.model_validate_json(self.bus.call("GetHistory"))
        entries = PAIRS.validate_python(result.data)[0]
        texts: list[str] = []
        for item_id, _display_text in entries:
            kind = Result.model_validate_json(self.bus.call("GetElementKind", ("s", item_id)))
            if TEXT.validate_python(kind.data)[0] == "Text":
                raw = Result.model_validate_json(self.bus.call("GetRawElement", ("s", item_id)))
                texts.append(TEXT.validate_python(raw.data)[0])
        return texts

    def write(self, text: str) -> None:
        """Explicit platform clipboard ownership; GPaste observes normally, imports never write."""
        try:
            result = subprocess.run(self.writer, input=text.encode("utf-8"), stdout=subprocess.DEVNULL,  # noqa: S603 - fixed writer argv; text is stdin, never a shell or log.
                                    stderr=subprocess.DEVNULL, check=False, timeout=6)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise BridgeError("desktop clipboard writer unavailable") from error
        if result.returncode:
            raise BridgeError("desktop clipboard write failed; verify desktop session authorization")
