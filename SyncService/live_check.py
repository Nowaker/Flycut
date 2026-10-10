"""Cross-machine QA using sourced client .env; never prints credentials or bodies."""

import argparse
import json
import os
from http.client import HTTPConnection
from pathlib import Path
from urllib.parse import urlencode, urlsplit
from uuid import uuid4

from SyncService.protocol import JSON, PROTOCOL, parse_json


class Client:
    def __init__(self) -> None:
        url = urlsplit(os.environ["FLYCUT_SYNC_URL"])
        assert url.scheme == "http" and url.hostname is not None and url.port is not None
        self.host, self.port = url.hostname, url.port
        self.collection = os.environ["FLYCUT_SYNC_COLLECTION"]
        self.token = os.environ["FLYCUT_SYNC_TOKEN"]
        self.path = f"/v1/collections/{self.collection}/events"

    def request(self, method: str, path: str, body: JSON = None) -> tuple[int, JSON]:
        connection = HTTPConnection(self.host, self.port, timeout=15)
        try:
            connection.request(method, path, body=json.dumps(body).encode() if body is not None else None,
                headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
            response = connection.getresponse()
            return response.status, parse_json(response.read())
        finally:
            connection.close()

    def page(self, after: str = "", limit: int = 200) -> dict[str, JSON]:
        status, page = self.request("GET", self.path + "?" + urlencode({"after": after, "limit": limit}))
        assert status == 200 and isinstance(page, dict)
        events = page["events"]
        assert isinstance(events, list) and len(events) <= limit
        return page

    def event(self, clock: str) -> dict[str, JSON]:
        event_id = str(uuid4())
        return {"protocol": PROTOCOL, "version": 1, "collection_id": self.collection,
            "event_id": event_id, "device_id": str(uuid4()), "clock": clock, "op": "create",
            "item_id": event_id, "payload": {"text": "Flycut GPT synthetic deployment QA",
            "content_type": "text/plain", "captured_at_ms": None, "source_app": None,
            "source_id": None, "favorite": False}}

    def prepare(self, state: Path) -> None:
        connection = HTTPConnection(self.host, self.port, timeout=15)
        try:
            connection.request("GET", self.path)
            response = connection.getresponse()
            assert response.status == 401
            response.read()
        finally:
            connection.close()
        assert self.request("GET", f"/v1/collections/{uuid4()}/events")[0] == 403
        assert self.request("GET", "/v1/collections")[0] == 200
        high, low = self.event("999"), self.event("1")
        assert self.request("POST", self.path, [high]) == (200, {"accepted": 1, "inserted": 1})
        high_page = self.page(limit=1000)
        while high_page["has_more"]:
            cursor = high_page["next_cursor"]
            assert isinstance(cursor, str)
            high_page = self.page(cursor, 1000)
        checkpoint = high_page["next_cursor"]
        assert isinstance(checkpoint, str)
        assert self.request("POST", self.path, [low]) == (200, {"accepted": 1, "inserted": 1})
        assert self.request("POST", self.path, [low]) == (200, {"accepted": 1, "inserted": 0})
        delivered = self.page(checkpoint)["events"]
        assert isinstance(delivered, list) and low in delivered
        candidate = self.event("3")
        assert self.request("POST", self.path, [candidate, {**high, "clock": "1000"}])[0] == 409
        invalid = {**candidate, "version": True}
        assert self.request("POST", self.path, [candidate, invalid])[0] == 400
        page = self.page(checkpoint)
        events = page["events"]
        assert isinstance(events, list) and candidate not in events
        assert self.request("GET", self.path + "?after=invalid") == (400, {"error": "invalid_cursor", "replay_required": True})
        assert self.request("GET", self.path + "?limit=1001")[0] == 400
        single = self.page(limit=1)
        assert single["has_more"] is True
        state.write_text(json.dumps({"checkpoint": checkpoint, "high": high, "low": low}), encoding="utf-8")
        print("Remote QA before restart: auth 401/403; discovery 200; ingestion/retry 200; conflicts 409; invalid atomic batch/cursor/limit 400; lower-clock delivery and bounded pages PASS")

    def verify(self, state: Path) -> None:
        saved = parse_json(state.read_bytes())
        assert isinstance(saved, dict)
        checkpoint, low, high = saved["checkpoint"], saved["low"], saved["high"]
        assert isinstance(checkpoint, str) and isinstance(low, dict) and isinstance(high, dict)
        events = self.page(checkpoint)["events"]
        assert isinstance(events, list) and low in events
        tombstones: list[JSON] = []
        for create in (high, low):
            tombstones.append({"protocol": PROTOCOL, "version": 1, "collection_id": self.collection,
                "event_id": str(uuid4()), "device_id": str(uuid4()), "clock": "1001", "op": "delete",
                "item_id": create["item_id"], "payload": {}})
        assert self.request("POST", self.path, tombstones) == (200, {"accepted": 2, "inserted": 2})
        print("Remote QA after restart: prior cursor valid and delayed event durable PASS; synthetic captures hidden via durable delete events (no pruning)")


def main() -> None:
    parser = argparse.ArgumentParser(description="Source/export client .env first. Prepare, restart remote service, then verify; synthetic captures are tombstoned on verify.")
    parser.add_argument("phase", choices=("prepare", "verify"))
    parser.add_argument("--state", type=Path, required=True, help="Owned QA checkpoint file, contains no credentials")
    args = parser.parse_args()
    client = Client()
    if args.phase == "prepare":
        client.prepare(args.state)
    else:
        client.verify(args.state)


if __name__ == "__main__":
    main()
