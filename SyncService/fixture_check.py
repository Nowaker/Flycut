"""Run: python3 -m SyncService.fixture_check path/to/archive-v1.json."""

import copy
import sys
import tempfile
from pathlib import Path

from SyncService.protocol import Failure, JSON, parse_event, parse_json, uuid_string
from SyncService.storage import Store


def check_fixture(path: Path) -> None:
    fixture = parse_json(path.read_bytes())
    assert isinstance(fixture, dict)
    collection = uuid_string(fixture["collection_id"])
    cases, invalids = fixture["cases"], fixture["invalid_variants"]
    assert isinstance(cases, list) and isinstance(invalids, list)
    deliveries_checked = 0
    for case in cases:
        assert isinstance(case, dict)
        events, deliveries = case["events"], case["deliveries"]
        assert isinstance(events, list) and isinstance(deliveries, list)
        for delivery in deliveries:
            assert isinstance(delivery, list)
            with tempfile.TemporaryDirectory() as directory:
                store = Store(Path(directory) / "events.sqlite", (collection,))
                expected: list[JSON] = []
                seen: set[str] = set()
                for index in delivery:
                    assert type(index) is int
                    event = parse_event(events[index], collection)
                    store.ingest([event])
                    if event.event_id not in seen:
                        expected.append(events[index])
                        seen.add(event.event_id)
                page = store.page(collection, "", 1000)
                assert page["events"] == expected
                assert len(expected) == case["expected_event_count"]
                deliveries_checked += 1
    for variant in invalids:
        assert isinstance(variant, dict)
        case_index, event_index = variant["base_case"], variant["base_event"]
        assert type(case_index) is int and type(event_index) is int
        case = cases[case_index]
        assert isinstance(case, dict)
        events = case["events"]
        assert isinstance(events, list)
        event = copy.deepcopy(events[event_index])
        assert isinstance(event, dict)
        changes = variant.get("replace", {})
        assert isinstance(changes, dict)
        event.update(changes)
        payload_changes = variant.get("payload_replace", {})
        assert isinstance(payload_changes, dict)
        payload = event["payload"]
        assert isinstance(payload, dict)
        payload.update(payload_changes)
        try:
            parse_event(event, collection)
        except Failure:
            continue
        raise AssertionError(f"Invalid variant accepted: {variant['name']}")
    print(f"Shared fixture passed: {deliveries_checked} durable delivery orders; {len(invalids)} rejected variants")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: python3 -m SyncService.fixture_check path/to/archive-v1.json")
    check_fixture(Path(sys.argv[1]))
