# Salesforce Setup Guide — Monte Carlo Forecast Integration

This guide walks through every Salesforce configuration step needed to connect
Agentforce to the Monte Carlo simulation service. Follow these steps in order.

---

## Prerequisites

- Salesforce org with Agentforce enabled (Spring '25 or later)
- SFDX CLI installed locally (`npm install -g @salesforce/cli`)

The FastAPI service is already live at `https://monte-carlo-forecast-0b7519dafaaf.herokuapp.com`.
All credential and action metadata in this repo already point to that URL — no
URL configuration needed.

---

## Step 0: One-Command Deploy (fastest path)

```bash
# Deploy all Salesforce metadata in a single command:
# - MonteCarloActionHandler Apex class + test class
# - Named Credential (pre-configured for monte-carlo-forecast.herokuapp.com)
# - External Credential
# - Remote Site Setting
# - GenAiFunction (Agentforce action definition)
# - GenAiPlugin (Agentforce topic)

sf project deploy start \
  --manifest salesforce/manifest/package.xml \
  --target-org <your-org-alias>
```

After this succeeds, skip to **Step 4** to wire the topic to your agent.
Steps 1–3 below document what was deployed and how to verify it.

---

## Step 1: Deploy the Apex Class

The Apex class is included in the manifest above. To deploy it in isolation:

```bash
sf project deploy start \
  --source-dir salesforce/force-app/main/default/classes \
  --target-org <your-org-alias>
```

Verify in Setup → Apex Classes that `MonteCarloActionHandler` appears.

---

## Step 2: Named Credential (pre-configured — deployed via manifest)

Named Credentials store the external service URL and authentication so Apex
code never hardcodes endpoints or secrets.

If you ran Step 0 (one-command deploy), the Named Credential is already deployed
and points to `https://monte-carlo-forecast-0b7519dafaaf.herokuapp.com`.

**To verify:** Setup → Security → Named Credentials → find `Monte Carlo API`

### Manual setup (if not using the manifest)

#### 2a. Create an External Credential (authentication container)

1. Setup → Security → Named Credentials → **External Credentials** tab
2. Click **New**
3. Fill in:
   - **Label**: `Monte Carlo API Auth`
   - **Name**: `MonteCarlo_API_Auth`
   - **Authentication Protocol**: `No Authentication`
     _(Use "Custom Header" if your deployment uses an API key — see note below)_
4. Under **Principals**, add a new Principal:
   - **Parameter Name**: `default`
   - **Sequence Number**: 1
5. Save

> **If you use API key authentication**, select "Custom Header" protocol and add
> a header named `X-API-Key` with your key value. Never put secrets in code.

#### 2b. Create the Named Credential

1. Setup → Security → Named Credentials → **Named Credentials** tab
2. Click **New**
3. Fill in:
   - **Label**: `Monte Carlo API`
   - **Name**: `MonteCarlo_API`  ← must match the constant in the Apex class
   - **URL**: `https://monte-carlo-forecast-0b7519dafaaf.herokuapp.com`
   - **External Credential**: `Monte Carlo API Auth` (from step 2a)
   - **Allow Formulas in HTTP Header**: checked
   - **Allow Formulas in HTTP Body**: checked
4. Save

---

## Step 3: Register as an External Service

External Services lets Salesforce "understand" the API shape by importing the
OpenAPI schema. This step is still done via the Setup UI (External Service
registration is not deployable via metadata).

1. Setup → Integrations → **External Services**
2. Click **New External Service**
3. Fill in:
   - **External Service Name**: `MonteCarloForecastAPI`
   - **Select Named Credential**: `Monte Carlo API`
   - **Service Schema**: Select **"Enter Service URL"**
   - **Schema URL**: `https://monte-carlo-forecast-0b7519dafaaf.herokuapp.com/api/v1/schema`
4. Click **Save & Next** — Salesforce will fetch and parse the OpenAPI schema
5. Review the operations shown (you should see `runMonteCarloSimulation` and `healthCheck`)
6. Click **Next** and then **Done**

> **Troubleshooting**: If the schema fails to load, verify the service is running
> by visiting `https://monte-carlo-forecast-0b7519dafaaf.herokuapp.com/health` in a browser.
> Also confirm the Named Credential URL doesn't have a trailing slash.

---

## Step 4: Wire the Agent Topic (GenAiPlugin → Your Agent)

The `Revenue_Forecasting` topic and `Run_Revenue_Forecast` action are deployed
via the manifest in Step 0. The final step is attaching the topic to your agent.

1. Setup → **Agentforce** → **Agents**
2. Open your Agent (or create a new one)
3. Go to the **Topics** tab
4. Click **Add Topic from Org**
5. Select **Revenue Forecasting** — this includes the `Run Revenue Forecast` action
6. Save and **Activate** the agent

The action's routing instructions (capability text) are pre-written in
`genAiFunctions/Run_Revenue_Forecast.genAiFunction-meta.xml`. The LLM will
automatically invoke the forecast when users ask questions like:
- "What's our chance of hitting $10M this quarter?"
- "Give me a Q1 pipeline forecast"
- "What's the probability we hit quota?"

### Manual action setup (if not using the deployed GenAiFunction)

If you need to register the action manually instead:

1. Setup → Agent Studio → **Agents** → [Your Agent] → **Actions** → **New Agent Action**
2. Fill in:
   - **Reference Action Type**: `Apex`
   - **Apex Class**: `MonteCarloActionHandler`
   - **Agent Action Label**: `Run Revenue Forecast`
   - **Agent Action API Name**: `Run_Revenue_Forecast`
3. Under **Instructions**:
   ```
   Use this action when the user asks about revenue forecasts, pipeline probability,
   likelihood of hitting quota, quarter-end predictions, or "what are our chances of
   hitting [amount]". This action queries live Opportunity data and runs a Monte Carlo
   simulation to return probability-based revenue estimates.

   When the user specifies a time period like "this quarter", convert it to
   time_horizon_days (e.g., "this quarter" ≈ 90 days, "this half" ≈ 180 days).
   When the user mentions a revenue target like "$10M", pass it in revenue_targets_csv.
   ```
4. Map the input/output variables (see table below)
5. Save and **Activate** the action

### Input Variable Mapping

| Agent Action Input | Maps To | Notes |
|--------------------|---------|-------|
| `timeHorizonDays` | LLM-extracted integer | "this quarter" → 90 |
| `revenueTargetsCSV` | LLM-extracted string | "$10M, $15M" → "10000000,15000000" |
| `stageFilter` | LLM-extracted string | Optional, leave blank for all stages |
| `numSimulations` | Fixed value: `10000` | Increase to 50000 for high-stakes analysis |

### Output Variable Mapping

| Output Variable | Use in Agent Response Template |
|----------------|-------------------------------|
| `summary` | Surface directly — pre-written natural language |
| `targetAnalysisJson` | Parse for specific target probabilities |
| `expectedRevenue` | Use in custom response templates |

---

## Step 5: Test the Integration

### Option A: Test via Agent Builder
1. In Setup → Agent Studio, open your Agent
2. Use the **Preview** panel (right side) to chat
3. Ask: _"What's our Q1 forecast? What's our chance of hitting $10M?"_
4. Verify the agent calls the action and returns simulation results

### Option B: Test via Anonymous Apex
```apex
// Run in Setup → Developer Console → Execute Anonymous
MonteCarloActionHandler.ActionInput input = new MonteCarloActionHandler.ActionInput();
input.timeHorizonDays = 90;
input.revenueTargetsCSV = '5000000,10000000';
input.numSimulations = 1000;

List<MonteCarloActionHandler.ActionInput> inputs =
    new List<MonteCarloActionHandler.ActionInput>{ input };

List<MonteCarloActionHandler.ActionOutput> outputs =
    MonteCarloActionHandler.runForecast(inputs);

System.debug('Summary: ' + outputs[0].summary);
System.debug('Expected Revenue: ' + outputs[0].expectedRevenue);
System.debug('Success: ' + outputs[0].success);
```

---

## Deployed Metadata Files

All metadata is pre-configured and lives in `salesforce/force-app/main/default/`.
No templates to fill in — the files are ready to deploy as-is.

| File | Type | Purpose |
|------|------|---------|
| `externalCredentials/MonteCarlo_API_Auth.externalCredential-meta.xml` | ExternalCredential | Auth container (Anonymous — no credentials needed) |
| `namedCredentials/MonteCarlo_API.namedCredential-meta.xml` | NamedCredential | Service endpoint (`monte-carlo-forecast.herokuapp.com`) |
| `remoteSiteSettings/MonteCarlo_API.remoteSite-meta.xml` | RemoteSiteSetting | Callout whitelist for the Heroku domain |
| `genAiFunctions/Run_Revenue_Forecast.genAiFunction-meta.xml` | GenAiFunction | Agentforce action wiring to MonteCarloActionHandler |
| `genAiPlugins/Revenue_Forecasting.genAiPlugin-meta.xml` | GenAiPlugin | Agentforce topic grouping the forecast action |
| `classes/MonteCarloActionHandler.cls` | ApexClass | Core callout and response logic |
| `classes/MonteCarloActionHandlerTest.cls` | ApexClass | Unit tests (required for org deployment coverage gates) |

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `CALLOUT_EXCEPTION: Unauthorized endpoint` | Missing Remote Site Setting | Add the service URL in Setup → Remote Site Settings |
| `CALLOUT_EXCEPTION: Read timed out` | Simulation taking >30s | Reduce `num_simulations` or check service health |
| Schema fails to load in External Services | Schema endpoint unreachable | Verify `/api/v1/schema` is publicly accessible |
| Agent doesn't invoke the action | Action instructions too vague | Refine the instruction text in Agent Action configuration |
| `JSONException` in Apex logs | API response format mismatch | Check API version compatibility, review `rawResponseJson` field |

---

## Data Flow Diagram

```
User (Slack/Chat)
      │
      ▼
Agentforce LLM Orchestrator
  "User wants a Q1 forecast targeting $10M"
      │
      ▼
Agent Action: Run Revenue Forecast
  (MonteCarloActionHandler.runForecast)
      │
      ├─► SOQL Query: SELECT Amount, Probability, CloseDate
      │   FROM Opportunity WHERE IsClosed = false
      │   AND CloseDate <= [90 days from now]
      │
      ▼
Named Credential: MonteCarlo_API
  POST /api/v1/simulate
  { opportunities: [...amounts + probabilities only] }
      │
      ▼
FastAPI Service (numpy)
  10,000 Monte Carlo runs
      │
      ▼
Response: { mean: $9.4M, p10: $7.2M, p90: $11.8M,
            targets: [{ "$10M": "68%" }] }
      │
      ▼
ActionOutput.summary:
  "Your expected Q1 revenue is $9.4M, ranging from
   $7.2M to $11.8M. You have a 68% chance of hitting $10M."
      │
      ▼
User sees conversational response in Slack/Chat
```
