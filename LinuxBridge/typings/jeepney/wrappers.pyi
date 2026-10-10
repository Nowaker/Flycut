from pydantic import JsonValue

from . import Message

class DBusErrorResponse(Exception): ...

def unwrap_msg(msg: Message) -> tuple[JsonValue, ...]: ...
