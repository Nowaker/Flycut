"""Status-only DBus errors; payloads remain inside parsed adapter responses."""

import shutil
import subprocess
from contextlib import closing
from typing import Final, Literal

from jeepney import DBusAddress, new_method_call
from jeepney.io.blocking import open_dbus_connection
from jeepney.wrappers import DBusErrorResponse, unwrap_msg
from pydantic import JsonValue, TypeAdapter

from .protocol import BridgeError, Model


class Result(Model):
    type: str
    data: list[JsonValue]


BOOLEAN: Final = TypeAdapter(tuple[bool])
ReadMethod = Literal["NameHasOwner", "getClipboardContents", "getClipboardHistoryMenu",
                     "GetHistory", "GetRawElement", "GetElementKind"]


class Bus:
    def __init__(self, service: str, interface: str, path: str) -> None:
        executable = shutil.which("busctl")
        if executable is None:
            raise BridgeError("busctl required; install systemd DBus tools on Linux")
        self.executable: str = executable
        self.service: str = service
        self.interface: str = interface
        self.path: str = path

    def call(self, method: ReadMethod, arguments: tuple[str, ...] = ()) -> str:
        command = (self.executable, "--user", "--json=short", "--timeout=5", "call",
                   self.service, self.path, self.interface, method, *arguments)
        try:
            result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=6)  # noqa: S603 - fixed DBus endpoint/argv, never a shell.
        except (OSError, subprocess.TimeoutExpired) as error:
            raise BridgeError("clipboard DBus unavailable; verify your logged-in desktop session") from error
        if result.returncode:
            raise BridgeError("clipboard manager/API unavailable; verify GPaste2 or Klipper is running")
        return result.stdout

    def text(self, method: Literal["setClipboardContents", "Add"], value: str) -> None:
        """Send confidential clipboard text over the session socket, never subprocess argv."""
        if "\0" in value:
            raise BridgeError("DBus text cannot contain NUL; use archive show to retrieve exact content")
        address = DBusAddress(self.path, bus_name=self.service, interface=self.interface)
        message = new_method_call(address, method, "s", (value,))
        try:
            with closing(open_dbus_connection(bus="SESSION")) as connection:
                reply = connection.send_and_get_reply(message, timeout=5)
                unwrap_msg(reply)
        except (OSError, DBusErrorResponse, KeyError) as error:
            raise BridgeError("native clipboard DBus call failed; verify the desktop session") from error

    @staticmethod
    def owns(service: str) -> bool:
        bus = Bus("org.freedesktop.DBus", "org.freedesktop.DBus", "/org/freedesktop/DBus")
        result = Result.model_validate_json(bus.call("NameHasOwner", ("s", service)))
        return BOOLEAN.validate_python(result.data)[0]
