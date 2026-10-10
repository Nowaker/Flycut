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
    for public_url in ("http://203.0.113.1:19787", "http://example.com:19787", "http://[2001:db8::1]:19787"):
        try:
            Service(public_url, secured_tailnet=True)
        except BridgeError:
            pass
        else:
            raise BridgeError("plaintext public URL accepted by secured-tailnet option")
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
            large_ids = [b.capture(f"{run_id}-large-{index} " + "é" * (250 * 1024)) for index in range(20)]
            try:
                service.sync(b)
                service.sync(a)
                require(len(search(a, Search(text=run_id + "-large-")).items) == 20,
                        "UTF-8 byte-bounded multi-batch upload lost large events")
            finally:
                for item_id in large_ids:
                    b.action(item_id, "delete")
                service.sync(b)
                service.sync(a)
            Archive.initialize(root / "oversize.sqlite3", collection)
            oversized = Archive(root / "oversize.sqlite3")
            oversized.capture("synthetic unsupported-size clip " + "x" * (9 * 1024 * 1024))
            try:
                service.sync(oversized)
            except BridgeError:
                with oversized.transaction(write=False) as db:
                    require(db.execute("SELECT 1 FROM checkpoints WHERE uploaded<>0").fetchone() is None,
                            "unsupported-size event was acknowledged")
            else:
                raise BridgeError("single oversized event accepted by service client")
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
          "invalid cursor rejection/explicit replay, 20 large UTF-8 clips split by 8 MiB body bytes, " +
          "single oversized event unacknowledged, late upload, exact owned tombstone cleanup; no clipboard writes.")


if __name__ == "__main__":
    main()
