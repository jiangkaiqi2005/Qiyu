#!/usr/bin/env python3
"""Send local images or image URLs to Qwen3.5-Flash for visual analysis."""

from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import os
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


API_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
MODEL = "qwen3.5-flash"
API_KEY_ENV_NAME = "QWEN35_FLASH_API_KEY"
SUPPORTED_MIME_TYPES = {
    "image/bmp",
    "image/heic",
    "image/jpeg",
    "image/png",
    "image/tiff",
    "image/webp",
}
MAX_RAW_BYTES = 20 * 1024 * 1024
MAX_DATA_URL_BYTES = 20 * 1024 * 1024


def get_api_key() -> str:
    value = os.environ.get(API_KEY_ENV_NAME)
    if value:
        return value
    raise ValueError(f"No API key found. Set environment variable: {API_KEY_ENV_NAME}")


def encode_image(source: str) -> str:
    if source.startswith(("http://", "https://")):
        return source

    path = Path(source).expanduser()
    if not path.is_file():
        raise ValueError(f"Image file does not exist or is not a file: {path}")

    mime_type, _ = mimetypes.guess_type(path.name)
    if mime_type not in SUPPORTED_MIME_TYPES:
        supported = ", ".join(sorted(SUPPORTED_MIME_TYPES))
        raise ValueError(f"Unsupported image type for {path}. Supported MIME types: {supported}")

    raw = path.read_bytes()
    if len(raw) > MAX_RAW_BYTES:
        raise ValueError(f"Image exceeds the 20 MB raw-file API limit: {path}")
    data_url = f"data:{mime_type};base64,{base64.b64encode(raw).decode('ascii')}"
    if len(data_url.encode("ascii")) > MAX_DATA_URL_BYTES:
        raise ValueError(f"Base64 data URL exceeds the 20 MB API limit: {path}")
    return data_url


def build_payload(images: list[str], prompt: str) -> dict[str, object]:
    content: list[dict[str, object]] = [
        {"type": "image_url", "image_url": {"url": encode_image(image)}}
        for image in images
    ]
    content.append({"type": "text", "text": prompt})
    return {
        "model": MODEL,
        "messages": [{"role": "user", "content": content}],
        "enable_thinking": False,
    }


def extract_answer(response: dict[str, object]) -> str:
    try:
        choices = response["choices"]
        message = choices[0]["message"]  # type: ignore[index]
        content = message["content"]  # type: ignore[index]
    except (KeyError, IndexError, TypeError) as exc:
        raise ValueError("API response did not contain choices[0].message.content") from exc

    if isinstance(content, str) and content.strip():
        return content
    if isinstance(content, list):
        parts = [item.get("text", "") for item in content if isinstance(item, dict)]
        answer = "".join(part for part in parts if isinstance(part, str))
        if answer:
            return answer
    raise ValueError("API response content was empty or had an unsupported format")


def parse_api_error(body: str) -> str:
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        return body.strip() or "No response body"

    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict):
            return str(error.get("message") or error)
        if isinstance(error, str):
            return error
        return str(payload.get("message") or payload)
    return str(payload)


def analyze(images: list[str], prompt: str, timeout: float) -> str:
    payload = json.dumps(build_payload(images, prompt), ensure_ascii=False).encode("utf-8")
    request = Request(
        API_URL,
        data=payload,
        headers={
            "Authorization": f"Bearer {get_api_key()}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urlopen(request, timeout=timeout) as response:
            data = json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"DashScope API returned HTTP {exc.code}: {parse_api_error(body)}") from exc
    except URLError as exc:
        raise RuntimeError(f"Could not reach the DashScope API: {exc.reason}") from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError("DashScope API returned invalid JSON") from exc

    if not isinstance(data, dict):
        raise RuntimeError("DashScope API returned an unexpected JSON value")
    return extract_answer(data)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Analyze one or more images with Qwen3.5-Flash."
    )
    parser.add_argument(
        "--image",
        action="append",
        required=True,
        help="Local image path or HTTP(S) URL. Repeat for multiple images.",
    )
    parser.add_argument("--prompt", required=True, help="Specific question about the image(s).")
    parser.add_argument(
        "--timeout",
        type=float,
        default=120.0,
        help="HTTP timeout in seconds (default: 120).",
    )
    args = parser.parse_args()

    try:
        answer = analyze(args.image, args.prompt, args.timeout)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print(answer)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
