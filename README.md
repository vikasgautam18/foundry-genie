# Foundry Genie - Market Campaign Analytics Assistant

**Foundry Genie** is an AI-powered assistant that leverages Azure AI Agents and Databricks Genie Space to provide intelligent insights into marketing campaign performance, ROI, spend analysis, audience segmentation, and more. The solution supports multiple interfaces including a web application via Chainlit and integration with Microsoft Teams.

## 📋 Overview

Foundry Genie bridges the gap between business users and data analytics by providing a natural language interface to query campaign data stored in Databricks. Users can ask questions about their marketing campaigns and receive data-driven insights powered by AI agents connected to Databricks Genie Space.

### Key Features

- **Multi-Channel Access**: Web UI (Chainlit) and Microsoft Teams bot integration
- **Natural Language Queries**: Ask questions about campaign performance, ROI, spend, and audience segments
- **Data Integration**: Connects to Databricks Genie Space via Model Context Protocol (MCP)
- **Flexible Authentication**: Supports both Machine-to-Machine (M2M) and User-to-Machine (U2M) authentication
- **Enterprise Ready**: Docker containerization, Azure deployment, Redis session management
- **Scalable Agent Architecture**: Built on Azure AI Agents SDK for reliable, production-grade AI interactions

## 🏗️ Architecture

```
┌─────────────────────────────────────────┐
│        User Interfaces                  │
│  ┌─────────────┐      ┌────────────┐  │
│  │  Chainlit   │      │ MS Teams   │  │
│  │  Web App    │      │ Bot        │  │
│  └─────┬───────┘      └─────┬──────┘  │
└────────┼──────────────────────┼────────┘
         │                      │
    ┌────▼──────────────────────▼────┐
    │   Foundry Genie Agent Core      │
    │   (Azure AI Agents SDK)         │
    │   - Agent orchestration         │
    │   - Session threading           │
    │   - Tool invocation             │
    └────┬─────────────────────────────┘
         │
    ┌────▼──────────────────────┐
    │  MCP Tool (Databricks)     │
    │  Genie Space Integration   │
    │  /api/2.0/mcp/genie/<id>   │
    └────┬──────────────────────┘
         │
    ┌────▼──────────────────────┐
    │  Databricks               │
    │  Campaign Data & Genie    │
    │  Analytics Space          │
    └───────────────────────────┘

    ┌────────────────────────────┐
    │  Token Store (Redis)       │
    │  Session & Auth Token Mgmt │
    └────────────────────────────┘
```

## 🔧 Technology Stack

### Core Dependencies

- **AI & Agents**:
  - `azure-ai-projects` (1.0.0+) - Azure AI project management
  - `azure-ai-agents` (1.2.0b3+) - Agent orchestration and tool integration
  - `azure-identity` (1.19.0+) - Azure authentication
  - `azure-keyvault-secrets` (4.9.0+) - Secure credential management

- **Web UI**:
  - `chainlit` (2.0.0+) - Python framework for building AI applications with chat interface

- **Teams Integration**:
  - `botbuilder-core` (4.16.1+) - Microsoft Bot Framework core
  - `botbuilder-integration-aiohttp` (4.16.1+) - Async HTTP integration
  - `aiohttp` (3.9-4) - Async HTTP client/server

- **State Management**:
  - `redis` (5.0+) - Session and token caching

- **Deployment**:
  - `gunicorn` (22.0.0+) - WSGI HTTP Server
  - Docker containerization
  - Python 3.11

## 📁 Project Structure

```
foundry-genie/
├── src/
│   ├── shared/                    # Shared agent and auth logic
│   │   ├── agent.py              # Core agent with Databricks MCP integration
│   │   ├── agent_rest.py         # REST API wrapper for agent
│   │   ├── databricks_oauth.py    # OAuth PKCE flow implementation
│   │   └── token_store.py        # Redis-based token persistence
│   ├── web/
│   │   ├── app.py                # Chainlit web application
│   │   └── __init__.py
│   ├── teams/
│   │   ├── bot.py                # Teams bot message handler
│   │   ├── teams_app.py          # Teams app configuration
│   │   ├── config_teams.py       # Teams-specific config
│   │   └── __init__.py
│   └── test/
│       ├── test_agent.py         # Agent unit tests
│       └── __init__.py
├── infra/                         # Infrastructure & deployment
│   ├── deploy-webapp.sh          # Azure WebApp deployment script
│   ├── install_terraform_hashicorp_apt.sh
│   └── setup-networking.sh
├── manifest/
│   └── manifest.json             # Microsoft Teams app manifest
├── chainlit.md                   # Chainlit UI welcome message
├── Dockerfile                    # Web app container build
├── Dockerfile.teams              # Teams bot container build
├── docker-compose.yml            # Local development environment
├── requirements.txt              # Python dependencies
└── README.md                     # This file
```

### Key Components

#### **1. Shared Agent (`src/shared/agent.py`)**
- Initializes Azure AI Agents client with Azure authentication
- Configures MCP tools to connect to Databricks Genie Space endpoint
- Manages agent threads and tool invocations
- Handles credential selection (service principal or managed identity)

#### **2. Web Application (`src/web/app.py`)**
- Chainlit-based chat interface
- Per-user session threading
- Supports dual authentication modes:
  - **OAuth/PAT Mode**: Machine-to-Machine using stored credentials
  - **U2M Mode**: User-to-Machine with Databricks OAuth PKCE flow
- Redis integration for token persistence across sessions

#### **3. Teams Bot (`src/teams/`)**
- Microsoft Bot Framework integration
- Handles Teams incoming messages and routes to agent
- OAuth integration for authenticating Teams users with Databricks
- Supports personal, team, and group chat scopes

#### **4. Token Store (`src/shared/token_store.py`)**
- Redis-based persistent storage for OAuth tokens
- Enables token reuse across user sessions
- Secure credential management

## 🚀 Getting Started

### Prerequisites

- Python 3.11+
- Docker & Docker Compose (for containerized deployment)
- Azure subscription with:
  - Azure AI Projects resource
  - Appropriate permissions for managed identity or service principal
- Databricks workspace with:
  - Genie Space configured
  - MCP endpoint enabled
- Redis instance (for token storage)
- Microsoft Teams app registration (for Teams bot)

### Local Development Setup

1. **Clone and setup Python environment**
   ```bash
   cd foundry-genie
   python -m venv .venv
   source .venv/bin/activate  # On Windows: .venv\Scripts\activate
   pip install -r requirements.txt
   ```

2. **Configure environment variables**
   Create a `.env` file in the project root:
   ```env
   # Azure configuration
   AZURE_SUBSCRIPTION_ID=<your-subscription-id>
   AZURE_RESOURCE_GROUP=<your-resource-group>
   AZURE_PROJECT_NAME=<your-ai-project-name>
   
   # Databricks configuration
   DATABRICKS_WORKSPACE_URL=https://<your-databricks-instance>
   DATABRICKS_AUTH_MODE=oauth  # or 'u2m' for user authentication
   DATABRICKS_GENIE_SPACE_ID=<genie-space-id>
   
   # For M2M authentication (optional)
   DATABRICKS_TOKEN=<your-pat-token>
   
   # Redis configuration
   REDIS_HOST=localhost
   REDIS_PORT=6379
   REDIS_DB=0
   REDIS_PASSWORD=
   
   # Azure authentication (for development)
   AZURE_CLIENT_ID=<service-principal-id>
   AZURE_CLIENT_SECRET=<service-principal-secret>
   AZURE_TENANT_ID=<tenant-id>
   ```

3. **Run with Docker Compose (includes Redis)**
   ```bash
   docker-compose up --build
   ```
   The web app will be available at `http://localhost:8000`

4. **Or run locally without Docker**
   ```bash
   # Ensure Redis is running on localhost:6379
   PYTHONPATH=src chainlit run src/web/app.py --host 0.0.0.0 --port 8000
   ```

## 📖 Usage

### Web Interface (Chainlit)

After starting the application, navigate to `http://localhost:8000`:

1. Users can type natural language questions about campaigns
2. Examples of queries:
   - "What's the ROI for Q1 campaigns?"
   - "Show me spend by audience segment"
   - "How did campaign performance compare month-to-month?"
3. The agent processes queries via the MCP tool and returns insights

### Microsoft Teams Bot

1. Deploy the Teams bot using the manifest in `manifest/manifest.json`
2. Users can mention the bot and ask campaign-related questions
3. The bot responds with insights from Databricks Genie Space

## 🔐 Authentication Modes

### Machine-to-Machine (M2M) - OAuth/PAT
- **When to use**: Service accounts, scheduled tasks, internal analytics
- **Setup**: Set `DATABRICKS_AUTH_MODE=oauth` and provide `DATABRICKS_TOKEN`
- **Pros**: No user sign-in required, simpler setup
- **Cons**: Single credential, less granular access control

### User-to-Machine (U2M)
- **When to use**: Per-user access control, audit trails, user-specific permissions
- **Setup**: Set `DATABRICKS_AUTH_MODE=u2m` and configure OAuth PKCE flow
- **Pros**: Each user authenticates with their own credentials
- **Cons**: Additional OAuth configuration complexity

## 🐳 Deployment

### Azure WebApp Deployment

Use the provided deployment script:
```bash
./infra/deploy-webapp.sh
```

This script:
- Builds the Docker image
- Pushes to Azure Container Registry
- Deploys to Azure WebApp
- Configures environment variables

### Environment Configuration

For production Azure deployment:
- Use **Managed Identity** instead of service principal credentials
- Store secrets in **Azure Key Vault**
- Use **Azure Cache for Redis** instead of self-managed Redis
- Enable **Application Insights** for monitoring
- Configure **Azure Cosmos DB** or similar for persistent session storage

### Docker Images

Two Dockerfiles are provided:

- **`Dockerfile`**: Builds the web UI application (Chainlit)
  ```bash
  docker build -t foundry-genie-web:latest -f Dockerfile .
  ```

- **`Dockerfile.teams`**: Builds the Teams bot service
  ```bash
  docker build -t foundry-genie-teams:latest -f Dockerfile.teams .
  ```

## 🧪 Testing

Run the test suite:
```bash
PYTHONPATH=src pytest src/test/
```

## 📊 Monitoring & Logging

The application logs diagnostic information including:
- Agent execution traces
- Tool invocation details
- Authentication flows
- Performance metrics

Configure logging level via environment:
```bash
export LOG_LEVEL=DEBUG  # or INFO, WARNING, ERROR
```

## 🔗 Integration with Databricks Genie

Foundry Genie uses the **Model Context Protocol (MCP)** to communicate with Databricks Genie Space:

- **Endpoint**: `https://<workspace-url>/api/2.0/mcp/genie/<space_id>`
- **Protocol**: MCP defines tools and resources for AI agents
- **Benefits**: 
  - Structured data access to Genie queries
  - Safe tool invocation with approval workflows
  - Seamless integration with Azure AI Agents

## 🛣️ Roadmap & Future Enhancements

- Analytics dashboard for agent performance metrics
- Multi-modal query support (charts, tables, exports)
- Advanced caching layer for frequent queries
- Slack bot integration
- Custom metric definitions per user/team
- Query result caching and optimization

## 📝 Contributing

Contributions are welcome! Please follow these guidelines:
- Create feature branches from `main`
- Ensure tests pass before submitting PRs
- Update documentation for new features
- Follow PEP 8 Python style guidelines

## ⚙️ Troubleshooting

### "Failed to authenticate with Databricks"
- Verify `DATABRICKS_WORKSPACE_URL` and token/credentials are correct
- Check that the Databricks workspace has Genie Space enabled
- For U2M mode, ensure OAuth PKCE app is registered in Databricks

### "Redis connection refused"
- Ensure Redis is running: `redis-cli ping`
- Verify `REDIS_HOST` and `REDIS_PORT` in `.env`
- For Docker Compose, check: `docker-compose ps`

### "MCP tool invocation failed"
- Verify Genie Space ID is correct in `DATABRICKS_GENIE_SPACE_ID`
- Check that the MCP endpoint is accessible from your network
- Review Azure AI Agents SDK logs for detailed error messages

## 📄 License

[Specify your license here]

## 👥 Support

For issues, questions, or feedback:
- Create an issue in the repository
- Contact the development team
- Review Azure AI Agents SDK documentation
- Check Databricks Genie Space documentation

---

**Last Updated**: March 2026  
**Python Version**: 3.11+  
**Status**: Active Development
