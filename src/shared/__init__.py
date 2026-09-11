"""Shared package.

``AgentConfig`` / ``GenieMcpAgent`` are imported lazily (PEP 562) so that the
cloud-SDK-free modules (``gic_reports``, ``gic_premium``, ``token_store``,
``oauth_state``) can be imported — and unit-tested — without pulling in the
azure-ai-agents dependency.
"""

__all__ = ["AgentConfig", "GenieMcpAgent"]


def __getattr__(name):
    if name in ("AgentConfig", "GenieMcpAgent"):
        from .agent_rest import AgentConfig, GenieMcpAgent
        return {"AgentConfig": AgentConfig, "GenieMcpAgent": GenieMcpAgent}[name]
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
