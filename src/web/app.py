"""
Chainlit web application that wraps the Foundry Genie MCP agent.
Each user session gets its own conversation thread.

Supports two Databricks auth modes (DATABRICKS_AUTH_MODE):
  - 'oauth' / 'pat' (M2M): no user sign-in required
  - 'u2m': each user signs into Databricks via OAuth PKCE

Run with:
    PYTHONPATH=src chainlit run src/web/app.py --host 0.0.0.0 --port 8000
"""

import logging
import os
import uuid

import chainlit as cl
from chainlit.server import app as fastapi_app
from starlette.requests import Request
from starlette.responses import RedirectResponse, HTMLResponse

from shared.agent_rest import GenieMcpAgent, AgentConfig
from shared.databricks_oauth import (
    build_auth_url,
    exchange_code,
    generate_pkce,
    generate_state,
    get_valid_token,
)
from shared.token_store import RedisTokenStore

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(name)-28s  %(levelname)-7s  %(message)s",
)
logger = logging.getLogger(__name__)

_AUTH_MODE = os.environ.get("DATABRICKS_AUTH_MODE", "oauth").lower()
_IS_U2M = _AUTH_MODE == "u2m"

# ── Token store (U2M only) ───────────────────────────────────────
_token_store: RedisTokenStore | None = None

def _get_token_store() -> RedisTokenStore:
    global _token_store
    if _token_store is None:
        _token_store = RedisTokenStore()
    return _token_store

# ── In-memory PKCE state (short-lived, per auth flow) ────────────
_pending_auth: dict[str, dict] = {}

# ── Singleton agent instance (shared across all sessions) ────────
_agent: GenieMcpAgent | None = None


def _get_agent() -> GenieMcpAgent:
    global _agent
    if _agent is None or _agent._agent is None:
        cfg = AgentConfig()
        agent = GenieMcpAgent(cfg)
        agent._agents_client.__enter__()
        agent.setup()
        _agent = agent
        logger.info("Agent initialised (id=%s)", _agent._agent.id)
    return _agent


# ── OAuth routes (mounted on Chainlit's FastAPI app) ─────────────

if _IS_U2M:
    @fastapi_app.get("/oauth/login")
    async def oauth_login(request: Request):
        """Redirect user to Databricks OAuth sign-in."""
        verifier, challenge = generate_pkce()
        state = generate_state()
        _pending_auth[state] = {"code_verifier": verifier}
        auth_url = build_auth_url(state=state, code_challenge=challenge)
        return RedirectResponse(auth_url)

    @fastapi_app.get("/oauth/callback")
    async def oauth_callback(request: Request):
        """Handle redirect from Databricks after user signs in."""
        code = request.query_params.get("code")
        state = request.query_params.get("state")

        if not code or not state or state not in _pending_auth:
            return HTMLResponse("<h3>Invalid OAuth callback. Please try signing in again.</h3>", status_code=400)

        verifier = _pending_auth.pop(state)["code_verifier"]

        try:
            tokens = exchange_code(code=code, code_verifier=verifier)
        except Exception as e:
            logger.exception("OAuth code exchange failed")
            return HTMLResponse(f"<h3>Sign-in failed: {e}</h3>", status_code=500)

        user_id = str(uuid.uuid4())
        store = _get_token_store()
        store.save_tokens(
            user_id=user_id,
            access_token=tokens["access_token"],
            refresh_token=tokens.get("refresh_token", ""),
            expires_in=tokens.get("expires_in", 3600),
        )

        response = RedirectResponse("/")
        response.set_cookie("dbx_user_id", user_id, httponly=True, secure=True, max_age=7 * 86400)
        logger.info("OAuth sign-in complete for user %s", user_id)
        return response

    @fastapi_app.get("/oauth/logout")
    async def oauth_logout(request: Request):
        """Clear user's Databricks tokens."""
        user_id = request.cookies.get("dbx_user_id")
        if user_id:
            _get_token_store().delete_tokens(user_id)
        response = RedirectResponse("/")
        response.delete_cookie("dbx_user_id")
        return response


# ── Chainlit lifecycle hooks ─────────────────────────────────────


@cl.on_chat_start
async def on_chat_start():
    """Called when a new user opens the chat."""
    agent = _get_agent()
    thread_id = agent.create_thread()
    cl.user_session.set("thread_id", thread_id)

    # In U2M mode, check for Databricks sign-in
    if _IS_U2M:
        user_id = cl.user_session.get("dbx_user_id")
        if not user_id:
            # Try to read from the HTTP request cookie
            http_request = cl.user_session.get("http_request")
            if http_request:
                user_id = http_request.cookies.get("dbx_user_id")
            if user_id:
                cl.user_session.set("dbx_user_id", user_id)

        store = _get_token_store()
        if not user_id or not store.has_valid_token(user_id):
            await cl.Message(
                content=(
                    "**Databricks sign-in required**\n\n"
                    "To access campaign data with your own permissions, "
                    "please [sign in to Databricks](/oauth/login).\n\n"
                    "After signing in you'll be redirected back here."
                )
            ).send()
            return

    await cl.Message(
        content=(
            "**Welcome to the Market Campaign Assistant!**\n\n"
            "I can answer questions about your campaign data — "
            "performance metrics, ROI, spend breakdowns, audience "
            "segments, and more.\n\n"
            "Just type your question below to get started."
        )
    ).send()


@cl.on_message
async def on_message(message: cl.Message):
    """Called when the user sends a message."""
    agent = _get_agent()
    thread_id = cl.user_session.get("thread_id")

    if thread_id is None:
        thread_id = agent.create_thread()
        cl.user_session.set("thread_id", thread_id)

    # Resolve user token for U2M mode
    user_token = None
    if _IS_U2M:
        user_id = cl.user_session.get("dbx_user_id")
        if not user_id:
            http_request = cl.user_session.get("http_request")
            if http_request:
                user_id = http_request.cookies.get("dbx_user_id")
                cl.user_session.set("dbx_user_id", user_id)

        if user_id:
            user_token = get_valid_token(user_id, _get_token_store())

        if not user_token:
            await cl.Message(
                content="Your session has expired. Please [sign in again](/oauth/login)."
            ).send()
            return

    thinking_msg = cl.Message(content="")
    await thinking_msg.send()

    try:
        response = await cl.make_async(agent.ask)(
            thread_id=thread_id,
            question=message.content,
            user_token=user_token,
        )
    except Exception as e:
        logger.exception("Agent error")
        response = f"Something went wrong: {e}"

    thinking_msg.content = response
    await thinking_msg.update()


@cl.on_chat_end
async def on_chat_end():
    """Cleanup is lightweight — threads are stateless server-side."""
    logger.info(
        "Session ended (thread=%s)",
        cl.user_session.get("thread_id", "?"),
    )
