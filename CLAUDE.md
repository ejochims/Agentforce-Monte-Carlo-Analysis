# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

Agentforce-as-orchestrator: a Salesforce Agentforce Agent that runs Monte Carlo simulations on live Salesforce pipeline data to answer questions like *"What's our probability of hitting $10M this quarter?"*

The live API is deployed at `https://monte-carlo-forecast-0b7519dafaaf.herokuapp.com`.

## Two Codebases in One Repo

This repo contains two distinct systems that must stay in sync:

1. **Python FastAPI service** (`api/`) — stateless Monte Carlo simulation engine
2. **Salesforce metadata** (`salesforce/force-app/`) — Apex class + Agentforce configuration

The Apex class (`MonteCarloActionHandler.cls`) calls the FastAPI service via Named Credential. If the API response shape changes, the Apex parsing logic must be updated to match.

## Commands

### Python API (local dev)

```bash
cp .env.example .env
./deploy/deploy.sh local          # Start with docker-compose, hot-reload at localhost:8000
```

Run without Docker (from repo root):
```bash
cd api
pip install -r ../requirements.txt
python main.py                    # uvicorn with auto-reload when DEBUG=true
```

### Python Tests

```bash
cd api
pip install -r ../requirements.txt pytest httpx
pytest ../tests/ -v                                  # All tests
pytest ../tests/test_simulation.py::TestMonteCarloMath -v   # Single class
pip install pytest-cov
pytest ../tests/ --cov=. --cov-report=term-missing   # With coverage
```

Tests add `api/` to `sys.path` — run pytest from `api/` directory or use the paths above from repo root.

### Deployment

```bash
./deploy/deploy.sh local
./deploy/deploy.sh heroku --app <app-name>
./deploy/deploy.sh lambda --function-name monte-carlo-forecast --region us-east-1
```

### Salesforce Metadata

```bash
# Deploy all metadata (Apex, Named Credential, External Credential, Remote Site, GenAiFunction, GenAiPlugin)
sf project deploy start --manifest salesforce/manifest/package.xml --target-org <alias>

# Deploy only Apex classes
sf project deploy start --source-dir salesforce/force-app/main/default/classes --target-org <alias>

# Run Apex tests
sf apex run test --class-names MonteCarloActionHandlerTest --target-org <alias> --result-format human
```

The SFDX source API version is `66.0` (`sfdx-project.json`). The Salesforce package path is `salesforce/force-app`.

**Note:** External Service registration (Step 3 in `salesforce/README_SETUP.md`) must be done manually in the Setup UI — it is not deployable via metadata.

## Architecture

```
User (Slack/Chat)
  → Agentforce LLM Orchestrator
  → Agent Action (GenAiFunction: Run_Revenue_Forecast)
  → MonteCarloActionHandler.cls (Apex, with sharing)
    → SOQL: SELECT Amount, Probability, CloseDate FROM Opportunity
    → HTTP POST via Named Credential: MonteCarlo_API
  → FastAPI (main.py)
    → Pydantic validation (models.py)
    → NumPy simulation engine (simulation.py)
    → JSON response
  → ActionOutput.summary → Agentforce LLM → User
```

**Data privacy:** Only `amount`, `probability`, and `close_date` leave Salesforce. Opportunity IDs are sent as anonymized identifiers. No names, contacts, or custom fields are transmitted.

## Key Design Decisions

- **Stateless service:** No database, no sessions. Every HTTP request is fully self-contained. This is intentional for data residency and simplicity.
- **OpenAPI 3.0 schema endpoint (`/api/v1/schema`):** FastAPI generates 3.1 by default, but Salesforce External Services requires 3.0. The schema is hand-crafted in `build_openapi_30_schema()` in `main.py` to maintain compatibility.
- **Salesforce probability conversion:** Salesforce stores `Probability` as 0–100 (integer). The API expects 0.0–1.0. The Apex class divides by 100.0 in `buildRequestPayload()`.
- **Dynamic SOQL uses `String.valueOf(date)` not `Date.format()`:** `Date.format()` produces locale-specific strings (e.g., "5/28/2026") which break SOQL. Always use `String.valueOf(horizonDate)` for SOQL date literals.
- **`with sharing` on Apex class:** Users can only forecast their own pipeline unless they have broader record access — intentional security boundary.
- **`mangum` in requirements.txt:** Wraps the ASGI app for AWS Lambda + API Gateway deployment. Not used in local/Heroku mode.

## Agentforce Agent Configuration

The Revenue Intelligence Agent (`salesforce/specs/revenueIntelligenceAgent.yaml`) has 3 topics:
- **Revenue Forecasting** — Monte Carlo simulations via `MonteCarloActionHandler`
- **Pipeline Analysis** — Pipeline summary via `PipelineSummaryAction`
- **Opportunity Updates** — Field updates via `UpdateOpportunityAction`

Topics are deployed as `GenAiPlugin` metadata; actions as `GenAiFunction` metadata. After deploying via manifest, topics must be manually attached to the agent in Setup → Agentforce → Agents → Topics → Add Topic from Org.

## Simulation Math

`simulation.py` uses vectorized NumPy operations:
1. Build arrays of `amounts` and `probabilities` (shape: `n_deals`)
2. Generate random draws matrix (shape: `num_simulations × n_deals`)
3. `won_matrix = random_draws < probabilities` — where each deal is "won"
4. `revenue_per_run = (won_matrix * amounts).sum(axis=1)` — revenue per simulation

Default: 10,000 simulations (~50ms). Max: 100,000. Configuration via env vars or `.env` file using `pydantic-settings`.

## Configuration

All settings are in `api/config.py` as Pydantic `BaseSettings` — every value is overridable via environment variable. Key settings:
- `DEFAULT_NUM_SIMULATIONS=10000`
- `MAX_NUM_SIMULATIONS=100000`
- `DEBUG=false` (set `true` for auto-reload and stack traces in responses)
- `PORT` is auto-set by Heroku; defaults to 8000 locally
