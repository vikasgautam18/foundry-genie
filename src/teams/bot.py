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

from shared.agent_rest import GenieMcpAgent, AgentConfig
from shared.databricks_oauth import get_valid_token
from shared.token_store import RedisTokenStore

logger = logging.getLogger(__name__)

_AUTH_MODE = os.environ.get("DATABRICKS_AUTH_MODE", "oauth").lower()
_IS_U2M = _AUTH_MODE == "u2m"

# Base URL for OAuth routes — set via env or default
_BOT_HOST = os.environ.get(
    "BOT_PUBLIC_URL",
    "https://foundry-genie-teams-bot.azurewebsites.net",
)


class GenieTeamsBot(ActivityHandler):
    """Bot that receives Teams messages and forwards to the Foundry Genie agent."""

    def __init__(self, token_store: RedisTokenStore | None = None) -> None:
        self._agent = GenieMcpAgent(AgentConfig())
        self._agent._agents_client.__enter__()
        self._agent.setup()

        self._token_store = token_store
        self._thread_map: dict[str, str] = {}
        logger.info("GenieTeamsBot initialised (agent=%s)", self._agent._agent.id)

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

        conv_id = turn_context.activity.conversation.id
        thread_id = self._thread_map.get(conv_id)

        if not thread_id:
            thread_id = self._agent.create_thread()
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
            reply = "Sorry, something went wrong while processing your request."

        await turn_context.send_activity(reply)

    async def on_members_added_activity(self, members_added, turn_context: TurnContext):
        """Greet new members when they join the conversation."""
        for member in members_added:
            if member.id != turn_context.activity.recipient.id:
                welcome = (
                    "**Welcome to the Market Campaign Assistant!**\n\n"
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
        """Send an Adaptive Card prompting the user to sign in to Databricks."""
        signin_url = f"{_BOT_HOST}/oauth/login?user_id={user_id}"
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
