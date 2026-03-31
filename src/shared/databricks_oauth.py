"""Databricks OAuth U2M (User-to-Machine) helpers.

Implements the OAuth 2.0 Authorization Code flow with PKCE for
Databricks, as described in:
    https://docs.databricks.com/en/dev-tools/auth/oauth-u2m.html

Requires env vars:
    DATABRICKS_HOST              — workspace hostname (no https://)
    DATABRICKS_OAUTH_CLIENT_ID   — from Databricks Account Console
    DATABRICKS_OAUTH_CLIENT_SECRET — from Key Vault / env
"""

import base64
import hashlib
import logging
import os
import secrets
import time

import requests

from shared.token_store import RedisTokenStore

logger = logging.getLogger(__name__)


def _env(name: str, default: str | None = None) -> str:
    val = os.environ.get(name, default)
    if val is None:
        raise ValueError(f"{name} is not configured.")
    return val


# ── PKCE helpers ────────────────────────────────────────────────────


def generate_pkce() -> tuple[str, str]:
    """Generate a PKCE code_verifier and code_challenge (S256)."""
    verifier = secrets.token_urlsafe(64)
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return verifier, challenge


def generate_state() -> str:
    """Generate a random state string for CSRF protection."""
    return secrets.token_urlsafe(32)


# ── URL builders ────────────────────────────────────────────────────


def build_auth_url(
    state: str,
    code_challenge: str,
    redirect_uri: str | None = None,
) -> str:
    """Construct the Databricks OAuth authorization URL."""
    host = _env("DATABRICKS_HOST")
    client_id = _env("DATABRICKS_OAUTH_CLIENT_ID")
    redirect = redirect_uri or _env("DATABRICKS_OAUTH_REDIRECT_URI")

    return (
        f"https://{host}/oidc/v1/authorize?"
        f"client_id={client_id}&"
        f"response_type=code&"
        f"redirect_uri={redirect}&"
        f"scope=all-apis%20offline_access&"
        f"code_challenge={code_challenge}&"
        f"code_challenge_method=S256&"
        f"state={state}"
    )


# ── Token exchange ──────────────────────────────────────────────────


def exchange_code(
    code: str,
    code_verifier: str,
    redirect_uri: str | None = None,
) -> dict:
    """Exchange an authorization code for access + refresh tokens.

    Returns dict with: access_token, refresh_token, expires_in, token_type.
    """
    host = _env("DATABRICKS_HOST")
    client_id = _env("DATABRICKS_OAUTH_CLIENT_ID")
    client_secret = _env("DATABRICKS_OAUTH_CLIENT_SECRET")
    redirect = redirect_uri or _env("DATABRICKS_OAUTH_REDIRECT_URI")

    resp = requests.post(
        f"https://{host}/oidc/v1/token",
        data={
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "client_id": client_id,
            "client_secret": client_secret,
            "code_verifier": code_verifier,
        },
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    logger.info("Exchanged auth code for tokens (expires_in=%s)", data.get("expires_in"))
    return data


def refresh_access_token(refresh_token: str) -> dict:
    """Use a refresh token to get a new access token.

    Returns dict with: access_token, refresh_token, expires_in, token_type.
    """
    host = _env("DATABRICKS_HOST")
    client_id = _env("DATABRICKS_OAUTH_CLIENT_ID")
    client_secret = _env("DATABRICKS_OAUTH_CLIENT_SECRET")

    resp = requests.post(
        f"https://{host}/oidc/v1/token",
        data={
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": client_id,
            "client_secret": client_secret,
        },
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    logger.info("Refreshed access token (expires_in=%s)", data.get("expires_in"))
    return data


# ── High-level token accessor ──────────────────────────────────────


def get_valid_token(user_id: str, store: RedisTokenStore) -> str | None:
    """Return a valid Databricks access token for the user.

    Refreshes automatically if the token is near expiry. Returns None
    if the user has never signed in.
    """
    tokens = store.get_tokens(user_id)
    if tokens is None:
        return None

    # Token still fresh — return it
    if time.time() < (tokens["expires_at"] - 300):
        return tokens["access_token"]

    # Try to refresh
    try:
        new_tokens = refresh_access_token(tokens["refresh_token"])
        store.save_tokens(
            user_id=user_id,
            access_token=new_tokens["access_token"],
            refresh_token=new_tokens.get("refresh_token", tokens["refresh_token"]),
            expires_in=new_tokens.get("expires_in", 3600),
        )
        return new_tokens["access_token"]
    except Exception:
        logger.exception("Token refresh failed for user %s", user_id)
        # Refresh token may be expired — user must re-authenticate
        store.delete_tokens(user_id)
        return None
