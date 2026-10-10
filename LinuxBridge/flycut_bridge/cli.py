"""Explicit archive commands; sync and clipboard writes are opt-in."""

import os
import sqlite3
import sys
import time
from pathlib import Path
from typing import Annotated, Final, assert_never

import httpx2
import typer
from pydantic import ValidationError

from .archive import Archive
from .folder import Folder
from .klipper import Klipper, Observer
from .protocol import EVENTS, BridgeError, identifier
from .query import Search, item_text, search
from .service import Service

APP: Final = typer.Typer(help=(
    "Flycut Archive V1 for Linux/KDE. Requires Python 3.12+, uv and busctl for Klipper. "
    "Run: uv run --project LinuxBridge flycut-bridge --help. Sync defaults off. "
    "Imports never copy or paste. Polling observes Klipper's text/display API, not raw MIME, "
    "and may miss changes faster than the polling interval. No CloudKit gateway. "
    "Archive/folder/service logs retain deleted text; deletion is not secure erasure."),
    pretty_exceptions_enable=False)
DEFAULT_DB: Final = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "flycut/archive.sqlite3"
Database = Annotated[Path, typer.Option("--db", help="Archive SQLite path (use an isolated path for QA).")]


@APP.command()
def init(collection: str, db: Database = DEFAULT_DB) -> None:
    """Create a new local archive with an explicitly chosen collection UUID."""
    Archive.initialize(db, collection)
    print("Archive initialized; sync remains off.")


@APP.command()
def capture(db: Database = DEFAULT_DB) -> None:
    """Capture exact UTF-8 text from stdin, including trailing newlines."""
    print(Archive(db).capture(sys.stdin.read()))


@APP.command("search")
def search_command(query: Annotated[str, typer.Argument()] = "", db: Database = DEFAULT_DB,
                   favorites: bool = False, group_duplicates: bool = False,
                   limit: Annotated[int, typer.Option(min=1, max=1000)] = 100,
                   cursor: str | None = None) -> None:
    """Return a bounded JSON page. Pass next_cursor to fetch another page."""
    page = search(Archive(db), Search(text=query, favorites=favorites, duplicates=not group_duplicates,
                                     limit=limit, cursor=cursor))
    print(page.model_dump_json())


@APP.command()
def show(item: str, db: Database = DEFAULT_DB) -> None:
    """Write one exact archive item's text to stdout without changing clipboard."""
    sys.stdout.write(item_text(Archive(db), identifier(item)))


@APP.command()
def favorite(item: str, value: bool = True, db: Database = DEFAULT_DB) -> None:
    """Set the favorite register for the selected representative item ID."""
    Archive(db).action(item, "favorite", value)
    print("Favorite updated.")


@APP.command()
def delete(item: str, db: Database = DEFAULT_DB) -> None:
    """Permanently tombstone an item. Logs/backups/Klipper may retain its text."""
    Archive(db).action(item, "delete")
    print("Item deleted from archive view; not securely erased.")


@APP.command()
def clear(db: Database = DEFAULT_DB, confirm: bool = False) -> None:
    """Delete locally known live nonfavorites; unseen offline captures may arrive later."""
    if not confirm:
        raise BridgeError(
            "use --confirm: favorites survive; unseen offline/concurrent captures may arrive later; not secure erasure")
    print(f"Deleted {Archive(db).clear()} known nonfavorites; favorites preserved.")


@APP.command()
def join(collection: str, db: Database = DEFAULT_DB, share_existing: bool = False) -> None:
    """Explicitly adopt a collection and share ALL existing events, preserving IDs."""
    if not share_existing:
        raise BridgeError("use --share-existing to explicitly share all local events with the new collection")
    Archive(db).join(collection)
    print("Collection adopted; all local events eligible for sync; checkpoints reset.")


@APP.command("import-events")
def import_events(path: Path, db: Database = DEFAULT_DB) -> None:
    """Import a JSON event array atomically, without changing the clipboard."""
    events = EVENTS.validate_json(path.read_bytes())
    print(f"Imported {Archive(db).import_events(events)} new events; clipboard unchanged.")


@APP.command("folder-init")
def folder_init(folder: Path, collection: str) -> None:
    """Create a folder manifest (never overwrite an existing manifest)."""
    Folder.initialize(folder, identifier(collection))
    print("Folder manifest created.")


def backend(folder: Path | None, server: str | None, secured_tailnet: bool) -> Folder | Service | None:
    if folder is not None and server is not None:
        raise BridgeError("select one backend only: --folder OR --server")
    if folder is not None:
        return Folder(folder)
    if server is not None:
        return Service(server, secured_tailnet)
    return None


@APP.command()
def sync(db: Database = DEFAULT_DB, folder: Path | None = None, server: str | None = None,
         secured_tailnet: bool = False, replay: bool = False) -> None:
    """Sync folder OR server. Service auth comes from sourced .env FLYCUT_SYNC_TOKEN."""
    selected = backend(folder, server, secured_tailnet)
    if selected is None:
        raise BridgeError("sync defaults off; explicitly supply --folder or --server")
    print("Syncing...", flush=True)
    match selected:
        case Folder():
            if replay:
                raise BridgeError("folder always rescans; --replay is service-only")
            sent, received, deferred = selected.sync(Archive(db))
        case Service():
            sent, received, deferred = selected.sync(Archive(db), replay)
        case _:
            assert_never(selected)
    print(f"Sync committed: uploaded={sent}, imported={received}, deferred_files={deferred}; clipboard unchanged.")


@APP.command()
def copy(item: str, db: Database = DEFAULT_DB, moves_to_top: bool = False) -> None:
    """Explicitly copy to Klipper Clipboard AND PRIMARY; never synthesize a paste key."""
    Klipper().select(Archive(db), identifier(item), moves_to_top)
    print("Copied explicitly to Clipboard/PRIMARY; paste in your target application yourself.")


@APP.command("import-klipper")
def import_klipper(db: Database = DEFAULT_DB, confirm: bool = False) -> None:
    """One-time import of Klipper display text. Separate from watch startup; no clipboard write."""
    if not confirm:
        raise BridgeError("use --confirm to import existing Klipper display history once")
    print("Importing Klipper history...", flush=True)
    print(f"Imported {Klipper().import_history(Archive(db))} entries; clipboard unchanged.")


@APP.command()
def watch(db: Database = DEFAULT_DB, interval: Annotated[float, typer.Option(min=0.1)] = 0.5,
          folder: Path | None = None, server: str | None = None,
          secured_tailnet: bool = False, cycles: Annotated[int, typer.Option(min=0)] = 0) -> None:
    """Seed current Klipper text without capture, then observe local transitions. Ctrl+C stops."""
    archive = Archive(db)
    klipper = Klipper()
    observer = Observer(archive, klipper.current())
    selected = backend(folder, server, secured_tailnet)
    print("Watching Klipper (startup seeded, not captured); sync " + ("on." if selected else "off."), flush=True)
    iteration = 0
    while cycles == 0 or iteration < cycles:
        try:
            if observer.observe(klipper.current()):
                print("Local capture committed.", flush=True)
            if selected:
                print("Syncing...", flush=True)
                sent, received, deferred = selected.sync(archive)
                print(f"Sync committed: uploaded={sent}, imported={received}, deferred_files={deferred}", flush=True)
        except (BridgeError, OSError, httpx2.HTTPError, ValidationError, sqlite3.Error):
            print("Observation/sync unavailable; will retry without advancing failed checkpoints.",
                  file=sys.stderr, flush=True)
        iteration += 1
        if cycles == 0 or iteration < cycles:
            time.sleep(interval)


def main() -> None:
    try:
        APP()
    except BridgeError as error:
        print(f"Error: {error.reason}", file=sys.stderr)
        raise SystemExit(1) from None
    except (OSError, httpx2.HTTPError, ValidationError, sqlite3.Error):
        print("Error: storage, protocol, network, or input failure; no writable fallback. Check paths/configuration.",
              file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
