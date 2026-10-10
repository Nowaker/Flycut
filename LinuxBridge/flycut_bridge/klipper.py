"""Optional KDE Klipper text/display adapter; imported events never invoke write."""

from typing import Final

from pydantic import TypeAdapter

from .dbus import Bus, Result

TEXT: Final = TypeAdapter(tuple[str])
HISTORY: Final = TypeAdapter(tuple[list[str]])


class Klipper:
    def __init__(self) -> None:
        self.name: Final = "Klipper"
        self.source_id: Final = "org.kde.klipper"
        self.bus: Bus = Bus(self.source_id, "org.kde.klipper.klipper", "/klipper")

    def current(self) -> str:
        result = Result.model_validate_json(self.bus.call("getClipboardContents"))
        return TEXT.validate_python(result.data)[0]

    def history(self) -> list[str]:
        result = Result.model_validate_json(self.bus.call("getClipboardHistoryMenu"))
        return HISTORY.validate_python(result.data)[0]

    def write(self, text: str) -> None:
        """KDE's explicit setter writes both Clipboard and PRIMARY Selection."""
        self.bus.text("setClipboardContents", text)
