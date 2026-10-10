# Typed subset of Jeepney 0.9's actual API, not replacement runtime behavior.

class Message: ...

class DBusAddress:
    def __init__(self, object_path: str, *, bus_name: str, interface: str) -> None: ...

def new_method_call(
    remote_obj: DBusAddress, method: str, signature: str, body: tuple[str, ...]
) -> Message: ...
