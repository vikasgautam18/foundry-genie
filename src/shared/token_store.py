"""Per-user Databricks token store backed by Azure Redis Cache.

Stores OAuth tokens (access_token, refresh_token, expires_at) per user
so each user's Genie queries run under their own Databricks identity.

Requires:
    REDIS_URL — Redis connection string (e.g. rediss://:password@host:6380/0)
"""

import json
import logging
import os
import time

import redis

logger = logging.getLogger(__name__)

# Default TTL for stored tokens (7 days — covers refresh token lifetime)
_DEFAULT_TTL = 7 * 24 * 3600


class RedisTokenStore:
    """Manages per-user Databricks OAuth tokens in Redis."""

    def __init__(self, redis_url: str | None = None):
        url = redis_url or os.environ.get("REDIS_URL")
        if not url:
            raise ValueError("REDIS_URL is not configured.")
        self._client = redis.from_url(url, decode_responses=True)
        logger.info("RedisTokenStore connected")

    def _key(self, user_id: str) -> str:
        return f"dbx_token:{user_id}"

    def save_tokens(
        self,
        user_id: str,
        access_token: str,
        refresh_token: str,
        expires_in: int = 3600,
    ) -> None:
        """Persist a user's Databricks OAuth tokens."""
        data = {
            "access_token": access_token,
            "refresh_token": refresh_token,
            "expires_at": time.time() + expires_in,
        }
        self._client.set(self._key(user_id), json.dumps(data), ex=_DEFAULT_TTL)
        logger.info("Saved tokens for user %s (expires_in=%ds)", user_id, expires_in)

    def get_tokens(self, user_id: str) -> dict | None:
        """Retrieve a user's stored tokens, or None if not found."""
        raw = self._client.get(self._key(user_id))
        if raw is None:
            return None
        return json.loads(raw)

    def has_valid_token(self, user_id: str) -> bool:
        """Check if the user has a token (may need refresh, but exists)."""
        return self.get_tokens(user_id) is not None

    def is_token_fresh(self, user_id: str, margin: float = 300) -> bool:
        """Check if the user's access token is still valid (with margin)."""
        tokens = self.get_tokens(user_id)
        if tokens is None:
            return False
        return time.time() < (tokens["expires_at"] - margin)

    def delete_tokens(self, user_id: str) -> None:
        """Remove a user's tokens (logout)."""
        self._client.delete(self._key(user_id))
        logger.info("Deleted tokens for user %s", user_id)
