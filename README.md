# Agentforce Monte Carlo Revenue Forecasting

> **Agentforce as Orchestrator** — a Salesforce Agentforce Agent that runs Monte Carlo
> simulations on live pipeline data to answer probability-based revenue questions.
>
> *"What's my chance of hitting $25M this quarter?"*
> *"Am I on track for quota?"*
> *"What's a realistic revenue range for Q1?"*

The agent queries the current user's open Opportunities in real time, ships only the
anonymized deal math to a stateless simulation engine on Heroku, runs 10,000 Monte Carlo
scenarios, and returns a plain-English answer — in under a second.

---

## How It Works

A user asks a natural-language question in Slack, Experience Cloud, or any Agentforce
surface. The LLM orchestrator recognizes a forecasting intent, invokes the
`Run Revenue Forecast` action, and returns a probabilistic answer derived from live
Opportunity data — not a gut feeling or a weighted pipeline number.

```
User: "Will I hit $25M this quarter?"

Agentforce LLM Orchestrator
  → recognizes forecasting intent
  → invokes Run Revenue Forecast action (revenueTarget = 25000000)

MonteCarloActionHandler.cls  [Apex, with sharing]
  → SOQL: SELECT Amount, Probability, CloseDate
          FROM Opportunity
          WHERE IsClosed = false
          AND CloseDate <= [end of current quarter]
          [scoped to current user automatically via with sharing]

POST https://monte-carlo-forecast-0b7519dafaaf.herokuapp.com/api/v1/simulate
  → { opportunities: [{ amount, probability, close_date }, ...] }
  → 10,000 Monte Carlo simulations (~50ms, NumPy vectorized)

Response: { mean: $22.4M, p10: $18.1M, p90: $27.6M, target_probability: "68.3%" }

Agentforce LLM → User:
  "Based on your 14 open opportunities, you have a 68.3% chance of hitting $25M
   this quarter. Your expected revenue is $22.4M, with a realistic range of
   $18.1M (pessimistic) to $27.6M (optimistic)."
```

---

## The Simulation Math

The Monte Carlo engine runs vectorized simulations using NumPy:

1. Build arrays of `amounts` and `probabilities` from your open Opportunities
2. Generate a random draw matrix (`num_simulations × n_deals`)
3. `won_matrix = random_draws < probabilities` — each deal is independently won or lost
4. `revenue_per_run = (won_matrix × amounts).sum(axis=1)` — total revenue per simulation
5. Aggregate: mean, p10, p90, and probability of hitting each revenue target

**Default: 10,000 simulations. Each run takes ~50ms.**

Unlike weighted pipeline (which gives one deterministic number), Monte Carlo surfaces
the full distribution — so you see not just the expected outcome, but how wide the
cone of uncertainty is.

---

## Architecture

```mermaid
flowchart TD
    U([User\nSlack / Experience Cloud / Chat]) -->|Natural language question| LLM

    subgraph Salesforce
        LLM[Agentforce LLM Orchestrator\nRecognizes forecasting intent]
        LLM -->|Invokes action with revenueTarget| FLOW

        FLOW[AutoLaunched Flow\nRun_Revenue_Forecast_Monte_Carlo]
        FLOW -->|Calls @InvocableMethod| APEX

        APEX[MonteCarloActionHandler.cls\nwith sharing — auto user-scoped]
        APEX -->|SOQL: Amount · Probability · CloseDate| OPPS

        OPPS[(Opportunity Records\nFiltered to current user\nOpen + closing this quarter)]
        OPPS -->|Deal math only| APEX

        APEX -->|HTTP POST via Named Credential| NC
        NC[Named Credential\nMonteCarlo_API]
    end

    subgraph Heroku ["Heroku  (Stateless)"]
        NC -->|HTTPS JSON payload| API
        API[FastAPI — main.py\nPydantic validation]
        API --> SIM
        SIM[simulation.py\nNumPy vectorized\n10,000 Monte Carlo runs]
        SIM -->|mean · p10 · p90 · target probability| API
        API -->|SimulationResponse JSON| NC
    end

    NC -->|Parsed ActionOutput| FLOW
    FLOW -->|summary · targetProbabilityPct · ranges| LLM
    LLM -->|Plain-English answer| U

    style U fill:#00A1E0,color:#fff
    style LLM fill:#0070D2,color:#fff
    style FLOW fill:#1B5E20,color:#fff
    style APEX fill:#1B5E20,color:#fff
    style OPPS fill:#1B5E20,color:#fff
    style NC fill:#1B5E20,color:#fff
    style SIM fill:#FF6B35,color:#fff
    style API fill:#FF6B35,color:#fff
```

**What this diagram shows:**
- Salesforce Opportunities stay in Salesforce — only deal math (`amount`, `probability`, `close_date`) leaves
- `with sharing` on the Apex class automatically scopes the SOQL to the current user — no user ID input required
- The simulation service is fully stateless — no data stored after the HTTP response
- The LLM never sees raw Opportunity data — only the computed narrative summary

**Key design decisions:**
- `with sharing` on the Apex class means users only forecast their own pipeline —
  no user ID input needed, no ownerIdFilter required
- Only `amount`, `probability`, and `close_date` leave Salesforce — no names,
  accounts, contacts, or custom fields
- The simulation service is fully stateless — no database, no sessions, no data at rest
- The AutoLaunched Flow acts as the Agentforce action wrapper, calling the Apex class
- `timeHorizonDays` defaults to end of current calendar quarter automatically if
  the user doesn't specify a custom window

---

## Agent Action Inputs & Outputs

### Inputs

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `revenueTarget` | Number | Yes | Dollar amount to forecast. Extracted from the user's message — e.g., "Will I hit $25M?" → `25000000` |
| `timeHorizonDays` | Number | No | Days from today to include opportunities closing within. Leave blank for "this quarter" — auto-calculated |

### Outputs

| Output | Type | Description |
|--------|------|-------------|
| `summary` | String | Plain-English answer — read this directly to the user |
| `targetProbabilityPct` | String | Probability of hitting the target, e.g., `"68.3%"` |
| `expectedRevenue` | Number | Mean revenue across all simulations (USD) |
| `p10Revenue` | Number | 10th percentile — pessimistic scenario |
| `p90Revenue` | Number | 90th percentile — optimistic scenario |
| `opportunitiesAnalyzed` | Number | Count of open opps included in simulation |
| `success` | Boolean | `true` if simulation completed; `false` on error |
| `errorMessage` | String | Error description if `success` is false |

---

## Data Residency

Designed to answer *"what leaves Salesforce?"* clearly.

**Leaves Salesforce (3 fields per opportunity):**
- `amount` — deal size as a number
- `probability` — win probability as a decimal (0.0–1.0)
- `close_date` — expected close date (ISO format)
- Opportunity `Id` as an anonymized internal identifier (not used in computation)

**Never leaves Salesforce:**
- Account names, opportunity names, contact names
- Owner names or user details
- Any custom fields
- Any other standard fields

**Why this is safe:**
The simulation engine only needs the mathematical inputs. The response contains
only computed statistics — no raw data is echoed back. All computation runs in
ephemeral memory; nothing is stored after the HTTP response completes.

For regulated industries, the service can be deployed in a customer-controlled
VPC (AWS Lambda) or on-premise to keep even the anonymous statistical data
inside the customer's environment.

---

## Repository Structure

```
├── api/
│   ├── main.py          FastAPI app, routes, OpenAPI 3.0 schema endpoint
│   ├── models.py        Pydantic request/response models
│   ├── simulation.py    Monte Carlo engine (NumPy vectorized)
│   └── config.py        Environment-based configuration (pydantic-settings)
│
├── salesforce/
│   ├── force-app/main/default/
│   │   ├── classes/
│   │   │   ├── MonteCarloActionHandler.cls          Invocable Apex (2 inputs)
│   │   │   └── MonteCarloActionHandlerTest.cls      Unit tests
│   │   ├── flows/
│   │   │   └── Run_Revenue_Forecast_Monte_Carlo     AutoLaunched Flow (action wrapper)
│   │   ├── genAiFunctions/
│   │   │   └── Run_Revenue_Forecast/                Agentforce action definition
│   │   ├── genAiPlugins/
│   │   │   └── Revenue_Forecasting                  Agentforce topic
│   │   ├── bots/
│   │   │   └── Monte_Carlo_Revenue_Forecaster/      Agent bot + version metadata
│   │   ├── namedCredentials/                        MonteCarlo_API endpoint config
│   │   └── remoteSiteSettings/                      Callout allowlist
│   ├── manifest/
│   │   └── package.xml                              Deployment manifest
│   ├── specs/
│   │   └── monteCarlorevenueForecaster.yaml         Agent creation spec
│   └── README_SETUP.md                              Salesforce setup guide
│
├── deploy/
│   ├── Dockerfile          Production container image
│   ├── docker-compose.yml  Local dev environment
│   └── deploy.sh           One-command deploy (local / Heroku / Lambda)
│
├── tests/
│   └── test_simulation.py  Unit tests for simulation math
│
├── docs/
│   ├── README.md               API reference and architecture deep-dive
│   └── WORKSHOP_WALKTHROUGH.md Facilitator guide for live demos
│
├── requirements.txt   Pinned Python dependencies
└── .env.example       Configuration template
```

---

## Quick Start — Local API

```bash
# Clone and configure
git clone https://github.com/ejochims/Agentforce-Monte-Carlo-Analysis.git
cd Agentforce-Monte-Carlo-Analysis
cp .env.example .env

# Start with Docker (hot-reload)
./deploy/deploy.sh local
# → API running at http://localhost:8000
# → Interactive docs at http://localhost:8000/docs
```

**Run a sample simulation:**

```bash
curl -X POST http://localhost:8000/api/v1/simulate \
  -H "Content-Type: application/json" \
  -d '{
    "opportunities": [
      {"name": "Deal A", "amount": 5000000, "probability": 0.75, "close_date": "2026-03-31"},
      {"name": "Deal B", "amount": 3000000, "probability": 0.60, "close_date": "2026-03-15"},
      {"name": "Deal C", "amount": 8000000, "probability": 0.40, "close_date": "2026-03-31"},
      {"name": "Deal D", "amount": 2000000, "probability": 0.90, "close_date": "2026-02-28"}
    ],
    "num_simulations": 10000,
    "revenue_targets": [10000000, 15000000, 20000000]
  }'
```

---

## Quick Start — Salesforce Deployment

**Prerequisites:** Salesforce org with Agentforce enabled, `sf` CLI installed.

```bash
# Deploy all metadata in one command:
# Apex class + test, AutoLaunched Flow, GenAiFunction, GenAiPlugin,
# Bot + BotVersion, Named Credential, Remote Site Setting
sf project deploy start \
  --manifest salesforce/manifest/package.xml \
  --target-org <your-org-alias>
```

After deployment:
1. Setup → Agentforce → Agents → open your agent
2. Topics tab → **Add Topic from Org** → select **Revenue Forecasting**
3. Activate the agent
4. Ask: *"What's my probability of hitting $10M this quarter?"*

See `salesforce/README_SETUP.md` for the full configuration walkthrough including
Named Credential setup and troubleshooting.

---

## Running Tests

**Python (simulation engine):**

```bash
cd api
pip install -r ../requirements.txt pytest httpx pytest-cov
pytest ../tests/ -v                                   # all tests
pytest ../tests/test_simulation.py::TestMonteCarloMath -v  # math only
pytest ../tests/ --cov=. --cov-report=term-missing    # with coverage
```

**Salesforce Apex:**

```bash
sf apex run test \
  --class-names MonteCarloActionHandlerTest \
  --target-org <your-org-alias> \
  --result-format human
```

**Test utterances for the Agentforce agent:**
- *"Will I hit $25 million this quarter?"*
- *"What's my probability of closing $10M by end of Q1?"*
- *"Am I on track for my $8M quota?"*
- *"Give me a realistic revenue range for the next 30 days"*

---

## Deployment

The live API is deployed at `https://monte-carlo-forecast-0b7519dafaaf.herokuapp.com`.

All Salesforce metadata already points to this URL — no configuration needed for demos.

| Target | Command |
|--------|---------|
| Local (Docker) | `./deploy/deploy.sh local` |
| Heroku | `./deploy/deploy.sh heroku --app <app-name>` |
| AWS Lambda | `./deploy/deploy.sh lambda --function-name monte-carlo-forecast --region us-east-1` |

**Health check:** `https://monte-carlo-forecast-0b7519dafaaf.herokuapp.com/health`

**API docs:** `https://monte-carlo-forecast-0b7519dafaaf.herokuapp.com/docs`
