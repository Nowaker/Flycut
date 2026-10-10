# /// script
# requires-python = ">=3.12"
# dependencies = ["pydantic>=2.10,<3", "httpx2[http2,brotli,zstd]>=2.13.1,<3"]
# ///
# Run after sourcing client .env: uv run LinuxBridge/service_qa.py
"""Real service replay/convergence QA using only owned synthetic items, then tombstones."""

import os
from pathlib import Path
from tempfile import TemporaryDirectory
from uuid import uuid4

from flycut_bridge.archive import Archive
from flycut_bridge.protocol import BridgeError
from flycut_bridge.query import Search, search
from flycut_bridge.service import Service


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise BridgeError(reason)


def main() -> None:
    collection = os.environ["FLYCUT_SYNC_COLLECTION"]
    service = Service(os.environ["FLYCUT_SYNC_URL"], secured_tailnet=True)
    run_id = f"flycut-linux-qa-{uuid4()}"
    with TemporaryDirectory(prefix="flycut-service-qa-") as temporary:
        root = Path(temporary)
        Archive.initialize(root / "a.sqlite3", collection)
        Archive.initialize(root / "b.sqlite3", collection)
        a, b = Archive(root / "a.sqlite3"), Archive(root / "b.sqlite3")
        owned_a = a.capture(run_id + "-a")
        owned_b = b.capture(run_id + "-b")
        try:
            service.sync(a)
            service.sync(b)
            service.sync(a)
            require(search(a, Search(text=run_id)).items == search(b, Search(text=run_id)).items,
                    "real server peers failed convergence")
            require(len(search(a, Search(text=run_id)).items) == 2, "real server lost synthetic capture")
            a.action(owned_b, "favorite", favorite=True)
            service.sync(a)
            service.sync(b)
            require(search(b, Search(text=run_id, favorites=True)).items[0].item_id == owned_b,
                    "favorite register did not converge")
            service.sync(b, replay=True)
            require(len(search(b, Search(text=run_id)).items) == 2, "full replay duplicated items")
            backend = f"service:{service.url.copy_with(path=f'/v1/collections/{collection}/events')}"
            with b.transaction() as db:
                db.execute("UPDATE checkpoints SET cursor='invalid' WHERE backend=?", (backend,))
            try:
                service.sync(b)
            except BridgeError:
                pass
            else:
                raise BridgeError("invalid server cursor was silently accepted")
            service.sync(b, replay=True)
            late = a.capture(run_id + "-late")
            try:
                service.sync(a)
                service.sync(b)
                require(search(b, Search(text=run_id + "-late")).items[0].item_id == late,
                        "late upload did not arrive via insertion cursor")
            finally:
                a.action(late, "delete")
        finally:
            a.action(owned_a, "delete")
            b.action(owned_b, "delete")
            service.sync(a)
            service.sync(b)
            service.sync(a)
        require(not search(a, Search(text=run_id)).items, "owned synthetic items remain visible")
        require(not search(b, Search(text=run_id)).items, "peer synthetic cleanup did not converge")
    print("Real HTTP service QA passed: two-device convergence, favorite, idempotent replay, " +
          "invalid cursor rejection/explicit replay, late upload, exact owned tombstone cleanup; no clipboard writes.")


if __name__ == "__main__":
    main()
