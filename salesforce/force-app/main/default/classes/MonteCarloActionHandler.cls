/**
 * MonteCarloActionHandler.cls
 *
 * PURPOSE:
 *   Invocable Apex class that serves as the bridge between Agentforce and the
 *   Monte Carlo FastAPI service. When an Agentforce Agent needs to run a
 *   revenue forecast, it calls this Action, which:
 *     1. Queries Opportunities from the current org
 *     2. Applies optional filters (time horizon, stage, segment)
 *     3. Posts the data to the Monte Carlo service via Named Credential
 *     4. Parses the response and returns structured results
 *
 * AGENTFORCE PATTERN:
 *   This class is the "tool" that the Agentforce LLM calls when it decides
 *   a revenue forecast is needed. The LLM never writes SOQL or calls APIs
 *   directly — it invokes this Action with high-level parameters, and this
 *   class handles all the technical execution.
 *
 * DATA PRIVACY NOTE:
 *   Only Opportunity.Amount, Opportunity.Probability, and Opportunity.CloseDate
 *   are sent to the external service. No account names, contact info, or other
 *   PII leaves Salesforce. The "name" field sent is an internal Opportunity ID
 *   (or anonymized label) for correlation purposes only.
 *
 * SETUP REQUIREMENTS:
 *   - Named Credential: "MonteCarlo_API" pointing to your deployed service
 *   - External Service registration (see README_SETUP.md)
 *   - Connected App with appropriate permissions
 *   - Remote Site Setting for the service URL (if not using Named Credential URL)
 *
 * @author  Salesforce Solution Engineering
 * @version 1.0
 * @apiVersion 62.0
 */
public with sharing class MonteCarloActionHandler {

    // ─── Named Credential ────────────────────────────────────────────────────
    // This matches the Named Credential label you create in Setup.
    // If you rename the credential, update this constant.
    private static final String NAMED_CREDENTIAL = 'callout:MonteCarlo_API';
    private static final String SIMULATE_ENDPOINT = '/api/v1/simulate';
    private static final Integer HTTP_TIMEOUT_MS = 30000; // 30 seconds

    // ─── Input/Output Data Transfer Objects ─────────────────────────────────

    /**
     * Input parameters for the Agent Action.
     * The Agentforce LLM populates these from the natural language conversation.
     */
    public class ActionInput {

        @InvocableVariable(
            label='Time Horizon (Days)'
            description='Only include opportunities closing within this many days. Use 90 for this quarter, 180 for this half. Leave blank for all open pipeline.'
            required=false
        )
        public Integer timeHorizonDays;

        @InvocableVariable(
            label='Number of Simulations'
            description='How many Monte Carlo iterations to run. Default 10000 gives good accuracy. Increase to 50000 for important decisions.'
            required=false
        )
        public Integer numSimulations;

        @InvocableVariable(
            label='Revenue Targets (comma-separated USD)'
            description='Revenue targets to calculate hit-probability for, as comma-separated numbers. Example: "5000000,10000000,20000000". Leave blank for defaults.'
            required=false
        )
        public String revenueTargetsCSV;

        @InvocableVariable(
            label='Opportunity Stage Filter'
            description='Only include opportunities in these stages. Comma-separated. Example: "Proposal/Price Quote,Value Proposition,Id. Decision Makers". Leave blank for all stages.'
            required=false
        )
        public String stageFilter;

        @InvocableVariable(
            label='Minimum Probability'
            description='Only include opportunities with win probability >= this value (0-100). Example: 20 means only deals with 20%+ probability.'
            required=false
        )
        public Integer minProbability;

        @InvocableVariable(
            label='Owner ID Filter'
            description='Salesforce User ID to filter by owner. Leave blank to include all reps. Useful for manager-level forecasting.'
            required=false
        )
        public String ownerIdFilter;
    }

    /**
     * Output returned to the Agentforce Agent after simulation completes.
     * The LLM uses these fields to compose a conversational response.
     * Field descriptions are written to guide the LLM's language generation.
     */
    public class ActionOutput {

        @InvocableVariable(
            label='Summary'
            description='One-paragraph natural language summary of the forecast results, ready to speak to the user.'
        )
        public String summary;

        @InvocableVariable(
            label='Expected Revenue'
            description='Mean revenue outcome across all simulations, in USD.'
        )
        public Decimal expectedRevenue;

        @InvocableVariable(
            label='Median Revenue'
            description='Median revenue outcome — the "most likely" single number.'
        )
        public Decimal medianRevenue;

        @InvocableVariable(
            label='P10 Revenue (Pessimistic)'
            description='10th percentile — only 10% of scenarios produced less than this amount.'
        )
        public Decimal p10Revenue;

        @InvocableVariable(
            label='P90 Revenue (Optimistic)'
            description='90th percentile — only 10% of scenarios produced more than this amount.'
        )
        public Decimal p90Revenue;

        @InvocableVariable(
            label='Target Analysis JSON'
            description='JSON array of revenue targets with hit-probabilities. Example: [{target:10000000, probability_pct:"72.4%"}]'
        )
        public String targetAnalysisJson;

        @InvocableVariable(
            label='Opportunities Analyzed'
            description='Number of opportunities included in the simulation.'
        )
        public Integer opportunitiesAnalyzed;

        @InvocableVariable(
            label='Compute Time (ms)'
            description='How long the simulation took to run in milliseconds.'
        )
        public Decimal computeTimeMs;

        @InvocableVariable(
            label='Success'
            description='True if the simulation ran successfully. False if there was an error.'
        )
        public Boolean success;

        @InvocableVariable(
            label='Error Message'
            description='If success is false, contains the error description.'
        )
        public String errorMessage;

        @InvocableVariable(
            label='Raw Response JSON'
            description='Full JSON response from the simulation service, for advanced use cases or debugging.'
        )
        public String rawResponseJson;
    }

    // ─── Invocable Entry Point ────────────────────────────────────────────────

    /**
     * Main invocable method called by Agentforce.
     *
     * Agentforce passes a list of ActionInput (always a list, even for single
     * invocations — this is the Invocable framework convention). We process
     * each input and return a corresponding list of ActionOutput.
     *
     * @param inputs  List of ActionInput from the Agentforce orchestrator
     * @return        List of ActionOutput with simulation results
     */
    @InvocableMethod(
        label='Run Monte Carlo Revenue Forecast'
        description='Queries open Opportunities and runs a Monte Carlo simulation to forecast revenue probability. Use when the user asks about pipeline likelihood, revenue targets, or quarter-end forecasts. Returns probability of hitting revenue targets and distribution statistics.'
        category='Revenue Forecasting'
        callout=true
    )
    public static List<ActionOutput> runForecast(List<ActionInput> inputs) {
        List<ActionOutput> outputs = new List<ActionOutput>();

        for (ActionInput input : inputs) {
            ActionOutput output = new ActionOutput();
            try {
                output = executeForecast(input);
                output.success = true;
            } catch (CalloutException e) {
                output.success = false;
                output.errorMessage = 'Callout to Monte Carlo service failed: ' + e.getMessage()
                    + '. Check Named Credential "MonteCarlo_API" configuration.';
                System.debug(LoggingLevel.ERROR, 'MonteCarloActionHandler callout error: ' + e.getMessage());
            } catch (JSONException e) {
                output.success = false;
                output.errorMessage = 'Failed to parse simulation response: ' + e.getMessage();
                System.debug(LoggingLevel.ERROR, 'MonteCarloActionHandler JSON error: ' + e.getMessage());
            } catch (Exception e) {
                output.success = false;
                output.errorMessage = 'Unexpected error: ' + e.getMessage();
                System.debug(LoggingLevel.ERROR, 'MonteCarloActionHandler unexpected error: ' + e.getMessage());
            }
            outputs.add(output);
        }

        return outputs;
    }

    // ─── Private Implementation ───────────────────────────────────────────────

    /**
     * Core execution: query Opportunities, call service, parse response.
     */
    private static ActionOutput executeForecast(ActionInput input) {
        // Step 1: Query opportunities with applied filters
        List<Opportunity> opps = queryOpportunities(input);

        if (opps.isEmpty()) {
            ActionOutput emptyOutput = new ActionOutput();
            emptyOutput.success = true;
            emptyOutput.summary = 'No open opportunities found matching the specified criteria. '
                + 'Try broadening the filter (e.g., increase time horizon or remove stage filters).';
            emptyOutput.opportunitiesAnalyzed = 0;
            return emptyOutput;
        }

        // Step 2: Build the API request payload
        Map<String, Object> requestPayload = buildRequestPayload(opps, input);

        // Step 3: Call the Monte Carlo service
        String responseBody = callMonteCarloService(requestPayload);

        // Step 4: Parse and return the response
        return parseSimulationResponse(responseBody, opps.size());
    }

    /**
     * Query open Opportunities with dynamic filters.
     *
     * IMPORTANT: This runs as the current user (with sharing) so it respects
     * Salesforce record-level security. Users only forecast their own pipeline
     * unless they have broader access.
     */
    private static List<Opportunity> queryOpportunities(ActionInput input) {
        String soql = buildDynamicSOQL(input);
        System.debug('MonteCarloActionHandler SOQL: ' + soql);
        return Database.query(soql);
    }

    /**
     * Build dynamic SOQL based on input filters.
     * Uses bind variables where possible to prevent SOQL injection.
     */
    private static String buildDynamicSOQL(ActionInput input) {
        List<String> whereClauses = new List<String>();

        // Always filter to open opportunities
        whereClauses.add('IsClosed = false');
        whereClauses.add('Amount != null');
        whereClauses.add('Probability != null');
        whereClauses.add('CloseDate != null');

        // Time horizon filter
        if (input.timeHorizonDays != null && input.timeHorizonDays > 0) {
            Date horizonDate = Date.today().addDays(input.timeHorizonDays);
            // Using string interpolation for date — safe since horizonDate is a Date object, not user input
            whereClauses.add('CloseDate <= ' + horizonDate.format());
            whereClauses.add('CloseDate >= TODAY');
        }

        // Stage filter
        if (String.isNotBlank(input.stageFilter)) {
            List<String> stages = input.stageFilter.split(',');
            List<String> quotedStages = new List<String>();
            for (String stage : stages) {
                // Escape single quotes to prevent SOQL injection
                quotedStages.add('\'' + String.escapeSingleQuotes(stage.trim()) + '\'');
            }
            whereClauses.add('StageName IN (' + String.join(quotedStages, ',') + ')');
        }

        // Minimum probability filter
        if (input.minProbability != null && input.minProbability > 0) {
            Integer minProb = Math.min(Math.max(input.minProbability, 0), 100);
            whereClauses.add('Probability >= ' + minProb);
        }

        // Owner filter
        if (String.isNotBlank(input.ownerIdFilter)) {
            String safeOwnerId = String.escapeSingleQuotes(input.ownerIdFilter.trim());
            whereClauses.add('OwnerId = \'' + safeOwnerId + '\'');
        }

        return 'SELECT Id, Name, Amount, Probability, CloseDate, StageName '
            + 'FROM Opportunity '
            + 'WHERE ' + String.join(whereClauses, ' AND ')
            + ' ORDER BY CloseDate ASC '
            + 'LIMIT 500';
    }

    /**
     * Build the JSON payload for the Monte Carlo API.
     *
     * Opportunities are serialized with only the statistical fields needed —
     * no account names, contacts, or other sensitive data leave Salesforce.
     */
    private static Map<String, Object> buildRequestPayload(
        List<Opportunity> opps,
        ActionInput input
    ) {
        List<Map<String, Object>> oppList = new List<Map<String, Object>>();

        for (Opportunity opp : opps) {
            Map<String, Object> oppData = new Map<String, Object>{
                // Use anonymized ID, not the opportunity name, for data privacy
                'name'         => opp.Id,
                'amount'       => opp.Amount,
                // Salesforce stores probability as 0-100; API expects 0.0-1.0
                'probability'  => opp.Probability / 100.0,
                'close_date'   => String.valueOf(opp.CloseDate)
            };
            oppList.add(oppData);
        }

        Map<String, Object> payload = new Map<String, Object>{
            'opportunities'    => oppList,
            'num_simulations'  => input.numSimulations != null ? input.numSimulations : 10000,
            'time_horizon_days' => input.timeHorizonDays
        };

        // Parse revenue targets from CSV string
        if (String.isNotBlank(input.revenueTargetsCSV)) {
            List<Object> targets = new List<Object>();
            for (String t : input.revenueTargetsCSV.split(',')) {
                try {
                    targets.add(Decimal.valueOf(t.trim()));
                } catch (Exception e) {
                    // Skip malformed values
                    System.debug('Skipping invalid revenue target: ' + t);
                }
            }
            if (!targets.isEmpty()) {
                payload.put('revenue_targets', targets);
            }
        }

        return payload;
    }

    /**
     * Make the HTTP callout to the Monte Carlo service via Named Credential.
     *
     * The Named Credential handles:
     *   - Base URL (so we don't hardcode the service endpoint)
     *   - Authentication headers (if your deployment uses API key auth)
     *   - Certificate validation
     */
    private static String callMonteCarloService(Map<String, Object> payload) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + SIMULATE_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(HTTP_TIMEOUT_MS);
        req.setBody(JSON.serialize(payload));

        Http http = new Http();
        HttpResponse res = http.send(req);

        System.debug('Monte Carlo API response status: ' + res.getStatusCode());

        if (res.getStatusCode() != 200) {
            throw new CalloutException(
                'Monte Carlo API returned status ' + res.getStatusCode()
                + ': ' + res.getBody()
            );
        }

        return res.getBody();
    }

    /**
     * Parse the JSON response from the simulation service into ActionOutput.
     *
     * We use deserializeUntyped() for flexibility — if the API adds new fields
     * in the future, this won't break. Key fields are explicitly extracted.
     */
    private static ActionOutput parseSimulationResponse(String responseBody, Integer totalOpps) {
        ActionOutput output = new ActionOutput();
        output.rawResponseJson = responseBody;

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(responseBody);

        // ── Extract summary statistics ────────────────────────────────────────
        Map<String, Object> stats = (Map<String, Object>) response.get('summary_statistics');
        if (stats != null) {
            output.expectedRevenue  = toDecimal(stats.get('mean'));
            output.medianRevenue    = toDecimal(stats.get('median'));
            output.p10Revenue       = toDecimal(stats.get('p10'));
            output.p90Revenue       = toDecimal(stats.get('p90'));
        }

        // ── Extract metadata ──────────────────────────────────────────────────
        Map<String, Object> metadata = (Map<String, Object>) response.get('metadata');
        if (metadata != null) {
            output.opportunitiesAnalyzed = (Integer) metadata.get('opportunities_included');
            output.computeTimeMs = toDecimal(metadata.get('compute_time_ms'));
        }

        // ── Extract and serialize target analysis ─────────────────────────────
        List<Object> targetList = (List<Object>) response.get('target_analysis');
        if (targetList != null) {
            output.targetAnalysisJson = JSON.serialize(targetList);
        }

        // ── Build human-readable summary ──────────────────────────────────────
        output.summary = buildNarrativeSummary(output, targetList, totalOpps);

        return output;
    }

    /**
     * Compose a conversational summary that the Agentforce Agent can deliver verbatim.
     *
     * This is the text the user actually hears/sees. Write it to sound natural
     * when spoken by the Agent. Keep it concise — 2-3 sentences max.
     */
    private static String buildNarrativeSummary(
        ActionOutput output,
        List<Object> targetList,
        Integer totalOpps
    ) {
        String summary = 'Based on your current pipeline of '
            + output.opportunitiesAnalyzed + ' open opportunities';

        if (output.expectedRevenue != null) {
            summary += ', my forecast shows an expected revenue of '
                + formatCurrency(output.expectedRevenue);
        }

        if (output.p10Revenue != null && output.p90Revenue != null) {
            summary += ', with a realistic range of '
                + formatCurrency(output.p10Revenue)
                + ' to '
                + formatCurrency(output.p90Revenue)
                + ' (10th to 90th percentile).';
        } else {
            summary += '.';
        }

        // Add the most interesting target probability
        if (targetList != null && !targetList.isEmpty()) {
            // Find the target with probability closest to 50% — most interesting
            Map<String, Object> mostInteresting = findMostInterestingTarget(targetList);
            if (mostInteresting != null) {
                summary += ' You have a ' + mostInteresting.get('probability_pct')
                    + ' chance of hitting '
                    + formatCurrencyFromNumber((Decimal) toDecimal(mostInteresting.get('target')))
                    + '.';
            }
        }

        return summary;
    }

    /**
     * Find the revenue target with probability closest to 50% — this is usually
     * the most actionable insight to surface (not too certain, not too uncertain).
     */
    private static Map<String, Object> findMostInterestingTarget(List<Object> targets) {
        Map<String, Object> best = null;
        Double bestDistance = 1.0;

        for (Object t : targets) {
            Map<String, Object> target = (Map<String, Object>) t;
            Double prob = ((Decimal) toDecimal(target.get('probability'))).doubleValue();
            Double distance = Math.abs(prob - 0.5);
            if (distance < bestDistance) {
                bestDistance = distance;
                best = target;
            }
        }
        return best;
    }

    // ─── Utility Methods ──────────────────────────────────────────────────────

    private static Decimal toDecimal(Object value) {
        if (value == null) return null;
        if (value instanceof Decimal) return (Decimal) value;
        if (value instanceof Integer) return Decimal.valueOf((Integer) value);
        if (value instanceof Long) return Decimal.valueOf((Long) value);
        if (value instanceof Double) return Decimal.valueOf(String.valueOf(value));
        return Decimal.valueOf(String.valueOf(value));
    }

    private static String formatCurrency(Decimal amount) {
        if (amount == null) return '$0';
        return formatCurrencyFromNumber(amount);
    }

    private static String formatCurrencyFromNumber(Decimal amount) {
        if (amount >= 1000000) {
            return '$' + (amount / 1000000).setScale(1, RoundingMode.HALF_UP) + 'M';
        } else if (amount >= 1000) {
            return '$' + (amount / 1000).setScale(0, RoundingMode.HALF_UP) + 'K';
        } else {
            return '$' + amount.setScale(0, RoundingMode.HALF_UP);
        }
    }
}
