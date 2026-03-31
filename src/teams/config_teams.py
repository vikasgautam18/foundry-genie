"""Configuration for the Teams Bot Service."""

import os
from dotenv import load_dotenv

load_dotenv()

# Azure Bot registration
BOT_APP_ID = os.environ.get("MICROSOFT_APP_ID", "")
BOT_APP_PASSWORD = os.environ.get("MICROSOFT_APP_PASSWORD", "")
BOT_APP_TENANT_ID = os.environ.get("MICROSOFT_APP_TENANT_ID", "")
BOT_APP_TYPE = os.environ.get("MICROSOFT_APP_TYPE", "UserAssignedMSI")

# Server
PORT = int(os.environ.get("PORT", "3978"))
