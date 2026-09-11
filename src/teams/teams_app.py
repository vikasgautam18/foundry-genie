"""Entry point for the Teams bot service.

Starts an aiohttp web server that receives Bot Framework messages from
Teams (via Azure Bot Service) and forwards them to the Foundry Genie agent.

Includes OAuth endpoints for U2M Databricks sign-in when
DATABRICKS_AUTH_MODE=u2m.

Run with:
    PYTHONPATH=src python -m teams.teams_app
"""

import logging
import os
import sys
from types import SimpleNamespace

from aiohttp import web
from botbuilder.integration.aiohttp import (
    CloudAdapter,
    ConfigurationBotFrameworkAuthentication,
)
from botbuilder.schema import Activity

from teams import config_teams
from teams.bot import GenieTeamsBot
from shared.databricks_oauth import (
    build_auth_url,
    exchange_code,
    generate_pkce,
)
from shared.oauth_state import verify_state_signature
from shared.token_store import RedisTokenStore

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger(__name__)

_AUTH_MODE = os.environ.get("DATABRICKS_AUTH_MODE", "oauth").lower()
_BOT_HOST = os.environ.get("BOT_PUBLIC_URL", "http://localhost:3978")

# ── Bot Framework authentication ────────────────────────────────────

VALID_APP_TYPES = {"MultiTenant", "SingleTenant", "UserAssignedMSI"}
if config_teams.BOT_APP_TYPE not in VALID_APP_TYPES:
    raise ValueError(
        f"Invalid MICROSOFT_APP_TYPE '{config_teams.BOT_APP_TYPE}'. "
        f"Expected one of: {sorted(VALID_APP_TYPES)}"
    )

logger.info("Bot auth type: %s", config_teams.BOT_APP_TYPE)

auth_configuration = SimpleNamespace(
    APP_ID=config_teams.BOT_APP_ID,
    APP_PASSWORD=config_teams.BOT_APP_PASSWORD,
    APP_TYPE=config_teams.BOT_APP_TYPE,
    APP_TENANTID=config_teams.BOT_APP_TENANT_ID,
)

AUTH = ConfigurationBotFrameworkAuthentication(configuration=auth_configuration)
ADAPTER = CloudAdapter(AUTH)


async def on_adapter_error(context, error):
    """Global error handler for the adapter."""
    logger.exception("Unhandled adapter error: %s", error)
    await context.send_activity("An internal error occurred. Please try again later.")


ADAPTER.on_turn_error = on_adapter_error

# Initialise token store for U2M mode
_token_store = RedisTokenStore() if _AUTH_MODE == "u2m" else None

BOT = GenieTeamsBot(token_store=_token_store)

# ── Routes ──────────────────────────────────────────────────────────


async def messages(req: web.Request) -> web.Response:
    """Handle incoming Bot Framework messages at /api/messages."""
    if req.content_type != "application/json":
        return web.Response(status=415)

    try:
        body = await req.json()
        activity = Activity().deserialize(body)
    except Exception:
        logger.warning("Malformed activity payload on /api/messages")
        return web.Response(status=400)

    auth_header = req.headers.get("Authorization", "")

    try:
        await ADAPTER.process_activity(auth_header, activity, BOT.on_turn)
    except PermissionError:
        # Invalid / missing Bot Framework JWT — reject cleanly.
        return web.Response(status=401)
    except Exception:
        logger.exception("Error processing Bot Framework activity")
        return web.Response(status=500)
    return web.Response(status=200)


async def health(_req: web.Request) -> web.Response:
    """Simple health-check endpoint."""
    return web.json_response({"status": "healthy"})


async def oauth_login(req: web.Request) -> web.Response:
    """Start Databricks OAuth for a Teams user via a signed *state* nonce.

    The nonce is minted by the bot and bound (server-side, in Redis) to the
    Bot-Framework-verified Teams user id. We never read a user_id from the
    query string, so a crafted link cannot bind tokens to another identity.
    """
    state = req.query.get("state", "")
    if not state or not verify_state_signature(state):
        return web.Response(text="Invalid sign-in request.", status=400)
    if not _token_store or not _token_store.has_login_state(state):
        return web.Response(
            text="Sign-in request expired. Please start again from Teams.",
            status=400,
        )

    verifier, challenge = generate_pkce()
    _token_store.save_pkce_verifier(state, verifier)

    redirect_uri = os.environ.get(
        "DATABRICKS_OAUTH_REDIRECT_URI", f"{_BOT_HOST}/oauth/callback"
    )
    auth_url = build_auth_url(
        state=state, code_challenge=challenge, redirect_uri=redirect_uri
    )
    raise web.HTTPFound(auth_url)


async def oauth_callback(req: web.Request) -> web.Response:
    """Handle redirect from Databricks after user signs in."""
    code = req.query.get("code")
    state = req.query.get("state")

    if not code or not state or not verify_state_signature(state):
        return web.Response(text="Invalid OAuth callback.", status=400)

    # Atomically consume the single-use nonce -> verified user id + PKCE verifier.
    user_id = _token_store.consume_login_state(state) if _token_store else None
    verifier = _token_store.consume_pkce_verifier(state) if _token_store else None
    if not user_id or not verifier:
        return web.Response(
            text="Sign-in session expired or already used. Please try again from Teams.",
            status=400,
        )

    try:
        tokens = exchange_code(code=code, code_verifier=verifier)
    except Exception:
        logger.exception("OAuth code exchange failed for user %s", user_id)
        return web.Response(text="Sign-in failed. Please try again.", status=500)

    _token_store.save_tokens(
        user_id=user_id,
        access_token=tokens["access_token"],
        refresh_token=tokens.get("refresh_token", ""),
        expires_in=tokens.get("expires_in", 3600),
    )

    logger.info("OAuth sign-in complete for Teams user %s", user_id)
    return web.Response(
        text="<html><body><h2>Signed in to Databricks!</h2>"
             "<p>You can close this window and return to Teams.</p>"
             "</body></html>",
        content_type="text/html",
    )


# Keep the variable name `app` so gunicorn auto-detection works
app = web.Application()
app.router.add_post("/api/messages", messages)
app.router.add_get("/api/health", health)
app.router.add_get("/", health)

# OAuth routes (U2M mode)
if _AUTH_MODE == "u2m":
    app.router.add_get("/oauth/login", oauth_login)
    app.router.add_get("/oauth/callback", oauth_callback)
    logger.info("U2M OAuth routes registered")

if __name__ == "__main__":
    logger.info("Starting Teams bot on port %s", config_teams.PORT)
    web.run_app(app, host="0.0.0.0", port=config_teams.PORT)
