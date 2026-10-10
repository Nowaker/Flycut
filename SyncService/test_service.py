"""Live-process contract checks with isolated SQLite and ephemeral .env grants."""

import copy
import base64
import json
import secrets
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from http.client import HTTPConnection
from pathlib import Path
from urllib.parse import urlencode
from uuid import uuid4

from SyncService.protocol import JSON, PROTOCOL


class ServiceTests(unittest.TestCase):
    def __init__(self, methodName: str = "runTest") -> None:
        super().__init__(methodName)
        self.sandbox = tempfile.TemporaryDirectory()
        self.root = Path(self.sandbox.name)
        self.collection = str(uuid4())
        self.other = str(uuid4())
        self.token = secrets.token_urlsafe(32)
        self.other_token = secrets.token_urlsafe(32)
        self.process: subprocess.Popen[str] | None = None
        self.port = 0

    def setUp(self) -> None:
        env_file = self.root / ".env"
        env_file.write_text("FLYCUT_SYNC_GRANTS=" + json.dumps({self.token: [self.collection], self.other_token: [self.other]}), encoding="utf-8")
        env_file.chmod(0o600)
        self.start()

    def start(self) -> None:
        self.process = subprocess.Popen(self.command(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, cwd=Path(__file__).resolve().parent.parent)
        if self.process.stdout is None:
            self.fail("Missing process readiness pipe")
        line = self.process.stdout.readline()
        self.assertTrue(line.startswith("Flycut sync listening on 127.0.0.1:"), "Service failed readiness")
        self.port = int(line.strip().rsplit(":", 1)[1])

    def command(self) -> list[str]:
        return [sys.executable, "-m", "SyncService.server",
            "--port", "0", "--database", str(self.root / "events.sqlite"),
            "--env-file", str(self.root / ".env"), "--collection", self.collection,
            "--collection", self.other]

    def stop(self) -> None:
        process = self.process
        assert process is not None
        process.terminate()
        output, errors = process.communicate(timeout=10)
        self.assertNotIn(self.token, output + errors)
        self.assertNotIn("private clipboard test", output + errors)
        self.assertEqual(errors, "")

    def tearDown(self) -> None:
        self.stop()
        self.sandbox.cleanup()

    def event(self, clock: str = "1") -> dict[str, JSON]:
        event_id = str(uuid4())
        return {"protocol": PROTOCOL, "version": 1, "collection_id": self.collection,
            "event_id": event_id, "device_id": str(uuid4()), "clock": clock,
            "op": "create", "item_id": event_id, "payload": {"text": "private clipboard test",
            "content_type": "text/plain", "captured_at_ms": None, "source_app": None,
            "source_id": None, "favorite": False}}

    def request(self, method: str, options: dict[str, JSON]) -> tuple[int, JSON]:
        connection = HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            collection = options.get("collection", self.collection)
            path = options.get("path", f"/v1/collections/{collection}/events")
            assert isinstance(path, str)
            headers = {"Content-Type": "application/json"}
            token = options.get("token", self.token)
            if isinstance(token, str):
                headers["Authorization"] = "Bearer " + token
            body = json.dumps(options["body"]) if "body" in options else None
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def page(self, after: str = "", limit: int = 200) -> dict[str, JSON]:
        status, result = self.request("GET", {"path": f"/v1/collections/{self.collection}/events?" + urlencode({"after": after, "limit": limit})})
        self.assertEqual(status, 200)
        assert isinstance(result, dict)
        return result

    def test_late_lower_clock_is_delivered(self) -> None:
        high, low = self.event("999"), self.event("1")
        self.assertEqual(self.request("POST", {"body": [high]})[0], 200)
        cursor = self.page()["next_cursor"]
        assert isinstance(cursor, str)
        self.assertEqual(self.request("POST", {"body": [low]})[0], 200)
        self.assertEqual(self.page(cursor)["events"], [low])

    def test_equivalent_retry_is_idempotent(self) -> None:
        event = self.event()
        self.request("POST", {"body": [event]})
        reordered = dict(reversed(list(event.items())))
        self.assertEqual(self.request("POST", {"body": [reordered]}), (200, {"accepted": 1, "inserted": 0}))
        self.assertEqual(self.page()["events"], [event])

    def test_conflict_rolls_back_entire_batch(self) -> None:
        original = self.event()
        self.request("POST", {"body": [original]})
        conflicting = copy.deepcopy(original)
        conflicting["clock"] = "2"
        self.assertEqual(self.request("POST", {"body": [self.event(), conflicting]})[0], 409)
        self.assertEqual(self.page()["events"], [original])

    def test_invalid_event_rolls_back_entire_batch(self) -> None:
        invalid = self.event()
        invalid["version"] = True
        self.assertEqual(self.request("POST", {"body": [self.event(), invalid]})[0], 400)
        self.assertEqual(self.page()["events"], [])

    def test_authorization_isolates_reads_writes_discovery(self) -> None:
        for method in ("GET", "POST"):
            self.assertEqual(self.request(method, {"token": None, "body": [self.event()]})[0], 401)
            self.assertEqual(self.request(method, {"token": "invalid", "body": [self.event()]})[0], 401)
            self.assertEqual(self.request(method, {"collection": self.other, "body": [self.event()]})[0], 403)
        status, result = self.request("GET", {"path": "/v1/collections"})
        self.assertEqual((status, result), (200, {"collections": [{"protocol": PROTOCOL, "version": 1, "collection_id": self.collection}]}))
        self.assertEqual(self.page()["events"], [])

    def test_events_and_cursor_survive_restart(self) -> None:
        first, second = self.event(), self.event()
        self.request("POST", {"body": [first, second]})
        cursor = self.page(limit=1)["next_cursor"]
        assert isinstance(cursor, str)
        self.stop()
        self.start()
        self.assertEqual(self.page(cursor)["events"], [second])

    def test_explicit_sharing_preserves_ids_across_collections(self) -> None:
        original = self.event()
        self.request("POST", {"body": [original]})
        shared = {**original, "collection_id": self.other}
        self.assertEqual(self.request("POST", {"collection": self.other, "token": self.other_token, "body": [shared]}), (200, {"accepted": 1, "inserted": 1}))
        self.assertEqual(self.page()["events"], [original])
        self.assertEqual(self.request("GET", {"collection": self.other, "token": self.other_token})[0], 200)
        conflict = {**shared, "clock": "2"}
        self.assertEqual(self.request("POST", {"collection": self.other, "token": self.other_token, "body": [conflict]})[0], 409)

    def test_paging_has_no_gaps_and_enforces_bounds(self) -> None:
        events: list[JSON] = [self.event() for _ in range(205)]
        self.request("POST", {"body": events})
        first = self.page()
        self.assertEqual(first["events"], events[:200])
        self.assertTrue(first["has_more"])
        cursor = first["next_cursor"]
        assert isinstance(cursor, str)
        last = self.page(cursor)
        self.assertEqual(last["events"], events[200:])
        self.assertFalse(last["has_more"])
        for limit in (0, 1001):
            self.assertEqual(self.request("GET", {"path": f"/v1/collections/{self.collection}/events?limit={limit}"})[0], 400)

    def test_invalid_cursor_requires_explicit_replay(self) -> None:
        self.assertEqual(self.request("GET", {"path": f"/v1/collections/{self.collection}/events?after=bad"}), (400, {"error": "invalid_cursor", "replay_required": True}))
        status, result = self.request("GET", {"collection": self.other, "token": self.other_token})
        self.assertEqual(status, 200)
        assert isinstance(result, dict)
        foreign = result["next_cursor"]
        assert isinstance(foreign, str)
        self.assertEqual(self.request("GET", {"path": f"/v1/collections/{self.collection}/events?" + urlencode({"after": foreign})})[0], 400)

    def test_oversized_cursor_requires_explicit_replay(self) -> None:
        cursor = self.page()["next_cursor"]
        assert isinstance(cursor, str)
        raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode()
        oversized = base64.urlsafe_b64encode((raw.rsplit(":", 1)[0] + ":9223372036854775808").encode()).decode().rstrip("=")
        self.assertEqual(self.request("GET", {"path": f"/v1/collections/{self.collection}/events?" + urlencode({"after": oversized})}), (400, {"error": "invalid_cursor", "replay_required": True}))

    def test_restore_rotation_rejects_reused_sequence_cursor(self) -> None:
        self.request("POST", {"body": [self.event()]})
        with sqlite3.connect(self.root / "events.sqlite") as source, sqlite3.connect(self.root / "backup.sqlite") as backup:
            source.backup(backup)
        self.request("POST", {"body": [self.event()]})
        old_cursor = self.page()["next_cursor"]
        assert isinstance(old_cursor, str)
        self.stop()
        with sqlite3.connect(self.root / "backup.sqlite") as backup, sqlite3.connect(self.root / "events.sqlite") as destination:
            backup.backup(destination)
        rotated = subprocess.run(self.command() + ["--rotate-cursor-identity"], capture_output=True, text=True,
            cwd=Path(__file__).resolve().parent.parent, timeout=10, check=True)
        self.assertEqual(rotated.stderr, "")
        self.start()
        self.request("POST", {"body": [self.event()]})
        self.assertEqual(self.request("GET", {"path": f"/v1/collections/{self.collection}/events?" + urlencode({"after": old_cursor})}), (400, {"error": "invalid_cursor", "replay_required": True}))


if __name__ == "__main__":
    unittest.main()
