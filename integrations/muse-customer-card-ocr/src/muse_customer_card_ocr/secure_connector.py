from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal, Mapping, Protocol


@dataclass(frozen=True, repr=False)
class BearerOcrRequest:
    """Package-internal port request for a secret-injecting Bearer connector.

    The package has a separate stdio/helper adapter, but this remains an
    internal interface rather than MUSE's Secure Vault wire/API contract. The
    real MUSE binding must follow its documented interface. The request contains
    no token or Authorization header.
    """

    request_id: str
    method: Literal["POST"]
    url: str
    auth_scheme: Literal["bearer"]
    headers: Mapping[str, str]
    body: bytes = field(repr=False)
    timeout_seconds: float

    def __repr__(self) -> str:
        return (
            "BearerOcrRequest("
            f"request_id={self.request_id!r}, method={self.method!r}, "
            f"url={self.url!r}, auth_scheme={self.auth_scheme!r}, "
            "body=<redacted>)"
        )


@dataclass(frozen=True, repr=False)
class BearerOcrResponse:
    status_code: int
    body: bytes = field(repr=False)

    def __repr__(self) -> str:
        return f"BearerOcrResponse(status_code={self.status_code}, body=<redacted>)"


class SecureBearerConnector(Protocol):
    """Injected transport port; the implementation attaches Bearer auth.

    The production credential must stay in the connector's protected store,
    outside this Python package. This Protocol defines only an internal seam.
    """

    def send(self, request: BearerOcrRequest) -> BearerOcrResponse:
        """Send one request and return a redacted-response wrapper."""
        ...
