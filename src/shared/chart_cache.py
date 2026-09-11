"""Short-lived Redis cache for rendered chart PNG bytes.

Used by the Teams bot to host chart images at a public, bot-served URL
(``/charts/{id}.png``) without any new Azure infrastructure — the Bot
Service's ``/api/messages`` inbound is already public, so this route reuses
the same App Service origin, and the existing Redis cache for storage.

Keys are unguessable (``uuid4``) and short-TTL, since chart images are
ephemeral (rendered per Teams answer, not intended for long-term sharing).
TTL is configurable via ``CHART_CACHE_TTL_SECONDS`` (default 21600s/6h).
"""

import logging
import os
import uuid

from shared.token_store import build_redis_client

logger = logging.getLogger(__name__)

_DEFAULT_TTL = int(os.environ.get("CHART_CACHE_TTL_SECONDS", str(6 * 3600)))

_KEY_PREFIX = "chart:"


class ChartCache:
    """Stores/retrieves rendered chart PNG bytes in Redis, keyed by an opaque id."""

    def __init__(self):
        # Binary mode: PNG bytes are stored/returned as-is (no decode_responses).
        self._client = build_redis_client(decode_responses=False)

    def put(self, png_bytes: bytes, ttl: int = _DEFAULT_TTL) -> str:
        """Cache PNG bytes and return an opaque, unguessable chart id."""
        chart_id = uuid.uuid4().hex
        self._client.set(f"{_KEY_PREFIX}{chart_id}", png_bytes, ex=ttl)
        return chart_id

    def get(self, chart_id: str) -> bytes | None:
        """Return the cached PNG bytes for ``chart_id``, or ``None`` if missing/expired."""
        return self._client.get(f"{_KEY_PREFIX}{chart_id}")
