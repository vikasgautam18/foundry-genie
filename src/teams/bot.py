"""Teams bot that bridges Microsoft Teams with the Foundry Genie agent.

Receives messages from Teams (routed through Azure Bot Service) and
forwards them to the existing GenieMcpAgent — the same agent logic
that powers the Chainlit web UI.

In U2M mode (DATABRICKS_AUTH_MODE=u2m), prompts users to sign in to
Databricks before processing queries. Each user gets their own
Databricks identity and data permissions.

Conversation memory: Each Teams conversation is mapped to a Foundry
thread_id so the agent retains context across messages.
"""

import asyncio
import json
import logging
import os

from botbuilder.core import ActivityHandler, TurnContext, CardFactory
from botbuilder.schema import Activity, ActivityTypes

from shared.agent_rest import GenieMcpAgent, AgentConfig, AgentReply
from shared.databricks_oauth import get_valid_token
from shared.oauth_state import generate_signed_state
from shared.token_store import RedisTokenStore
from shared.charting import build_chart, chart_to_native_points
from shared.chart_cache import ChartCache

logger = logging.getLogger(__name__)

_AUTH_MODE = os.environ.get("DATABRICKS_AUTH_MODE", "oauth").lower()
_IS_U2M = _AUTH_MODE == "u2m"

# Base URL for OAuth routes — set via env or default
_BOT_HOST = os.environ.get("BOT_PUBLIC_URL", "http://localhost:3978")


class GenieTeamsBot(ActivityHandler):
    """Bot that receives Teams messages and forwards to the Foundry Genie agent."""

    def __init__(self, token_store: RedisTokenStore | None = None,
                 chart_cache: ChartCache | None = None) -> None:
        self._agent: GenieMcpAgent | None = None
        self._agent_ready = False
        self._token_store = token_store
        self._chart_cache = chart_cache
        self._thread_map: dict[str, str] = {}
        logger.info("GenieTeamsBot created (agent setup deferred to first message)")

    def _ensure_agent(self) -> None:
        """Lazily initialise the Foundry agent on first use."""
        if self._agent_ready:
            return
        logger.info("Initialising Foundry agent...")
        self._agent = GenieMcpAgent(AgentConfig())
        self._agent._agents_client.__enter__()
        self._agent.setup()
        self._agent_ready = True
        logger.info("Foundry agent ready (agent=%s)", self._agent._agent.id)

    async def on_message_activity(self, turn_context: TurnContext) -> None:
        """Handle incoming messages from Teams and relay to the AI agent."""
        user_text = turn_context.activity.text or ""
        if not user_text.strip():
            return

        user_id = turn_context.activity.from_property.id

        # U2M: check for Databricks sign-in
        user_token = None
        if _IS_U2M:
            if self._token_store:
                user_token = get_valid_token(user_id, self._token_store)
            if not user_token:
                await self._send_signin_card(turn_context, user_id)
                return

        await turn_context.send_activity(Activity(type=ActivityTypes.typing))

        # Lazy-init agent on first message so server starts fast
        try:
            await asyncio.to_thread(self._ensure_agent)
        except Exception:
            logger.exception("Failed to initialise Foundry agent")
            await turn_context.send_activity(
                "Sorry, I couldn't connect to the AI backend. Please try again shortly."
            )
            return

        conv_id = turn_context.activity.conversation.id
        thread_id = (
            self._token_store.get_thread(conv_id)
            if self._token_store else self._thread_map.get(conv_id)
        )

        if not thread_id:
            thread_id = self._agent.create_thread()
            if self._token_store:
                self._token_store.save_thread(conv_id, thread_id)
            else:
                self._thread_map[conv_id] = thread_id
            logger.info(
                "Created Foundry thread %s for Teams conversation %s",
                thread_id, conv_id,
            )

        try:
            reply = await asyncio.to_thread(
                self._agent.ask,
                thread_id=thread_id,
                question=user_text,
                user_token=user_token,
            )
        except Exception:
            logger.exception("Agent call failed")
            reply = AgentReply(text="Sorry, something went wrong while processing your request.")

        await turn_context.send_activity(reply.text)

        # Best-effort chart rendering — never let a charting failure affect
        # the text reply already sent above.
        try:
            await self._send_charts(turn_context, reply.genie_results)
        except Exception:
            logger.exception("Chart rendering failed")

    async def _send_charts(self, turn_context: TurnContext, genie_results: list) -> None:
        """Send a follow-up Adaptive Card chart for each chart-worthy Genie result.

        PNG rendering (via Plotly's kaleido engine, hosted at this bot's own
        ``/charts/{id}.png`` route) is used whenever a ``ChartCache`` is
        available — this is the same rendering already confirmed working on
        the web UI, so it is preferred over native Adaptive Card ``Chart.*``
        elements, whose exact rendering behavior varies across Teams clients
        and has proven unreliable in testing. Native cards are used only as a
        best-effort fallback when Redis/ChartCache isn't configured.
        """
        for gr in genie_results:
            fig = build_chart(gr.get("columns", []), gr.get("rows", []))
            if fig is None:
                continue

            if self._chart_cache is not None:
                png_bytes = await asyncio.to_thread(
                    fig.to_image, format="png", width=800, height=500
                )
                chart_id = self._chart_cache.put(png_bytes)
                url = f"{_BOT_HOST}/charts/{chart_id}.png"
                title = (fig.layout.title.text if fig.layout.title else None) or "Chart"
                card = self._build_image_card(url, title)
            else:
                native = chart_to_native_points(fig)
                if native is None:
                    logger.info("Skipping complex chart: no ChartCache and not native-renderable")
                    continue
                card = self._build_native_chart_card(native)

            await turn_context.send_activity(
                Activity(type=ActivityTypes.message, attachments=[CardFactory.adaptive_card(card)])
            )

    @staticmethod
    def _build_native_chart_card(native: dict) -> dict:
        """Build a native Adaptive Card Chart.* element (v1.5) for a simple,
        single-series bar/line/pie result, with a text fallback for older
        clients that don't support the Chart.* host extension.

        Field shapes differ per chart type (Adaptive Cards charts-in-cards
        schema): Chart.Pie/Donut use flat {legend, value}; Chart.VerticalBar
        uses flat {x, y}; Chart.Line requires a nested single-series
        {legend, values: [{x, y}, ...]}.
        """
        kind = native["kind"]
        title = native["title"] or "Chart"
        points = native["points"]
        summary = ", ".join(f"{label}: {value}" for label, value in points)

        if kind == "pie":
            chart_type = "Chart.Pie"
            body_element = {
                "type": chart_type,
                "title": title,
                "data": [{"legend": str(label), "value": float(value)} for label, value in points],
            }
        elif kind == "bar":
            chart_type = "Chart.VerticalBar"
            body_element = {
                "type": chart_type,
                "title": title,
                "data": [{"x": str(label), "y": float(value)} for label, value in points],
            }
        else:  # "line"
            chart_type = "Chart.Line"
            body_element = {
                "type": chart_type,
                "title": title,
                "data": [{
                    "legend": title,
                    "values": [{"x": str(label), "y": float(value)} for label, value in points],
                }],
            }

        body_element["fallback"] = {
            "type": "TextBlock",
            "text": f"**{title}**: {summary}",
            "wrap": True,
        }

        return {
            "type": "AdaptiveCard",
            "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
            "version": "1.5",
            "body": [body_element],
        }

    @staticmethod
    def _build_image_card(url: str, title: str) -> dict:
        """Build an Adaptive Card hosting a chart PNG at a public URL."""
        return {
            "type": "AdaptiveCard",
            "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
            "version": "1.4",
            "body": [
                {
                    "type": "TextBlock",
                    "text": f"**{title}**",
                    "wrap": True,
                    "weight": "Bolder",
                },
                {
                    "type": "Image",
                    "url": url,
                    "altText": title,
                    "size": "Stretch",
                },
            ],
        }

    async def on_members_added_activity(self, members_added, turn_context: TurnContext):
        """Greet new members when they join the conversation."""
        for member in members_added:
            if member.id != turn_context.activity.recipient.id:
                welcome = (
                    "**Welcome to camp_buddy!**\n\n"
                    "I can answer questions about your campaign data — "
                    "performance metrics, ROI, spend breakdowns, audience "
                    "segments, and more.\n\n"
                )
                if _IS_U2M:
                    welcome += (
                        "To get started, please sign in to Databricks "
                        "using the button below."
                    )
                    await self._send_signin_card(turn_context, member.id)
                else:
                    welcome += "Just type your question to get started."
                    await turn_context.send_activity(welcome)

    async def _send_signin_card(self, turn_context: TurnContext, user_id: str) -> None:
        """Send an Adaptive Card prompting the user to sign in to Databricks.

        Security: binds an opaque, HMAC-signed *state* nonce to the
        Bot-Framework-verified Teams ``user_id`` server-side (Redis). The
        browser-visible URL carries only the nonce — never a user id — so a
        crafted link can no longer bind one user's tokens to another identity.
        """
        if not self._token_store:
            logger.error("Token store unavailable; cannot start sign-in.")
            await turn_context.send_activity(
                "Sign-in is temporarily unavailable. Please try again later."
            )
            return

        state = generate_signed_state()
        self._token_store.save_login_state(state, user_id)
        signin_url = f"{_BOT_HOST}/oauth/login?state={state}"
        card = {
            "type": "AdaptiveCard",
            "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
            "version": "1.4",
            "body": [
                {
                    "type": "TextBlock",
                    "text": "**Sign in to Databricks**",
                    "wrap": True,
                    "size": "Medium",
                    "weight": "Bolder",
                },
                {
                    "type": "TextBlock",
                    "text": "To access campaign data with your own permissions, "
                            "please sign in to Databricks first.",
                    "wrap": True,
                },
            ],
            "actions": [
                {
                    "type": "Action.OpenUrl",
                    "title": "Sign in to Databricks",
                    "url": signin_url,
                }
            ],
        }
        attachment = CardFactory.adaptive_card(card)
        await turn_context.send_activity(
            Activity(type=ActivityTypes.message, attachments=[attachment])
        )
