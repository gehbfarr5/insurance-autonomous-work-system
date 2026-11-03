"""Adapter for the already-deployed Seoul OCR CLI; no direct OCR transport."""
from __future__ import annotations

import json
import subprocess
from collections.abc import Callable
from typing import Any


SEOUL_SSH_SCRIPT = "/home/hatch/workspace/server/ssh-seoul.sh"
SEOUL_SERVICE = "/home/ubuntu/baidu-ocr-service/baidu_ocr_service.py"


class SeoulCliError(RuntimeError):
    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


def run_seoul_ocr(
    image_bytes: bytes,
    *,
    command_runner: Callable[..., Any] = subprocess.run,
) -> dict[str, Any]:
    """Send one already-authorized image to the existing Seoul service."""
    if not isinstance(image_bytes, bytes) or not image_bytes:
        raise SeoulCliError("OCR_IMAGE_INVALID")
    completed = command_runner(
        [SEOUL_SSH_SCRIPT, f"python3 {SEOUL_SERVICE} --stdin-image"],
        input=image_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=120,
        check=False,
    )
    if completed.returncode != 0:
        raise SeoulCliError("SEOUL_CLI_FAILED")
    try:
        payload = json.loads(completed.stdout.decode("utf-8"))
    except (AttributeError, UnicodeDecodeError, json.JSONDecodeError):
        raise SeoulCliError("SEOUL_CLI_INVALID_RESPONSE") from None
    if not isinstance(payload, dict):
        raise SeoulCliError("SEOUL_CLI_INVALID_RESPONSE")
    return payload
