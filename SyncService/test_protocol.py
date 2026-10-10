"""Malformed wire events are rejected before any durable ingestion."""

import json
import unittest
from uuid import uuid4

from SyncService.protocol import Failure, JSON, PROTOCOL, parse_batch, parse_json


class ProtocolTests(unittest.TestCase):
    def test_malformed_fields_are_rejected(self) -> None:
        collection, event_id = str(uuid4()), str(uuid4())
        valid: dict[str, JSON] = {"protocol": PROTOCOL, "version": 1,
            "collection_id": collection, "event_id": event_id, "device_id": str(uuid4()),
            "clock": "9223372036854775807", "op": "create", "item_id": event_id,
            "payload": {"text": "exact \n text", "content_type": "text/plain",
                "captured_at_ms": 0, "source_app": "", "source_id": None, "favorite": False}}
        cases: list[tuple[str, JSON]] = [("version", True), ("version", 2),
            ("clock", 1), ("clock", "0"), ("clock", "-1"), ("clock", "9223372036854775808"),
            ("clock", "1.0"), ("collection_id", str(uuid4())), ("op", "undelete"),
            ("item_id", str(uuid4())), ("device_id", "BAD"),
            ("payload", {"text": ""}), ("payload", {"value": 1})]
        for field, value in cases:
            with self.subTest(field=field, value=value):
                changed = {**valid, field: value}
                with self.assertRaises(Failure):
                    parse_batch(json.dumps([changed]).encode(), collection)

    def test_all_operations_preserve_exact_text(self) -> None:
        collection, item = str(uuid4()), str(uuid4())
        operations: list[JSON] = []
        for op in ("create", "favorite", "touch", "delete"):
            event_id = item if op == "create" else str(uuid4())
            payload: dict[str, JSON] = {}
            if op == "create":
                payload = {"text": " \n text \u0000 \U0001f680", "content_type": "text/plain",
                    "captured_at_ms": None, "source_app": None, "source_id": None, "favorite": True}
            if op == "favorite":
                payload = {"value": False}
            operations.append({"protocol": PROTOCOL, "version": 1,
                "collection_id": collection, "event_id": event_id, "device_id": str(uuid4()),
                "clock": "1", "op": op, "item_id": item, "payload": payload})
        parsed = parse_batch(json.dumps(operations).encode(), collection)
        self.assertEqual([parse_json(event.encoded) for event in parsed], operations)

    def test_duplicate_fields_are_rejected(self) -> None:
        with self.assertRaises(Failure):
            parse_json('{"clock":"1","clock":"2"}')

    def test_non_utf8_json_is_rejected(self) -> None:
        for encoding in ("utf-16", "utf-32"):
            with self.subTest(encoding=encoding), self.assertRaises(Failure):
                parse_json('[{"clock":"1"}]'.encode(encoding))

    def test_surrogate_text_is_rejected(self) -> None:
        collection, item = str(uuid4()), str(uuid4())
        event: dict[str, JSON] = {"protocol": PROTOCOL, "version": 1,
            "collection_id": collection, "event_id": item, "device_id": str(uuid4()),
            "clock": "1", "op": "create", "item_id": item,
            "payload": {"text": "\ud800", "content_type": "text/plain",
                "captured_at_ms": None, "source_app": None, "source_id": None, "favorite": False}}
        with self.assertRaises(Failure):
            parse_batch(json.dumps([event]).encode(), collection)


if __name__ == "__main__":
    unittest.main()
