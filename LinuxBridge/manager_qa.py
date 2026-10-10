# /// script
# requires-python = ">=3.12"
# dependencies = ["pydantic>=2.10,<3", "jeepney>=0.9,<0.10", "httpx2[http2,brotli,zstd]>=2.13.1,<3"]
# ///
# Run only inside task-owned DBus/Xvfb: FLYCUT_ISOLATED_QA=1 uv run LinuxBridge/manager_qa.py
"""Real GPaste/X11 adapter QA, refusing the real Cinnamon desktop bus."""

import os
import selectors
import shutil
import subprocess
import sys
import time
from pathlib import Path
from tempfile import TemporaryDirectory

from flycut_bridge.archive import Archive
from flycut_bridge.clipboard import Manager, Observer, manager
from flycut_bridge.dbus import Bus
from flycut_bridge.folder import Folder
from flycut_bridge.protocol import BridgeError
from flycut_bridge.query import Search, search
from flycut_bridge.service import Service


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise BridgeError(reason)


def signal(fd: int, marker: bytes) -> None:
    deadline = time.monotonic() + 20
    received = b""
    with selectors.DefaultSelector() as selector:
        selector.register(fd, selectors.EVENT_READ)
        while marker not in received:
            remaining = deadline - time.monotonic()
            require(remaining > 0 and bool(selector.select(timeout=max(remaining, 0))),
                    "GPaste signal wait timed out")
            chunk = os.read(fd, 65536)
            require(bool(chunk), "GPaste signal monitor exited")
            received += chunk


def write(desktop: Manager, text: str, fd: int) -> None:
    desktop.write(text)
    signal(fd, b"Update")


def cli(arguments: list[str]) -> str:
    uv = shutil.which("uv")
    if uv is None:
        raise BridgeError("uv required for real CLI QA")
    command = [uv, "run", "--project", str(Path(__file__).parent), "flycut-bridge", *arguments]
    result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=120)  # noqa: S603 - task-owned fixed CLI, no shell.
    require(result.returncode == 0, "real bridge CLI failed inside isolated desktop")
    return result.stdout


def exercise(fd: int) -> None:
    desktop = manager("auto")
    require(desktop.name == "GPaste", "GPaste was not autodetected")
    write(desktop, "synthetic startup seed", fd)
    Bus("org.gnome.GPaste", "org.gnome.GPaste2", "/org/gnome/GPaste").text(
        "Add", "synthetic confidential native canary")
    signal(fd, b"Update")
    require(desktop.current() == "synthetic confidential native canary", "native DBus setter failed")
    with TemporaryDirectory(prefix="flycut-manager-qa-") as temporary:
        root = Path(temporary)
        shared_service = os.environ.get("FLYCUT_CROSS_HOST_QA") == "1"
        collection = os.environ["FLYCUT_SYNC_COLLECTION"] if shared_service else "10000000-0000-0000-0000-000000000001"
        a_path, b_path = root / "a.sqlite3", root / "b.sqlite3"
        Archive.initialize(a_path, collection)
        Archive.initialize(b_path, collection)
        a, b = Archive(a_path), Archive(b_path)
        observer = Observer(a, desktop.current(), desktop)
        require(observer.observe(desktop.current()) is None, "actual desktop startup was recaptured")
        write(desktop, "synthetic observed text\r\nexact whitespace 😀\n", fd)
        capture = observer.observe(desktop.current())
        if capture is None:
            raise BridgeError("real clipboard transition did not capture")
        require(observer.observe(desktop.current()) is None, "real repeated clipboard value recaptured")
        require(search(a, Search()).items[0].payload.text == "synthetic observed text\r\nexact whitespace 😀\n",
                "actual clipboard whitespace was altered")
        remote = b.capture("synthetic remote archive clip")
        Folder.initialize(root / "shared", collection)
        folder = Folder(root / "shared")
        current = desktop.current()
        folder.sync(b)
        folder.sync(a)
        folder.sync(a)
        require(desktop.current() == current, "incoming folder clips changed actual clipboard")
        require(observer.observe(desktop.current()) is None, "remote folder import echoed to capture")
        count = len(a.events_after(0))
        print(cli(["copy", remote, "--db", str(a_path), "--desktop", "auto"]).strip())
        signal(fd, b"Update")
        require(desktop.current() == "synthetic remote archive clip", "explicit CLI copy failed")
        require(observer.observe(desktop.current()) is None, "explicit CLI copy echoed into new create")
        require(len(a.events_after(0)) == count, "explicit copy emitted an unrequested event")
        imported_path = root / "imported.sqlite3"
        Archive.initialize(imported_path, collection)
        current = desktop.current()
        print(cli(["import-history", "--confirm", "--db", str(imported_path)]).strip())
        require(bool(search(Archive(imported_path), Search()).items), "real GPaste text history not imported")
        require(desktop.current() == current, "history import changed actual clipboard")
        watched_path = root / "watched.sqlite3"
        Archive.initialize(watched_path, collection)
        print(cli(["watch", "--cycles", "1", "--db", str(watched_path)]).strip())
        require(not search(Archive(watched_path), Search()).items, "CLI watcher recaptured startup seed")
        if shared_service:
            cross_host(a, b, (capture, remote))
    print("Actual isolated GPaste/X11 QA passed: autodetect, local capture, exact text, no import echo, " +
          "explicit CLI copy suppression, one-time native history import, seeded CLI watcher.")


def cross_host(a: Archive, b: Archive, owned: tuple[str, str]) -> None:
    service = Service(os.environ["FLYCUT_SYNC_URL"], secured_tailnet=True)
    try:
        service.sync(a)
        service.sync(b)
        print(f"SERVICE_READY {owned[0]} {owned[1]}", flush=True)
        require(sys.stdin.readline().strip() == "ACK", "cross-host coordinator acknowledgement missing")
        service.sync(a)
        require(any(item.item_id == owned[0] for item in search(
            a, Search(text="synthetic observed", favorites=True)).items),
                "Mac favorite failed to converge back to Linux")
    finally:
        a.action(owned[0], "delete")
        b.action(owned[1], "delete")
        service.sync(a)
        service.sync(b)
        service.sync(a)
    print("SERVICE_CLEANED", flush=True)


def main() -> None:
    require(os.environ.get("FLYCUT_ISOLATED_QA") == "1", "isolated desktop QA authorization missing")
    require(not Bus.owns("org.Cinnamon"), "refusing user's real Cinnamon desktop bus")
    executable = shutil.which("gdbus")
    if executable is None:
        raise BridgeError("gdbus required for actual signal-driven QA")
    arguments = [executable, "monitor", "--session", "--dest", "org.gnome.GPaste",
                 "--object-path", "/org/gnome/GPaste"]
    with subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as monitor:  # noqa: S603 - fixed status-only monitor on isolated DBus.
        try:
            if monitor.stdout is None:
                raise BridgeError("signal monitor pipe missing")
            fd = monitor.stdout.fileno()
            signal(fd, b"is owned by")
            exercise(fd)
        finally:
            monitor.terminate()
            try:
                monitor.wait(timeout=5)
            except subprocess.TimeoutExpired:
                monitor.kill()
                monitor.wait(timeout=5)


if __name__ == "__main__":
    main()
