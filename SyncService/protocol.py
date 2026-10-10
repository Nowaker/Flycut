"""Strict Flycut archive wire parsing. No clipboard or reducer side effects."""

import json
import re
from dataclasses import dataclass
from typing import Final, TypeAlias
from uuid import UUID

JSON: TypeAlias = None | bool | int | float | str | list['JSON'] | dict[str, 'JSON']
PROTOCOL: Final = "net.nowaker.flycut.events"
MAX_CLOCK: Final = 9223372036854775807


@dataclass(frozen=True, slots=True)
class Failure(Exception):
    status: int
    code: str


@dataclass(frozen=True, slots=True)
class Event:
    event_id: str
    collection_id: str
    encoded: str


def uuid_string(value: JSON) -> str:
    if not isinstance(value, str):
        raise Failure(400, "invalid_uuid")
    try:
        parsed = UUID(value)
    except ValueError:
        raise Failure(400, "invalid_uuid") from None
    if str(parsed) != value:
        raise Failure(400, "invalid_uuid")
    return value


def unique_fields(pairs: list[tuple[str, JSON]]) -> dict[str, JSON]:
    result: dict[str, JSON] = {}
    for key, value in pairs:
        if key in result:
            raise Failure(400, "duplicate_json_key")
        result[key] = value
    return result


def parse_json(raw: bytes | str) -> JSON:
    try:
        text = raw.decode("utf-8") if isinstance(raw, bytes) else raw
        return json.loads(text, object_pairs_hook=unique_fields)
    except (ValueError, UnicodeError, RecursionError):
        raise Failure(400, "invalid_json") from None


def parse_event(raw: JSON, collection: str) -> Event:
    keys = {"protocol", "version", "collection_id", "event_id", "device_id",
            "clock", "op", "item_id", "payload"}
    if not isinstance(raw, dict) or set(raw) != keys:
        raise Failure(400, "invalid_event_shape")
    if raw["protocol"] != PROTOCOL or type(raw["version"]) is not int or raw["version"] != 1:
        raise Failure(400, "unsupported_protocol")
    for field in ("collection_id", "event_id", "device_id", "item_id"):
        uuid_string(raw[field])
    if raw["collection_id"] != collection:
        raise Failure(400, "collection_mismatch")
    clock = raw["clock"]
    if not isinstance(clock, str) or re.fullmatch(r"[1-9][0-9]{0,18}", clock) is None:
        raise Failure(400, "invalid_clock")
    if int(clock) > MAX_CLOCK:
        raise Failure(400, "invalid_clock")
    payload = raw["payload"]
    if not isinstance(payload, dict):
        raise Failure(400, "invalid_payload")
    match raw["op"]:
        case "create":
            if set(payload) != {"text", "content_type", "captured_at_ms", "source_app", "source_id", "favorite"}:
                raise Failure(400, "invalid_payload")
            if raw["item_id"] != raw["event_id"]:
                raise Failure(400, "invalid_create_id")
            if not isinstance(payload["text"], str) or not payload["text"]:
                raise Failure(400, "invalid_text")
            if payload["content_type"] != "text/plain" or type(payload["favorite"]) is not bool:
                raise Failure(400, "invalid_payload")
            captured = payload["captured_at_ms"]
            if captured is not None and (type(captured) is not int or not -MAX_CLOCK - 1 <= captured <= MAX_CLOCK):
                raise Failure(400, "invalid_timestamp")
            for field in ("source_app", "source_id"):
                if payload[field] is not None and not isinstance(payload[field], str):
                    raise Failure(400, "invalid_source")
        case "favorite":
            if set(payload) != {"value"} or type(payload["value"]) is not bool:
                raise Failure(400, "invalid_payload")
        case "touch" | "delete":
            if payload:
                raise Failure(400, "invalid_payload")
        case _:
            raise Failure(400, "unsupported_operation")
    try:
        encoded = json.dumps(raw, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
        encoded.encode("utf-8")
    except (ValueError, UnicodeError):
        raise Failure(400, "invalid_unicode") from None
    return Event(uuid_string(raw["event_id"]), collection, encoded)


def parse_batch(raw: bytes, collection: str) -> list[Event]:
    values = parse_json(raw)
    if not isinstance(values, list) or not 1 <= len(values) <= 1000:
        raise Failure(400, "invalid_batch")
    return [parse_event(value, collection) for value in values]
