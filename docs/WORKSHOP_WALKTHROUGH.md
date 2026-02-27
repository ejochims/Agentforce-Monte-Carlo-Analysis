# Workshop Facilitator Guide: Agentforce Monte Carlo Forecasting

**Session title:** Agentforce as Orchestrator — Live Pipeline Forecasting Demo
**Audience:** Technical Solution Engineers, Solution Architects, Technical AEs
**Duration:** 45–60 minutes (demo) + 30 minutes (hands-on optional)
**Difficulty:** Intermediate (attendees can read code, may not write it daily)

---

## Before the Workshop

### Setup Checklist (complete 24h before)

- [ ] Monte Carlo service deployed to public URL (Heroku recommended for simplicity)
- [ ] Service health check passing: `curl https://your-app.herokuapp.com/health`
- [ ] Salesforce sandbox org with Agentforce enabled
- [ ] Named Credential `MonteCarlo_API` configured and tested
- [ ] Apex class `MonteCarloActionHandler` deployed to the sandbox
- [ ] Agent Action created and activated in Agent Studio
- [ ] Test pipeline data loaded (10–20 sample Opportunities with varying probability/amount)
- [ ] Local backup: `docker-compose up` running on your laptop (fallback if cloud service is down)

### Environment Setup

```bash
# Start local backup service (do this before the session)
./deploy/deploy.sh local

# Verify it's running
curl http://localhost:8000/health

# Optional: expose locally with ngrok for Salesforce testing
ngrok http 8000
```

---

## Workshop Agenda

### Segment 1: Context Setting (10 min)

**Talk track:**

> "Today we're going to look at one of the most powerful patterns in Agentforce — using the agent as an *orchestrator* that calls external compute services, not just as a chat interface to Salesforce data.
>
> The problem we're solving: a revenue forecast. Traditional Salesforce forecasting gives you the weighted pipeline — you multiply each deal's probability by its amount and sum them up. That tells you the *expected value*, but it doesn't tell you the *distribution of possible outcomes*.
>
> If your weighted pipeline is $10M, is that likely? Could you hit $15M? Is there a real chance you end up at $6M? Monte Carlo simulation answers these questions."

**Key concept to land:** *Expected value vs. probability distribution*

Draw on whiteboard (or share slide):
```
Traditional Forecast:  $8.5M  (one number — "expected value")

Monte Carlo Forecast:  $6M ──────▓▓▓▓▓▓████████▓▓▓▓── $14M
                              p10: $7.2M   p90: $11.8M
                              Mean: $9.4M | 68% chance of $10M
```

---

### Segment 2: Architecture Walkthrough (10 min)

**Walk through the `docs/README.md` architecture diagram.**

Key points to emphasize:

**1. What stays in Salesforce:**
> "Notice the Opportunity data stays in Salesforce — only three fields leave: amount, probability, and close date. No account names. No contacts. This is important for regulated customers."

**2. The LLM never sees raw data:**
> "The Agentforce LLM doesn't write SOQL or call APIs. It decides *that* a forecast is needed, then calls the Agent Action. The Apex class does all the heavy lifting — querying data, making the callout, parsing the response."

**3. Why external compute:**
> "Running 10,000 simulations in Apex would be impractical — you'd hit governor limits immediately. We offload compute-intensive work to a stateless microservice. This is the Agentforce-as-orchestrator pattern."

**Show the code briefly** (don't read it line-by-line):

```python
# simulation.py — the core math is just 4 lines of numpy
random_draws = np.random.uniform(0, 1, size=(num_simulations, len(opportunities)))
won_matrix = random_draws < probabilities
revenue_per_run = (won_matrix * amounts).sum(axis=1)
```

> "That's it. The magic of Monte Carlo is that it's conceptually simple — flip a weighted coin for every deal, sum the wins, repeat 10,000 times. NumPy does all 10,000 runs simultaneously in 50 milliseconds."

---

### Segment 3: Live Demo (15 min)

**Demo flow — follow this sequence exactly.**

#### 3a. Show the raw API (2 min)
Open `http://localhost:8000/docs` in browser.

> "Before we see it through Agentforce, let's look at the raw API. This is what the Apex class calls internally."

Run the sample payload from the docs (or use the Swagger UI). Point to:
- The `summary_statistics` block
- The `target_analysis` (this is the key output for the agent)
- The `compute_time_ms` in metadata

> "52 milliseconds for 10,000 simulations. This is why we use NumPy."

#### 3b. Show the Apex class (3 min)
Open `MonteCarloActionHandler.cls` in VS Code or browser.

Navigate to the `buildDynamicSOQL` method:
> "This is where the magic happens on the Salesforce side. The Apex class queries live Opportunity data — respecting record-level security — and shapes it into the API payload. Only amount, probability, and close date are serialized."

Navigate to `buildNarrativeSummary`:
> "This builds the sentence the agent speaks. It picks the most interesting target probability — the one closest to 50%, because that's the one that gives the richest decision-making information."

#### 3c. Show the Agent Action in Setup (3 min)
Open Setup → Agent Studio → Your Agent → Actions.

> "The instructions text here is the prompt that tells the LLM when to invoke this action. This is prompt engineering — we're teaching the AI when this tool is appropriate."

Read the instruction aloud:
> *"Use this action when the user asks about revenue forecasts, pipeline probability, likelihood of hitting quota..."*

> "Notice it also instructs the LLM to translate natural language time references — 'this quarter' → 90 days. The LLM handles that translation before calling the Apex class."

#### 3d. Live Agentforce conversation (7 min)
Open the Agent preview panel (or Slack if connected).

**Ask these questions in sequence:**

1. **Simple forecast:**
   > _"What does our Q1 pipeline look like?"_

   Expected: Agent calls the action, returns a summary with expected revenue range.

2. **Target-specific question:**
   > _"What's our probability of hitting $10M this quarter?"_

   Expected: Agent returns the specific probability percentage from `target_analysis`.

3. **Scenario comparison:**
   > _"What if we only focus on high-probability deals — 70% or above?"_

   Expected: Agent calls the action with `minProbability=70`, returns a tighter forecast.

4. **Push for detail:**
   > _"Give me the pessimistic and optimistic scenarios."_

   Expected: Agent returns p10 and p90 values in plain language.

**What to do if the demo breaks:**
- If the cloud service is down → switch to local service, update Named Credential URL to ngrok
- If Agentforce doesn't call the action → ask the question more directly ("Run the Monte Carlo forecast for Q1")
- If the Apex callout fails → run it manually in Execute Anonymous (see `README_SETUP.md`)

---

### Segment 4: Key Concepts Discussion (10 min)

Use these questions to drive discussion:

**Q1: "When would you use this pattern vs. built-in Agentforce capabilities?"**

*Good answers:* When you need compute beyond Apex governor limits, when results require specialized libraries (ML, stats, math), when the compute service needs to be reused outside Salesforce, when data residency requires the computation to be in a specific region.

**Q2: "What would you add to make this production-ready?"**

*Prompt for:*
- Authentication on the API (API key in Named Credential custom headers)
- Caching (same input = same result, could cache 5 minutes)
- Monitoring (Splunk/Datadog integration, error alerting)
- Stricter data anonymization (hash opportunity IDs before sending)
- Rate limiting

**Q3: "How would you adapt this for a specific customer vertical?"**

*Examples to offer:*
- **Financial Services:** Replace Opportunities with policy renewal data, calculate probability of retention targets
- **Healthcare/Life Sciences:** Forecast clinical trial site activation against enrollment targets
- **Manufacturing:** Model component availability probabilities against production schedules

---

### Segment 5: Hands-On (30 min, optional)

**Goal:** Attendees get the service running locally and call it from Postman or Apex.

**Exercise 1: Run locally (10 min)**
```bash
git clone <repo>
cd monte-carlo-forecast
./deploy/deploy.sh local
```
Verify: `curl http://localhost:8000/health`

**Exercise 2: Modify the simulation (10 min)**

In `api/simulation.py`, find this section in `run_full_simulation`:
```python
targets = revenue_targets if revenue_targets else settings.default_revenue_targets
```

Challenge: Add a `conservative_factor` parameter that scales all probabilities down by 10% to model sandbagging:
```python
# Example: scale probabilities for "sandbagging adjustment"
if conservative_factor:
    for opp in filtered_opps:
        opp.probability = opp.probability * (1 - conservative_factor)
```

**Exercise 3: Test from Anonymous Apex (10 min)**

In a connected sandbox org, open Developer Console → Execute Anonymous and run:
```apex
MonteCarloActionHandler.ActionInput input = new MonteCarloActionHandler.ActionInput();
input.timeHorizonDays = 90;
input.revenueTargetsCSV = '5000000,10000000';
input.numSimulations = 1000;

List<MonteCarloActionHandler.ActionOutput> results =
    MonteCarloActionHandler.runForecast(
        new List<MonteCarloActionHandler.ActionInput>{ input }
    );

System.debug(results[0].summary);
```

---

## FAQ / Likely Questions

**"Does Salesforce support OpenAPI 3.1 yet?"**
> No, as of Spring '25 External Services requires OpenAPI 3.0. That's why we have the `/api/v1/schema` endpoint that hand-crafts a 3.0-compliant spec instead of using FastAPI's built-in 3.1 generator.

**"Can we run this in Salesforce Functions instead?"**
> Salesforce Functions was deprecated. The Named Credential + external service pattern is the current recommended approach for external compute.

**"How do we handle authentication for the API in production?"**
> Add a custom header in the Named Credential (`X-API-Key: your-secret`). Set the API key via Heroku/AWS environment variable. Add a middleware in `main.py` that validates the header. Never put secrets in code.

**"What about data sovereignty for EU customers?"**
> Deploy the service in an EU region (Heroku EU runtime, AWS eu-west-1). The service never stores data — it's truly stateless. For maximum control, customers can run it in their own AWS VPC with a private endpoint, and Salesforce can connect via External Credential with certificate-based auth.

**"How accurate is Monte Carlo vs. weighted pipeline?"**
> Both give the same *expected value* (they converge mathematically). Monte Carlo's advantage is the *distribution* — it tells you the range and probability of outcomes, not just the average. For quota attainment decisions, the distribution is the point.

**"Can we add ML to this? Better probability estimates?"**
> Absolutely — that's the natural next step. The simulation engine can accept any probability distribution. You could add a `/calibrate` endpoint that takes historical win/loss data and returns calibrated probabilities to feed back into the simulation.

---

## Presenter Notes

- **Pace**: Go slower on the architecture diagram than you think you need to. Attendees need time to absorb the callout chain.
- **Jargon**: Avoid "Lambda calculus", "vectorized operations", "ASGI" — just say "the math runs fast" and "the server".
- **The money moment**: When you show a specific target probability (e.g., "68% chance of hitting $10M"), pause and let it land. That's the insight the customer is paying for.
- **Bring customer context**: Before the session, look up the customer's public revenue targets (10-K, analyst estimates) and plug those numbers in as the `revenue_targets`. Nothing lands like: "You have a 58% chance of hitting your $4.2B guidance."
