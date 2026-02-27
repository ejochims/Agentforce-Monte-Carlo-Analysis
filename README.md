# Agentforce Monte Carlo Revenue Forecasting

> **Agentforce as Orchestrator** — an Agentforce Agent that runs Monte Carlo
> simulations on live Salesforce pipeline data to answer questions like
> *"What's our probability of hitting $10M this quarter?"*

## Quick Start

```bash
cp .env.example .env
./deploy/deploy.sh local
# → API running at http://localhost:8000
# → Docs at http://localhost:8000/docs
```

## Documentation

| File | What it covers |
|------|---------------|
| `docs/README.md` | Architecture, API reference, deployment guide, data residency notes |
| `docs/WORKSHOP_WALKTHROUGH.md` | Facilitator guide for live Agentforce demos |
| `salesforce/README_SETUP.md` | Step-by-step Salesforce configuration (Named Credential, External Service, Agent Action) |

## Project Structure

```
├── api/               Python FastAPI simulation service
├── salesforce/        Apex class + Salesforce setup guide
├── deploy/            Dockerfile, docker-compose, deploy.sh
├── docs/              README and workshop facilitator guide
├── tests/             Unit tests for simulation math
├── requirements.txt   Pinned Python dependencies
└── .env.example       Configuration template
```

See `docs/README.md` for the full architecture diagram and setup instructions.