"""Signed, single-use OAuth *state* nonce helpers for the Teams sign-in flow.

Fixes the identity-binding vulnerability where a caller-supplied ``user_id`` in
the sign-in URL could bind Databricks tokens to an arbitrary user. Instead, the
bot issues an opaque, HMAC-signed nonce that maps — server-side in Redis — to
the Bot-Framework-verified Teams user id. The browser never sees a user_id.

Requires:
    OAUTH_STATE_HMAC_SECRET — random secret (>= 32 chars) shared by the bot and
                              the OAuth web endpoints (injected from Key Vault).
"""

import hashlib
import hmac
import os
import secrets


def _secret() -> bytes:
    val = os.environ.get("OAUTH_STATE_HMAC_SECRET")
    if not val:
        raise ValueError("OAUTH_STATE_HMAC_SECRET is not configured.")
    return val.encode("utf-8")


def generate_signed_state() -> str:
    """Return an opaque ``<nonce>.<hmac>`` state string (256-bit nonce)."""
    nonce = secrets.token_urlsafe(32)
    sig = hmac.new(_secret(), nonce.encode("ascii"), hashlib.sha256).hexdigest()
    return f"{nonce}.{sig}"


def verify_state_signature(state: str) -> bool:
    """Constant-time verify the HMAC of a signed state string."""
    try:
        nonce, sig = state.rsplit(".", 1)
    except (ValueError, AttributeError):
        return False
    expected = hmac.new(_secret(), nonce.encode("ascii"), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, sig)
