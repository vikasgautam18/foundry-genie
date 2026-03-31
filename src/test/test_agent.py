"""
Quick CLI smoke-test for the Foundry Genie agent.
Run:  PYTHONPATH=src python -m test.test_agent "What campaigns ran last month?"
"""

import sys
import logging
from shared.agent_rest import GenieMcpAgent

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(name)-28s  %(levelname)-7s  %(message)s",
)

question = " ".join(sys.argv[1:]) or "What are the top 5 campaigns by spend?"

print(f"\nAsking: {question}\n")

with GenieMcpAgent() as agent:
    thread_id = agent.create_thread()
    answer = agent.ask(thread_id, question)
    print(f"Response:\n{answer}\n")
