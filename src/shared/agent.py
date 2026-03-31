"""
Foundry agent that uses a Databricks Genie Space via MCP to answer
market-campaign questions.

Uses the McpTool class from the azure-ai-agents SDK to connect to the
Databricks Genie MCP endpoint:
    https://<host>/api/2.0/mcp/genie/<space_id>
"""

import os
import time
import logging
from dataclasses import dataclass, field

from azure.ai.agents import AgentsClient
from azure.ai.agents.models import (
    ListSortOrder,
    McpTool,
    RequiredMcpToolCall,
    SubmitToolApprovalAction,
    ToolApproval,
)
from azure.identity import DefaultAzureCredential, AzureCliCredential

from dotenv import load_dotenv

load_dotenv()

logger = logging.getLogger(__name__)


def _get_credential():
    """
    Return the best available Azure credential.
    - If AZURE_CLIENT_ID + AZURE_TENANT_ID + AZURE_CLIENT_SECRET are set → service principal
    - Otherwise use DefaultAzureCredential but skip the slow managed-identity
      IMDS probe (9s timeout) that always fails in local Docker.
    """
    if all(os.environ.get(v) for v in ("AZURE_CLIENT_ID", "AZURE_TENANT_ID", "AZURE_CLIENT_SECRET")):
        logger.info("Using service-principal credentials (env vars)")
        return DefaultAzureCredential()
    logger.info("Using DefaultAzureCredential (managed-identity probe disabled)")
    return DefaultAzureCredential(
        exclude_managed_identity_credential=True,
    )

AGENT_INSTRUCTIONS = """\
You are an AI assistant specializing in **market campaign analytics**.

You have access to a Databricks Genie tool that can query campaign data stored
in a curated data space.  Use this tool whenever the user asks about:
  • campaign performance, ROI, spend, impressions, clicks, conversions
  • audience segments, demographics, geographic breakdowns
  • time-series trends (daily / weekly / monthly)
  • comparisons across channels (email, social, paid search, display)
  • any other market-campaign-related data question

Guidelines:
  1. Always use the Genie tool for data questions — never fabricate numbers.
  2. Present results in clear markdown tables or bullet points.
  3. If the tool returns SQL, briefly explain the query in plain language.
  4. If a query fails, suggest the user rephrase their question.
  5. You may answer general marketing-knowledge questions without the tool.
"""


@dataclass
class AgentConfig:
    """Configuration for the Foundry Genie agent."""

    project_endpoint: str = field(
        default_factory=lambda: os.environ["PROJECT_ENDPOINT"]
    )
    model_deployment: str = field(
        default_factory=lambda: os.environ["MODEL_DEPLOYMENT_NAME"]
    )
    databricks_host: str = field(
        default_factory=lambda: os.environ["DATABRICKS_HOST"]
    )
    genie_space_id: str = field(
        default_factory=lambda: os.environ["GENIE_SPACE_ID"]
    )
    databricks_token: str = field(
        default_factory=lambda: os.environ["DATABRICKS_TOKEN"]
    )
    mcp_server_label: str = field(
        default_factory=lambda: os.environ.get("MCP_SERVER_LABEL", "databricks_genie")
    )

    @property
    def mcp_server_url(self) -> str:
        return (
            f"https://{self.databricks_host}"
            f"/api/2.0/mcp/genie/{self.genie_space_id}"
        )


class GenieMcpAgent:
    """
    Wraps an Azure AI Foundry agent that is wired to a Databricks Genie
    Space via the Model Context Protocol (MCP).
    """

    def __init__(self, config: AgentConfig | None = None):
        self.cfg = config or AgentConfig()

        # Foundry agents client (direct AgentsClient, not AIProjectClient)
        self._agents_client = AgentsClient(
            endpoint=self.cfg.project_endpoint,
            credential=_get_credential(),
        )

        # MCP tool pointing at the Databricks Genie endpoint
        self._mcp_tool = McpTool(
            server_label=self.cfg.mcp_server_label,
            server_url=self.cfg.mcp_server_url,
        )
        # Inject the Databricks PAT as a Bearer header for the MCP call
        self._mcp_tool.update_headers(
            "Authorization", f"Bearer {self.cfg.databricks_token}"
        )
        # Auto-approve tool calls so the agent can call Genie without
        # a human-in-the-loop approval step.
        self._mcp_tool.set_approval_mode("never")

        self._agent = None

    # ── lifecycle ────────────────────────────────────────────────────

    def setup(self) -> str:
        """Create the remote agent and return its ID."""
        self._agent = self._agents_client.create_agent(
            model=self.cfg.model_deployment,
            name="market-campaign-genie-agent",
            instructions=AGENT_INSTRUCTIONS,
            tools=self._mcp_tool.definitions,
        )
        logger.info("Created agent %s", self._agent.id)
        return self._agent.id

    def teardown(self) -> None:
        """Delete the remote agent."""
        if self._agent:
            self._agents_client.delete_agent(self._agent.id)
            logger.info("Deleted agent %s", self._agent.id)
            self._agent = None

    # ── conversation ─────────────────────────────────────────────────

    def create_thread(self) -> str:
        """Create a new conversation thread and return its ID."""
        thread = self._agents_client.threads.create()
        logger.info("Created thread %s", thread.id)
        return thread.id

    def ask(
        self,
        thread_id: str,
        question: str,
        *,
        poll_interval: float = 1.0,
        timeout: float = 180.0,
    ) -> str:
        """
        Send *question* to the agent on *thread_id* and return the
        assistant's text response.

        Handles the MCP tool-approval loop automatically.
        """
        if self._agent is None:
            raise RuntimeError("Call setup() before ask().")

        # Add the user message
        self._agents_client.messages.create(
            thread_id=thread_id, role="user", content=question
        )

        # Create a run
        run = self._agents_client.runs.create(
            thread_id=thread_id,
            agent_id=self._agent.id,
            tool_resources=self._mcp_tool.resources,
        )
        logger.info("Run %s created (status=%s)", run.id, run.status)

        # Poll until terminal
        elapsed = 0.0
        while run.status in ("queued", "in_progress", "requires_action"):
            if elapsed >= timeout:
                self._agents_client.runs.cancel(
                    thread_id=thread_id, run_id=run.id
                )
                return "The request timed out. Please try a simpler question."

            time.sleep(poll_interval)
            elapsed += poll_interval
            run = self._agents_client.runs.get(
                thread_id=thread_id, run_id=run.id
            )

            # Handle MCP tool approval requests
            if run.status == "requires_action" and isinstance(
                run.required_action, SubmitToolApprovalAction
            ):
                self._handle_tool_approvals(thread_id, run)

            logger.debug("Run %s status=%s (%.0fs)", run.id, run.status, elapsed)

        if run.status == "failed":
            err = run.last_error or "unknown error"
            logger.error("Run failed: %s", err)
            return f"Agent run failed: {err}"

        return self._latest_assistant_text(thread_id)

    # ── internal helpers ─────────────────────────────────────────────

    def _handle_tool_approvals(self, thread_id: str, run) -> None:
        """Auto-approve any pending MCP tool calls."""
        tool_calls = run.required_action.submit_tool_approval.tool_calls
        if not tool_calls:
            return

        approvals = []
        for tc in tool_calls:
            if isinstance(tc, RequiredMcpToolCall):
                approvals.append(
                    ToolApproval(
                        tool_call_id=tc.id,
                        approve=True,
                        headers=self._mcp_tool.headers,
                    )
                )
                logger.info("Approved MCP tool call %s", tc.id)

        if approvals:
            self._agents_client.runs.submit_tool_outputs(
                thread_id=thread_id,
                run_id=run.id,
                tool_approvals=approvals,
            )

    def _latest_assistant_text(self, thread_id: str) -> str:
        """Return the text content of the most recent assistant message."""
        messages = self._agents_client.messages.list(
            thread_id=thread_id, order=ListSortOrder.DESCENDING
        )
        for msg in messages:
            if msg.role == "assistant" and msg.text_messages:
                return msg.text_messages[-1].text.value
        return "(No response from agent)"

    # ── context manager ──────────────────────────────────────────────

    def __enter__(self):
        self._agents_client.__enter__()
        self.setup()
        return self

    def __exit__(self, *exc):
        self.teardown()
        self._agents_client.__exit__(*exc)
