"""Authenticated service transport with durable independent upload/download checkpoints."""

import os
import socket
from ipaddress import IPv4Network, ip_address
from typing import Annotated, Final

import httpx2
from pydantic import Field

from .archive import Archive
from .protocol import BridgeError, Event, Model

MAX_POST_BYTES: Final = 8 * 1024 * 1024


class Download(Model):
    events: list[Annotated[Event, Field(discriminator="op")]]
    next_cursor: str
    has_more: bool


class Accepted(Model):
    accepted: int
    inserted: int


class Service:
    def __init__(self, url: str, secured_tailnet: bool = False) -> None:
        self.url: httpx2.URL = httpx2.URL(url)
        if (self.url.scheme not in {"http", "https"} or not self.url.host or
                self.url.userinfo or self.url.query or self.url.fragment):
            raise BridgeError("service URL must be http(s), without userinfo, query or fragment")
        if self.url.scheme != "https" and self.url.host not in {"localhost", "127.0.0.1", "::1"}:
            try:
                address = ip_address(self.url.host)
            except ValueError as error:
                raise BridgeError(
                    "plaintext tailnet opt-in requires an explicit 100.64/10 IP; use HTTPS for names") from error
            if not secured_tailnet or address not in IPv4Network("100.64.0.0/10"):
                raise BridgeError("HTTPS required except loopback or explicitly secured numeric tailnet IP")
        self.token: str = os.environ.get("FLYCUT_SYNC_TOKEN", "")
        if not self.token:
            raise BridgeError("source your .env containing FLYCUT_SYNC_TOKEN before service sync")

    def sync(self, archive: Archive, replay: bool = False) -> tuple[int, int, int]:
        with archive.transaction() as db:
            collection = archive.meta(db, "collection")
        endpoint = self.url.copy_with(path=f"{self.url.path.rstrip('/')}/v1/collections/{collection}/events")
        backend = f"service:{endpoint}"
        uploaded, cursor = archive.checkpoint(backend)
        if replay:
            cursor = ""
            with archive.transaction() as db:
                db.execute("UPDATE checkpoints SET cursor='' WHERE backend=?", (backend,))
        transport = httpx2.HTTPTransport(
            http2=True, retries=3,
            limits=httpx2.Limits(max_connections=200, max_keepalive_connections=40, keepalive_expiry=30),
            socket_options=[(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)])
        sent = 0
        received = 0
        with httpx2.Client(transport=transport, trust_env=False, follow_redirects=False,
                          timeout=httpx2.Timeout(connect=5, read=30, write=10, pool=10),
                          headers={"Authorization": f"Bearer {self.token}"}) as client:
            while batch := archive.events_after(uploaded):
                encoded: list[bytes] = []
                prefix: list[tuple[int, Event]] = []
                size = 2
                for sequence, event in batch:
                    raw = event.model_dump_json().encode("utf-8")
                    addition = len(raw) + int(bool(encoded))
                    if size + addition > MAX_POST_BYTES:
                        if not prefix:
                            raise BridgeError(
                                "single event exceeds service 8 MiB body limit; use folder sync; event unacknowledged")
                        break
                    encoded.append(raw)
                    prefix.append((sequence, event))
                    size += addition
                content = b"[" + b",".join(encoded) + b"]"
                response = client.post(endpoint, content=content, headers={"Content-Type": "application/json"})
                self.check_status(response)
                accepted = Accepted.model_validate_json(response.content)
                if accepted.accepted != len(prefix):
                    raise BridgeError("server did not acknowledge the complete upload batch")
                uploaded = prefix[-1][0]
                with archive.transaction() as db:
                    db.execute("UPDATE checkpoints SET uploaded=? WHERE backend=?", (uploaded, backend))
                sent += len(prefix)
            while True:
                response = client.get(endpoint, params={"after": cursor, "limit": 200})
                self.check_status(response)
                page = Download.model_validate_json(response.content)
                if page.has_more and page.next_cursor == cursor:
                    raise BridgeError("server cursor did not advance")
                with archive.transaction() as db:
                    received += sum(archive.ingest(db, event) for event in page.events)
                    db.execute("UPDATE checkpoints SET cursor=? WHERE backend=?", (page.next_cursor, backend))
                cursor = page.next_cursor
                if not page.has_more:
                    break
        return sent, received, 0

    @staticmethod
    def check_status(response: httpx2.Response) -> None:
        if response.status_code == 409:
            raise BridgeError("server reports conflicting_event; event_id reuse is corruption")
        if response.status_code in {401, 403}:
            raise BridgeError("service authentication or collection authorization failed; check your .env grant")
        if response.status_code == 400:
            raise BridgeError("server rejected request/cursor; use sync --replay for explicit safe full replay")
        if response.status_code not in {200, 201}:
            raise BridgeError(f"sync server returned HTTP {response.status_code}; no checkpoint advanced")
