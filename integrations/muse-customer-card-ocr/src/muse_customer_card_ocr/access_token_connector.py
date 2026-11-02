from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal, Mapping, Protocol


@dataclass(frozen=True, repr=False)
class QueryParamAccessTokenOcrRequest:
    """Package-internal OCR request for Vault-injected query-param auth.

    The request names the fixed authentication mode but contains no access
    token or caller-controlled query parameters. The connector resolves its
    protected credential outside this Python package.
    """

    request_id: str
    method: Literal["POST"]
    url: str
    auth_mode: Literal["query_param:access_token"]
    headers: Mapping[str, str]
    body: bytes = field(repr=False)
    timeout_seconds: float

    def __repr__(self) -> str:
        return (
            "QueryParamAccessTokenOcrRequest("
            f"request_id={self.request_id!r}, method={self.method!r}, "
            f"url={self.url!r}, auth_mode={self.auth_mode!r}, "
            "body=<redacted>)"
        )


@dataclass(frozen=True, repr=False)
class QueryParamAccessTokenOcrResponse:
    status_code: int
    body: bytes = field(repr=False)

    def __repr__(self) -> str:
        return (
            "QueryParamAccessTokenOcrResponse("
            f"status_code={self.status_code}, body=<redacted>)"
        )


class SecureQueryParamAccessTokenConnector(Protocol):
    """Injected connector port; it adds only ``access_token`` from secure storage.

    This is an internal package interface, not a claim about MUSE's Python API.
    """

    def send(
        self, request: QueryParamAccessTokenOcrRequest
    ) -> QueryParamAccessTokenOcrResponse:
        ...
