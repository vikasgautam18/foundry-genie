"""Per-user Databricks token store backed by Azure Redis Cache.

Stores OAuth tokens (access_token, refresh_token, expires_at) per user
so each user's Genie queries run under their own Databricks identity.

Authentication (selected by env):
  - REDIS_USE_ENTRA=true  → Microsoft Entra ID via the App Service managed
    identity (required when the cache has access-key auth disabled). Needs
    REDIS_HOST (and optional REDIS_PORT, default 6380).
  - otherwise             → REDIS_URL key-based connection string, e.g.
    ``rediss://:password@host:6380/0`` (local dev / docker-compose).
"""

import base64
import json
import logging
import os
import time

import redis

logger = logging.getLogger(__name__)

# Default TTL for stored tokens (7 days — covers refresh token lifetime)
_DEFAULT_TTL = 7 * 24 * 3600

# Entra token audience for Azure Cache for Redis / Azure Managed Redis.
_REDIS_ENTRA_RESOURCE = "https://redis.azure.com/"


def _truthy(val: str | None) -> bool:
    return (val or "").strip().lower() in ("1", "true", "yes", "on")


class RedisTokenStore:
    """Manages per-user Databricks OAuth tokens in Redis."""

    def __init__(self, redis_url: str | None = None):
        if _truthy(os.environ.get("REDIS_USE_ENTRA")):
            self._client = self._connect_entra()
            logger.info("RedisTokenStore connected (entra)")
        else:
            url = redis_url or os.environ.get("REDIS_URL")
            if not url:
                raise ValueError(
                    "Redis is not configured. Set REDIS_USE_ENTRA=true (with "
                    "REDIS_HOST) for managed-identity auth, or REDIS_URL for "
                    "key-based auth."
                )
            self._client = redis.from_url(url, decode_responses=True)
            logger.info("RedisTokenStore connected (key)")

    @staticmethod
    def _connect_entra() -> "redis.Redis":
        """Build a redis client authenticated with a managed-identity Entra token.

        Uses ``azure-identity`` directly (ManagedIdentityCredential on Azure hosts,
        which correctly uses the App Service / Container Apps MSI endpoint) via a
        redis-py CredentialProvider, with socket timeouts so a network or token
        problem fails fast with a clear error instead of hanging the request.
        """
        from azure.identity import ManagedIdentityCredential, DefaultAzureCredential
        from redis.credentials import CredentialProvider

        host = os.environ.get("REDIS_HOST")
        if not host:
            raise ValueError("REDIS_HOST is required when REDIS_USE_ENTRA=true.")
        port = int(os.environ.get("REDIS_PORT", "6380"))
        client_id = os.environ.get("AZURE_CLIENT_ID")

        # On Azure (App Service / ACA) use the managed identity endpoint directly;
        # locally fall back to DefaultAzureCredential (az login, etc.).
        if os.environ.get("WEBSITE_INSTANCE_ID") or os.environ.get("CONTAINER_APP_NAME"):
            credential = (
                ManagedIdentityCredential(client_id=client_id)
                if client_id else ManagedIdentityCredential()
            )
        else:
            credential = DefaultAzureCredential()

        class _EntraCredentialProvider(CredentialProvider):
            """Returns (username=object-id, password=Entra token) for Redis AUTH."""

            def get_credentials(self):
                token = credential.get_token(f"{_REDIS_ENTRA_RESOURCE}.default").token
                # Azure Cache for Redis expects the identity's object id (oid) as
                # the ACL username; extract it from the token's claims.
                payload = token.split(".")[1]
                payload += "=" * (-len(payload) % 4)
                oid = json.loads(base64.urlsafe_b64decode(payload)).get("oid", "")
                return (oid, token)

        return redis.Redis(
            host=host,
            port=port,
            ssl=True,
            credential_provider=_EntraCredentialProvider(),
            decode_responses=True,
            socket_connect_timeout=10,
            socket_timeout=10,
            retry_on_timeout=True,
            health_check_interval=30,
        )

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

    # ── Sign-in state (Teams U2M security fix) ───────────────────────
    # A short-lived, single-use mapping from an opaque signed state nonce to the
    # Bot-Framework-verified Teams user id, so the browser never carries user_id.

    # Atomic GET+DELETE that works on Redis 6.0 (GETDEL needs 6.2+).
    _GETDEL_LUA = "local v = redis.call('GET', KEYS[1]); if v then redis.call('DEL', KEYS[1]) end; return v"

    def _getdel(self, key: str) -> str | None:
        """Atomically fetch-and-delete a key (Redis 6.0-compatible via Lua)."""
        return self._client.eval(self._GETDEL_LUA, 1, key)

    def save_login_state(self, state: str, user_id: str, ttl: int = 300) -> None:
        """Bind an opaque state nonce to a verified user id (short TTL)."""
        self._client.set(f"login_state:{state}", user_id, ex=ttl)

    def has_login_state(self, state: str) -> bool:
        """True if the state nonce is still pending (not consumed/expired)."""
        return self._client.exists(f"login_state:{state}") == 1

    def consume_login_state(self, state: str) -> str | None:
        """Atomically fetch-and-delete the user id bound to a state nonce."""
        return self._getdel(f"login_state:{state}")

    def save_pkce_verifier(self, state: str, verifier: str, ttl: int = 300) -> None:
        """Store the PKCE code_verifier keyed by state (short TTL)."""
        self._client.set(f"login_pkce:{state}", verifier, ex=ttl)

    def consume_pkce_verifier(self, state: str) -> str | None:
        """Atomically fetch-and-delete the PKCE verifier for a state nonce."""
        return self._getdel(f"login_pkce:{state}")

    # ── Conversation → agent thread map (multi-worker safe) ──────────

    def save_thread(self, conversation_id: str, thread_id: str,
                    ttl: int = 7 * 24 * 3600) -> None:
        """Persist the Foundry thread id for a Teams conversation."""
        self._client.set(f"thread:{conversation_id}", thread_id, ex=ttl)

    def get_thread(self, conversation_id: str) -> str | None:
        """Return the Foundry thread id for a Teams conversation, if any."""
        return self._client.get(f"thread:{conversation_id}")
