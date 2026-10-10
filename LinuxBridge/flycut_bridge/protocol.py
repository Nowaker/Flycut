"""Strict, structured parsing of the shared Flycut event protocol."""

from typing import Annotated, ClassVar, Final, Literal, Self
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, field_validator, model_validator

PROTOCOL: Final = "net.nowaker.flycut.events"
MAX_CLOCK: Final = 9223372036854775807
Identifier = Annotated[str, Field(pattern=r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")]


class BridgeError(Exception):
    """An actionable boundary failure, without payloads or credentials."""

    def __init__(self, reason: str) -> None:
        self.reason: str = reason
        super().__init__(reason)


class Model(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True, extra="forbid")


class Manifest(Model):
    protocol: Literal["net.nowaker.flycut.events"]
    version: Literal[1]
    collection_id: Identifier

    @field_validator("version", mode="before")
    @classmethod
    def integer_version(cls, value: int) -> int:
        if type(value) is not int:
            raise BridgeError("version must be an integer")
        return value


class CreatePayload(Model):
    text: Annotated[str, Field(min_length=1)]
    content_type: Literal["text/plain"]
    captured_at_ms: Annotated[int, Field(ge=-9223372036854775808, le=MAX_CLOCK)] | None
    source_app: str | None
    source_id: str | None
    favorite: bool


class FavoritePayload(Model):
    value: bool


class EmptyPayload(Model):
    pass


class Envelope(Manifest):
    event_id: Identifier
    device_id: Identifier
    clock: Annotated[str, Field(pattern=r"^[1-9][0-9]*$")]
    item_id: Identifier

    @field_validator("clock")
    @classmethod
    def bounded_clock(cls, value: str) -> str:
        if len(value) > 19 or int(value) > MAX_CLOCK:
            raise BridgeError("clock outside signed 64-bit range")
        return value


class CreateEvent(Envelope):
    op: Literal["create"]
    payload: CreatePayload

    @model_validator(mode="after")
    def same_item(self) -> Self:
        if self.event_id != self.item_id:
            raise BridgeError("create item_id must equal event_id")
        return self


class FavoriteEvent(Envelope):
    op: Literal["favorite"]
    payload: FavoritePayload


class TouchEvent(Envelope):
    op: Literal["touch"]
    payload: EmptyPayload


class DeleteEvent(Envelope):
    op: Literal["delete"]
    payload: EmptyPayload


Event = CreateEvent | FavoriteEvent | TouchEvent | DeleteEvent
EVENT: Final = TypeAdapter(Annotated[Event, Field(discriminator="op")])
EVENTS: Final = TypeAdapter(list[Annotated[Event, Field(discriminator="op")]])


def identifier(value: str) -> str:
    """Parse CLI identifiers without accepting alternate UUID spellings."""
    try:
        parsed = str(UUID(value))
    except ValueError as error:
        raise BridgeError("expected lowercase UUID") from error
    if parsed != value:
        raise BridgeError("expected lowercase UUID")
    return parsed
