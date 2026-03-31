"""
Foundry agent that queries a Databricks Genie Space via its REST API.

This is a client-side function-calling approach: the Foundry agent decides
when to call the Genie tool, and this code executes the Databricks REST
calls locally — avoiding server-side MCP routing issues that can occur
with VNet-enabled AI Services resources.
"""

import os
import json
import time
import logging
import threading
import contextvars
from dataclasses import dataclass, field

import requests
from azure.ai.agents import AgentsClient
from azure.ai.agents.models import (
    FunctionTool,
    ListSortOrder,
    RequiredFunctionToolCall,
    SubmitToolOutputsAction,
    ToolOutput,
)
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

from dotenv import load_dotenv

load_dotenv()

logger = logging.getLogger(__name__)


# ── Azure credential ────────────────────────────────────────────────

def _get_credential():
    if all(os.environ.get(v) for v in ("AZURE_CLIENT_ID", "AZURE_TENANT_ID", "AZURE_CLIENT_SECRET")):
        logger.info("Using service-principal credentials")
        return DefaultAzureCredential()
    # On Azure (App Service / ACA), use managed identity
    if os.environ.get("WEBSITE_INSTANCE_ID") or os.environ.get("CONTAINER_APP_NAME"):
        logger.info("Using DefaultAzureCredential with managed identity (Azure hosted)")
        return DefaultAzureCredential()
    # Local dev: skip the 9s IMDS timeout that always fails
    logger.info("Using DefaultAzureCredential (managed-identity probe disabled)")
    return DefaultAzureCredential(exclude_managed_identity_credential=True)


def _get_databricks_token_static() -> str:
    """Fetch a static Databricks PAT from Key Vault or env var (legacy fallback)."""
    vault_url = os.environ.get("KEY_VAULT_URL")
    secret_name = os.environ.get("KEY_VAULT_SECRET_NAME", "databricks-pat")

    if vault_url:
        logger.info("Fetching Databricks token from Key Vault: %s", vault_url)
        client = SecretClient(vault_url=vault_url, credential=_get_credential())
        secret = client.get_secret(secret_name)
        return secret.value

    token = os.environ.get("DATABRICKS_TOKEN")
    if token:
        logger.info("Using Databricks token from DATABRICKS_TOKEN env var")
        return token

    raise ValueError(
        "Databricks token not configured. Set KEY_VAULT_URL or DATABRICKS_TOKEN."
    )


# Azure Databricks first-party Entra ID resource ID
_DATABRICKS_RESOURCE_ID = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"


class DatabricksOAuthTokenProvider:
    """Provides auto-refreshing Databricks OAuth tokens via Entra ID federation.

    Flow:
      1. Use DefaultAzureCredential to get an Entra ID token for the
         Azure Databricks resource (2ff814a6-3304-4ab8-85cb-cd0e6f879c1d).
      2. Exchange that token at the Databricks OIDC endpoint for a
         Databricks OAuth token (RFC 8693 token exchange).
      3. Cache the token and refresh it when it nears expiry.

    Supports both:
      - Account-wide federation (user tokens with upn claim)
      - Workload identity federation (managed identity tokens, requires
        client_id of the Databricks service principal)
    """

    def __init__(self, host: str, credential=None, databricks_sp_client_id: str | None = None):
        self._token_url = f"https://{host}/oidc/v1/token"
        self._credential = credential or _get_credential()
        self._databricks_sp_client_id = databricks_sp_client_id
        self._cached_token: str | None = None
        self._expires_at: float = 0.0
        self._lock = threading.Lock()
        self._refresh_margin = 300  # refresh 5 min before expiry

    def get_token(self) -> str:
        """Return a valid Databricks OAuth token, refreshing if needed."""
        with self._lock:
            if self._cached_token and time.time() < (self._expires_at - self._refresh_margin):
                return self._cached_token
            return self._refresh()

    def _refresh(self) -> str:
        """Acquire a fresh Databricks token via Entra ID → OIDC exchange."""
        # Step 1: Get Entra ID token for the Databricks resource
        entra_token = self._credential.get_token(
            f"{_DATABRICKS_RESOURCE_ID}/.default"
        ).token
        logger.info("Acquired Entra ID token for Databricks resource")

        # Step 2: Exchange for a Databricks OAuth token
        exchange_data = {
            "subject_token": entra_token,
            "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "scope": "all-apis",
        }
        # For workload identity federation (managed identity), include
        # the Databricks service principal client_id
        if self._databricks_sp_client_id:
            exchange_data["client_id"] = self._databricks_sp_client_id
            logger.info("Using workload identity federation (SP: %s)", self._databricks_sp_client_id)

        resp = requests.post(self._token_url, data=exchange_data, timeout=30)
        resp.raise_for_status()
        data = resp.json()

        self._cached_token = data["access_token"]
        self._expires_at = time.time() + data.get("expires_in", 3600)
        logger.info(
            "Databricks OAuth token acquired (expires_in=%ds)",
            data.get("expires_in", 0),
        )
        return self._cached_token


def _get_databricks_token(host: str) -> "str | DatabricksOAuthTokenProvider":
    """Return a token or token provider based on DATABRICKS_AUTH_MODE.

    Modes:
      - 'oauth' (default): Returns a DatabricksOAuthTokenProvider that
        auto-refreshes via Entra ID federation.
      - 'pat': Returns a static PAT string from Key Vault or env var.
    """
    auth_mode = os.environ.get("DATABRICKS_AUTH_MODE", "oauth").lower()

    if auth_mode == "pat":
        logger.info("Using PAT authentication mode")
        return _get_databricks_token_static()

    # For workload identity federation (managed identities), the
    # Databricks service principal client_id must be included in the
    # token exchange. For user tokens (local dev with Azure CLI), it's
    # optional — account-wide federation handles them.
    sp_client_id = os.environ.get("DATABRICKS_SP_CLIENT_ID")
    logger.info("Using OAuth token federation (Entra ID → Databricks)")
    return DatabricksOAuthTokenProvider(
        host=host, databricks_sp_client_id=sp_client_id
    )


# ── Databricks Genie REST helpers ───────────────────────────────────

class GenieClient:
    """Thin wrapper around the Databricks Genie Space REST API."""

    def __init__(self, host: str, space_id: str,
                 token: "str | DatabricksOAuthTokenProvider"):
        self._base = f"https://{host}/api/2.0/genie/spaces/{space_id}"
        self._sql_base = f"https://{host}/api/2.0/sql/statements"
        self._token = token

    @property
    def _headers(self) -> dict:
        """Build request headers, resolving the token on each call."""
        bearer = self._token.get_token() if isinstance(self._token, DatabricksOAuthTokenProvider) else self._token
        return {
            "Authorization": f"Bearer {bearer}",
            "Content-Type": "application/json",
        }

    def query(self, question: str, *, poll_timeout: float = 120.0) -> dict:
        """Send a question to Genie, poll until complete, return result."""
        # Start conversation
        r = requests.post(
            f"{self._base}/start-conversation",
            headers=self._headers,
            json={"content": question},
            timeout=30,
        )
        r.raise_for_status()
        data = r.json()
        conv_id = data["conversation_id"]
        msg_id = data["message_id"]

        return self._poll_message(conv_id, msg_id, poll_timeout)

    def follow_up(self, conversation_id: str, question: str,
                   *, poll_timeout: float = 120.0) -> dict:
        """Send a follow-up in an existing conversation."""
        r = requests.post(
            f"{self._base}/conversations/{conversation_id}/messages",
            headers=self._headers,
            json={"content": question},
            timeout=30,
        )
        r.raise_for_status()
        data = r.json()
        msg_id = data["message_id"]
        return self._poll_message(conversation_id, msg_id, poll_timeout)

    def get_query_result(self, statement_id: str) -> dict:
        """Fetch SQL result rows for a completed statement."""
        r = requests.get(
            f"{self._sql_base}/{statement_id}",
            headers=self._headers,
            timeout=30,
        )
        r.raise_for_status()
        data = r.json()
        cols = [c["name"] for c in data.get("manifest", {}).get("schema", {}).get("columns", [])]
        rows = data.get("result", {}).get("data_array", [])
        return {"columns": cols, "rows": rows}

    # ── internal ─────────────────────────────────────────────────

    def _poll_message(self, conv_id: str, msg_id: str,
                      timeout: float) -> dict:
        elapsed = 0.0
        while elapsed < timeout:
            r = requests.get(
                f"{self._base}/conversations/{conv_id}/messages/{msg_id}",
                headers=self._headers,
                timeout=30,
            )
            r.raise_for_status()
            msg = r.json()
            status = msg.get("status", "")
            logger.debug("Genie poll: status=%s (%.0fs)", status, elapsed)

            if status == "COMPLETED":
                return self._format_response(msg)
            if status in ("FAILED", "CANCELLED"):
                return {"error": f"Genie query {status.lower()}",
                        "conversation_id": conv_id}

            time.sleep(2)
            elapsed += 2

        return {"error": "Genie query timed out", "conversation_id": conv_id}

    def _format_response(self, msg: dict) -> dict:
        """Extract a clean result from a completed Genie message."""
        result = {
            "conversation_id": msg.get("conversation_id", ""),
            "status": "completed",
        }

        attachments = msg.get("attachments", [])
        for att in attachments:
            if "text" in att:
                result["answer"] = att["text"]["content"]
            if "query" in att:
                q = att["query"]
                result["sql"] = q.get("query", "")
                result["sql_description"] = q.get("description", "")
                stmt_id = q.get("statement_id", "")
                if stmt_id:
                    result["statement_id"] = stmt_id
                    # Inline the actual data rows
                    try:
                        qr = self.get_query_result(stmt_id)
                        result["columns"] = qr["columns"]
                        result["rows"] = qr["rows"][:50]  # cap to 50 rows
                    except Exception as e:
                        logger.warning("Could not fetch query result: %s", e)
            if "suggested_questions" in att:
                result["suggested_questions"] = att["suggested_questions"].get("questions", [])

        return result


# ── Tool functions exposed to the Foundry agent ─────────────────────

# Module-level GenieClient for M2M mode (singleton, shared token).
# Set to None when using U2M mode — per-request clients are created instead.
_genie: GenieClient | None = None

# Module-level config used by tool functions to create per-request clients (U2M)
_databricks_host: str = ""
_genie_space_id: str = ""

# ContextVar carries the per-user Databricks token during a request (U2M mode)
_current_user_token: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "databricks_user_token", default=None
)


def _get_genie_client() -> GenieClient:
    """Return the appropriate GenieClient for the current auth mode.

    - M2M (oauth/pat): returns the shared singleton ``_genie``.
    - U2M: creates a per-request client using the token from ``_current_user_token``.
    """
    user_token = _current_user_token.get()
    if user_token is not None:
        return GenieClient(host=_databricks_host, space_id=_genie_space_id, token=user_token)
    if _genie is not None:
        return _genie
    raise RuntimeError("Genie client not initialised and no user token set.")


def query_genie(question: str) -> str:
    """
    Ask a question about market campaign data.

    This queries the Databricks Genie analytics space which has access to
    campaign performance data including spend, impressions, clicks,
    conversions, ROI, audience segments, and channel breakdowns.

    Args:
        question: A natural-language question about campaign data.

    Returns:
        JSON string with the answer, SQL query, column names, and data rows.
    """
    if _genie is None and _current_user_token.get() is None:
        return json.dumps({"error": "Genie client not initialised"})
    try:
        client = _get_genie_client()
        result = client.query(question)
        return json.dumps(result, default=str)
    except Exception as e:
        logger.exception("Genie query failed")
        return json.dumps({"error": str(e)})


def follow_up_genie(conversation_id: str, question: str) -> str:
    """
    Ask a follow-up question in an existing Genie conversation.

    Use this when the user wants to refine or drill into a previous answer.
    The conversation_id comes from the previous query_genie result.

    Args:
        conversation_id: The conversation ID from a previous query.
        question: The follow-up question.

    Returns:
        JSON string with the answer, SQL query, column names, and data rows.
    """
    if _genie is None and _current_user_token.get() is None:
        return json.dumps({"error": "Genie client not initialised"})
    try:
        client = _get_genie_client()
        result = client.follow_up(conversation_id, question)
        return json.dumps(result, default=str)
    except Exception as e:
        logger.exception("Genie follow-up failed")
        return json.dumps({"error": str(e)})


# ── Agent instructions ──────────────────────────────────────────────

AGENT_INSTRUCTIONS = """\
You are an AI assistant specializing in **market campaign analytics**.

You have access to two tools that query a Databricks analytics space:

1. **query_genie** — Ask a new data question (campaigns, spend, clicks,
   impressions, conversions, ROI, audience segments, channel breakdowns,
   time-series trends).
2. **follow_up_genie** — Ask a follow-up using a previous conversation_id
   to refine or drill into results.

Guidelines:
  1. Always use the tools for data questions — never fabricate numbers.
  2. Present results in clear markdown tables or bullet points.
  3. If the tool returns SQL, briefly explain the query in plain language.
  4. If a query fails, suggest the user rephrase their question.
  5. You may answer general marketing-knowledge questions without the tools.
  6. When you get data rows, format them as a markdown table for the user.
"""


# ── Configuration ───────────────────────────────────────────────────

@dataclass
class AgentConfig:
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
    databricks_token: "str | DatabricksOAuthTokenProvider | None" = field(
        default=None
    )
    auth_mode: str = field(
        default_factory=lambda: os.environ.get("DATABRICKS_AUTH_MODE", "oauth").lower()
    )

    def __post_init__(self):
        # In U2M mode, tokens come per-request — no shared token needed
        if self.auth_mode != "u2m" and self.databricks_token is None:
            self.databricks_token = _get_databricks_token(self.databricks_host)


# ── Agent class ─────────────────────────────────────────────────────

class GenieMcpAgent:
    """
    Foundry agent backed by client-side Genie REST calls.

    Drop-in replacement for the MCP-based agent in agent.py — same
    public interface: setup(), teardown(), create_thread(), ask(),
    and context-manager support.
    """

    def __init__(self, config: AgentConfig | None = None):
        self.cfg = config or AgentConfig()

        self._agents_client = AgentsClient(
            endpoint=self.cfg.project_endpoint,
            credential=_get_credential(),
        )

        # Store host/space_id at module level for per-request GenieClient (U2M)
        global _databricks_host, _genie_space_id
        _databricks_host = self.cfg.databricks_host
        _genie_space_id = self.cfg.genie_space_id

        # In M2M mode, initialise the shared singleton GenieClient
        if self.cfg.auth_mode != "u2m":
            global _genie
            _genie = GenieClient(
                host=self.cfg.databricks_host,
                space_id=self.cfg.genie_space_id,
                token=self.cfg.databricks_token,
            )
        else:
            logger.info("U2M mode — GenieClient will be created per-request")

        # Build FunctionTool from our Python functions
        self._func_tool = FunctionTool(functions=[query_genie, follow_up_genie])

        self._agent = None

    # ── lifecycle ────────────────────────────────────────────────────

    def setup(self) -> str:
        self._agent = self._agents_client.create_agent(
            model=self.cfg.model_deployment,
            name="market-campaign-genie-agent",
            instructions=AGENT_INSTRUCTIONS,
            tools=self._func_tool.definitions,
        )
        logger.info("Created agent %s", self._agent.id)
        return self._agent.id

    def teardown(self) -> None:
        if self._agent:
            self._agents_client.delete_agent(self._agent.id)
            logger.info("Deleted agent %s", self._agent.id)
            self._agent = None

    # ── conversation ─────────────────────────────────────────────────

    def create_thread(self) -> str:
        thread = self._agents_client.threads.create()
        logger.info("Created thread %s", thread.id)
        return thread.id

    def ask(
        self,
        thread_id: str,
        question: str,
        *,
        user_token: str | None = None,
        poll_interval: float = 1.0,
        timeout: float = 180.0,
    ) -> str:
        if self._agent is None:
            raise RuntimeError("Call setup() before ask().")

        # Set per-request user token for U2M mode (read by tool functions)
        _current_user_token.set(user_token)

        self._agents_client.messages.create(
            thread_id=thread_id, role="user", content=question
        )

        run = self._agents_client.runs.create(
            thread_id=thread_id, agent_id=self._agent.id
        )
        logger.info("Run %s created (status=%s)", run.id, run.status)

        elapsed = 0.0
        while run.status in ("queued", "in_progress", "requires_action"):
            if elapsed >= timeout:
                self._agents_client.runs.cancel(
                    thread_id=thread_id, run_id=run.id
                )
                return "The request timed out. Please try a simpler question."

            # Handle function-call requests from the model
            if run.status == "requires_action" and isinstance(
                run.required_action, SubmitToolOutputsAction
            ):
                self._handle_tool_calls(thread_id, run)

            time.sleep(poll_interval)
            elapsed += poll_interval
            run = self._agents_client.runs.get(
                thread_id=thread_id, run_id=run.id
            )
            logger.debug("Run %s status=%s (%.0fs)", run.id, run.status, elapsed)

        if run.status == "failed":
            err = run.last_error or "unknown error"
            logger.error("Run failed: %s", err)
            return f"Agent run failed: {err}"

        return self._latest_assistant_text(thread_id)

    # ── internal helpers ─────────────────────────────────────────────

    def _handle_tool_calls(self, thread_id: str, run) -> None:
        """Execute requested function calls and submit results."""
        tool_calls = run.required_action.submit_tool_outputs.tool_calls
        outputs = []
        for tc in tool_calls:
            if isinstance(tc, RequiredFunctionToolCall):
                fn_name = tc.function.name
                fn_args = json.loads(tc.function.arguments)
                logger.info("Calling %s(%s)", fn_name, fn_args)

                result = self._func_tool.execute(tc)
                outputs.append(ToolOutput(tool_call_id=tc.id, output=result))
                logger.info("Function %s returned %d chars", fn_name, len(result))

        if outputs:
            self._agents_client.runs.submit_tool_outputs(
                thread_id=thread_id,
                run_id=run.id,
                tool_outputs=outputs,
            )

    def _latest_assistant_text(self, thread_id: str) -> str:
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
