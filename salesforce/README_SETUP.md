# Salesforce Setup Guide — Monte Carlo Forecast Integration

This guide walks through every Salesforce configuration step needed to connect
Agentforce to the Monte Carlo simulation service. Follow these steps in order.

---

## Prerequisites

- Salesforce org with Agentforce enabled (Spring '25 or later)
- Deployed Monte Carlo FastAPI service (see `deploy/` directory)
- Your service's public URL (e.g., `https://monte-carlo-forecast.herokuapp.com`)
- SFDX CLI installed locally (for deploying Apex)

---

## Step 1: Deploy the Apex Class

```bash
# From the repo root:
sf project deploy start \
  --source-dir salesforce/classes/ \
  --target-org <your-org-alias>
```

Verify in Setup → Apex Classes that `MonteCarloActionHandler` appears.

---

## Step 2: Create a Named Credential

Named Credentials store the external service URL and authentication so Apex
code never hardcodes endpoints or secrets.

### 2a. Create an External Credential (authentication container)

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

### 2b. Create the Named Credential

1. Setup → Security → Named Credentials → **Named Credentials** tab
2. Click **New**
3. Fill in:
   - **Label**: `Monte Carlo API`
   - **Name**: `MonteCarlo_API`  ← must match the constant in the Apex class
   - **URL**: `https://your-service-url.com`  ← your deployed service URL
   - **External Credential**: `Monte Carlo API Auth` (from step 2a)
   - **Allow Formulas in HTTP Header**: checked
   - **Allow Formulas in HTTP Body**: checked
4. Save

---

## Step 3: Register as an External Service

External Services lets Salesforce "understand" the API shape by importing the
OpenAPI schema. This generates Flow/Apex-callable classes automatically.

1. Setup → Integrations → **External Services**
2. Click **New External Service**
3. Fill in:
   - **External Service Name**: `MonteCarloForecastAPI`
   - **Select Named Credential**: `Monte Carlo API` (from step 2b)
   - **Service Schema**: Select **"Enter Service URL"**
   - **Schema URL**: `https://your-service-url.com/api/v1/schema`
4. Click **Save & Next** — Salesforce will fetch and parse the OpenAPI schema
5. Review the operations shown (you should see `runMonteCarloSimulation` and `healthCheck`)
6. Click **Next** and then **Done**

> **Troubleshooting**: If the schema fails to load, verify the service is running
> by visiting `https://your-service-url.com/health` in a browser. Also confirm
> the Named Credential URL doesn't have a trailing slash.

---

## Step 4: Configure the Agentforce Agent Action

This connects the Apex class to the Agentforce AI orchestrator.

1. Setup → Agent Studio → **Agents**
2. Open your Agent (or create a new one)
3. Go to the **Actions** tab
4. Click **New Agent Action**
5. Fill in:
   - **Reference Action Type**: `Apex`
   - **Apex Class**: `MonteCarloActionHandler`
   - **Agent Action Label**: `Run Revenue Forecast`
   - **Agent Action API Name**: `Run_Revenue_Forecast`
6. Under **Instructions** (this is the prompt that tells the LLM when to use this):
   ```
   Use this action when the user asks about revenue forecasts, pipeline probability,
   likelihood of hitting quota, quarter-end predictions, or "what are our chances of
   hitting [amount]". This action queries live Opportunity data and runs a Monte Carlo
   simulation to return probability-based revenue estimates.

   When the user specifies a time period like "this quarter", convert it to
   time_horizon_days (e.g., "this quarter" ≈ 90 days, "this half" ≈ 180 days).
   When the user mentions a revenue target like "$10M", pass it in revenue_targets_csv.
   ```
7. Map the input/output variables (see table below)
8. Save and **Activate** the action

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

## Metadata Templates (for version control)

### Named Credential XML (for SFDX deployment)

Save as `salesforce/namedCredentials/MonteCarlo_API.namedCredential-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<NamedCredential xmlns="http://soap.sforce.com/2006/04/metadata">
    <label>Monte Carlo API</label>
    <name>MonteCarlo_API</name>
    <protocol>NoAuthentication</protocol>
    <url>https://YOUR_SERVICE_URL_HERE</url>
    <allowMergeFieldsInBody>true</allowMergeFieldsInBody>
    <allowMergeFieldsInHeader>true</allowMergeFieldsInHeader>
    <generateAuthorizationHeader>false</generateAuthorizationHeader>
</NamedCredential>
```

> Replace `YOUR_SERVICE_URL_HERE` with your actual deployed service URL before deploying.

### Remote Site Setting XML

Save as `salesforce/remoteSiteSettings/MonteCarlo_API.remoteSite-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<RemoteSiteSetting xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>Monte Carlo Revenue Forecast API - allows Apex callouts to simulation service</description>
    <disableProtocolSecurity>false</disableProtocolSecurity>
    <isActive>true</isActive>
    <name>MonteCarlo_API</name>
    <url>https://YOUR_SERVICE_URL_HERE</url>
</RemoteSiteSetting>
```

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
