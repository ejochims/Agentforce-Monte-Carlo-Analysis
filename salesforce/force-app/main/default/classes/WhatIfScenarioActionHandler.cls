/**
 * WhatIfScenarioActionHandler.cls
 *
 * PURPOSE:
 *   Runs a "what-if" scenario analysis by finding a specific deal in the
 *   current user's pipeline, applying a hypothetical change to it in memory
 *   (new probability, pushed close date), and comparing the revenue forecast
 *   before and after the change.
 *
 * USAGE EXAMPLES:
 *   "What if I close Acme Corp this week?" → lower timeHorizonDays
 *   "What if TechCo slips 30 days?"       → newCloseDateDays = 30
 *   "What if the Acme deal drops to 40%?" → newProbabilityPct = 40
 *
 * HOW IT WORKS:
 *   1. Queries all open opportunities for the current user
 *   2. Finds the best name/account match for dealSearchTerm
 *   3. Runs a baseline Monte Carlo simulation (unmodified pipeline)
 *   4. Modifies the matched deal in memory (no DML — Salesforce data unchanged)
 *   5. Runs a scenario Monte Carlo simulation with the modified pipeline
 *   6. Returns a before/after comparison narrative
 *
 * @author  Salesforce Solution Engineering
 * @version 1.0
 */
public with sharing class WhatIfScenarioActionHandler {

    private static final String NAMED_CREDENTIAL  = 'callout:MonteCarlo_API';
    private static final String SIMULATE_ENDPOINT = '/api/v1/simulate';
    private static final Integer HTTP_TIMEOUT_MS  = 30000;
    private static final Integer NUM_SIMULATIONS  = 10000;

    // ─── Input ────────────────────────────────────────────────────────────────

    public class ActionInput {

        @InvocableVariable(
            label='Deal Search Term'
            description='The name of the opportunity or account to model. Example: "Acme Corp" or "Enterprise Platform Deal". A partial name match will find the closest deal. Required.'
            required=true
        )
        public String dealSearchTerm;

        @InvocableVariable(
            label='Revenue Target (USD)'
            description='The dollar amount to calculate probability of hitting in both the baseline and scenario. Example: 25000000 for $25M. Required.'
            required=true
        )
        public Decimal revenueTarget;

        @InvocableVariable(
            label='New Probability (0-100)'
            description='Override the matched deal probability with this value (0 to 100). Example: 40 means the deal drops to 40% likelihood. Leave blank to keep the existing probability.'
            required=false
        )
        public Decimal newProbabilityPct;

        @InvocableVariable(
            label='Close Date Slip (Days)'
            description='Push the matched deal close date forward by this many days. Example: 30 means the deal slips one month. Leave blank to keep the existing close date.'
            required=false
        )
        public Integer closeDateSlipDays;

        @InvocableVariable(
            label='Time Horizon (Days)'
            description='Only include opportunities closing within this many days in both simulations. Leave blank to default to end of the current calendar quarter.'
            required=false
        )
        public Integer timeHorizonDays;
    }

    // ─── Output ───────────────────────────────────────────────────────────────

    public class ActionOutput {

        @InvocableVariable(
            label='Overall Summary'
            description='Plain-English comparison of the baseline vs. what-if scenario. Read this directly to the user.'
        )
        public String overallSummary;

        @InvocableVariable(
            label='Deal Found'
            description='The full name of the opportunity that was matched and modified in the scenario.'
        )
        public String dealFound;

        @InvocableVariable(
            label='Baseline Probability'
            description='Probability of hitting the revenue target with the current unmodified pipeline.'
        )
        public String baselineProbabilityPct;

        @InvocableVariable(
            label='Baseline Expected Revenue'
            description='Mean revenue outcome with the current unmodified pipeline, in USD.'
        )
        public Decimal baselineExpectedRevenue;

        @InvocableVariable(
            label='Scenario Probability'
            description='Probability of hitting the revenue target after applying the what-if modification to the deal.'
        )
        public String scenarioProbabilityPct;

        @InvocableVariable(
            label='Scenario Expected Revenue'
            description='Mean revenue outcome after applying the what-if modification, in USD.'
        )
        public Decimal scenarioExpectedRevenue;

        @InvocableVariable(
            label='Probability Change'
            description='The net change in hit-probability between baseline and scenario. Positive means the scenario improves the forecast. Example: "+12.4%" or "-8.1%".'
        )
        public String probabilityChange;

        @InvocableVariable(label='Success' description='True if the scenario analysis completed successfully.')
        public Boolean success;

        @InvocableVariable(label='Error Message' description='Error description if success is false.')
        public String errorMessage;
    }

    // ─── Invocable Entry Point ────────────────────────────────────────────────

    @InvocableMethod(
        label='Run What-If Scenario Analysis'
        description='Simulates the impact of changing a single deal on overall revenue probability. Use when the user asks "What if I close [deal name] this week?", "What if [deal] slips 30 days?", or "What happens to my number if [deal] drops to 40%?" Requires the deal name (dealSearchTerm) and the revenue target.'
        category='Revenue Forecasting'
        callout=true
    )
    public static List<ActionOutput> runWhatIf(List<ActionInput> inputs) {
        List<ActionOutput> outputs = new List<ActionOutput>();

        for (ActionInput input : inputs) {
            ActionOutput output = new ActionOutput();
            try {
                output = executeWhatIf(input);
                output.success = true;
            } catch (CalloutException e) {
                output.success = false;
                output.errorMessage = 'Callout to Monte Carlo service failed: ' + e.getMessage()
                    + '. Check Named Credential "MonteCarlo_API" configuration.';
                System.debug(LoggingLevel.ERROR, 'WhatIfScenarioActionHandler callout error: ' + e.getMessage());
            } catch (JSONException e) {
                output.success = false;
                output.errorMessage = 'Failed to parse simulation response: ' + e.getMessage();
                System.debug(LoggingLevel.ERROR, 'WhatIfScenarioActionHandler JSON error: ' + e.getMessage());
            } catch (Exception e) {
                output.success = false;
                output.errorMessage = 'Unexpected error: ' + e.getMessage();
                System.debug(LoggingLevel.ERROR, 'WhatIfScenarioActionHandler unexpected error: ' + e.getMessage());
            }
            outputs.add(output);
        }

        return outputs;
    }

    // ─── Private Implementation ───────────────────────────────────────────────

    private static ActionOutput executeWhatIf(ActionInput input) {
        Integer horizonDays = input.timeHorizonDays != null
            ? input.timeHorizonDays
            : daysToQuarterEnd();

        // Query a wider window so named deals outside the horizon can still be found
        Integer searchWindow = Math.max(horizonDays, 180);
        List<Opportunity> allOpps = queryOpportunities(searchWindow);

        if (allOpps.isEmpty()) {
            ActionOutput empty = new ActionOutput();
            empty.success = true;
            empty.overallSummary = 'No open opportunities found in your pipeline.';
            return empty;
        }

        Opportunity matchedDeal = findBestMatch(allOpps, input.dealSearchTerm);

        if (matchedDeal == null) {
            ActionOutput notFound = new ActionOutput();
            notFound.success = true;
            notFound.overallSummary = 'Could not find an open opportunity matching "'
                + input.dealSearchTerm + '". Try a different name or partial account name.';
            return notFound;
        }

        ActionOutput output = new ActionOutput();
        output.dealFound = matchedDeal.Name;

        // Baseline: current pipeline, unmodified
        Map<String, Object> baseline = runSimulation(allOpps, horizonDays, input.revenueTarget);
        output.baselineProbabilityPct  = (String) baseline.get('probability_pct');
        output.baselineExpectedRevenue = toDecimal(baseline.get('mean'));

        // Scenario: same pipeline with the matched deal modified in memory
        List<Opportunity> scenarioOpps = applyModification(allOpps, matchedDeal.Id, input);
        Map<String, Object> scenario = runSimulation(scenarioOpps, horizonDays, input.revenueTarget);
        output.scenarioProbabilityPct  = (String) scenario.get('probability_pct');
        output.scenarioExpectedRevenue = toDecimal(scenario.get('mean'));

        // Calculate net change in probability
        Decimal basePct = parsePct(output.baselineProbabilityPct);
        Decimal scenPct = parsePct(output.scenarioProbabilityPct);
        Decimal delta   = scenPct - basePct;
        output.probabilityChange = (delta >= 0 ? '+' : '')
            + delta.setScale(1, RoundingMode.HALF_UP) + '%';

        output.overallSummary = buildSummary(output, input, matchedDeal);
        return output;
    }

    private static List<Opportunity> queryOpportunities(Integer horizonDays) {
        Date horizonDate = Date.today().addDays(horizonDays);
        String soql = 'SELECT Id, Name, Amount, Probability, CloseDate, Account.Name '
            + 'FROM Opportunity '
            + 'WHERE IsClosed = false '
            + 'AND Amount != null '
            + 'AND Probability != null '
            + 'AND CloseDate >= TODAY '
            + 'AND CloseDate <= :horizonDate '
            + 'ORDER BY CloseDate ASC LIMIT 500';
        return Database.query(soql);
    }

    /**
     * Find the deal whose Name or Account Name contains the search term (case-insensitive).
     * Returns the first match — typically the closest closing deal will appear first
     * due to ORDER BY CloseDate ASC in the query.
     */
    private static Opportunity findBestMatch(List<Opportunity> opps, String searchTerm) {
        String lower = searchTerm.toLowerCase();
        for (Opportunity opp : opps) {
            Boolean nameMatch = opp.Name != null && opp.Name.toLowerCase().contains(lower);
            Boolean acctMatch = opp.Account != null
                && opp.Account.Name != null
                && opp.Account.Name.toLowerCase().contains(lower);
            if (nameMatch || acctMatch) {
                return opp;
            }
        }
        return null;
    }

    /**
     * Return a copy of the opportunity list with the matched deal's fields changed
     * in memory only. No DML — Salesforce data is never written to.
     */
    private static List<Opportunity> applyModification(
        List<Opportunity> opps,
        Id matchedId,
        ActionInput input
    ) {
        List<Opportunity> result = new List<Opportunity>();
        for (Opportunity opp : opps) {
            if (opp.Id == matchedId) {
                Opportunity modified = opp.clone(true, true, false, false);
                if (input.newProbabilityPct != null) {
                    modified.Probability = input.newProbabilityPct;
                }
                if (input.closeDateSlipDays != null) {
                    modified.CloseDate = opp.CloseDate.addDays(input.closeDateSlipDays);
                }
                result.add(modified);
            } else {
                result.add(opp);
            }
        }
        return result;
    }

    private static Map<String, Object> runSimulation(
        List<Opportunity> opps,
        Integer horizonDays,
        Decimal revenueTarget
    ) {
        String responseBody = callMonteCarloService(buildRequestPayload(opps, horizonDays, revenueTarget));
        return extractKeyStats(responseBody);
    }

    private static Map<String, Object> buildRequestPayload(
        List<Opportunity> opps,
        Integer horizonDays,
        Decimal revenueTarget
    ) {
        List<Map<String, Object>> oppList = new List<Map<String, Object>>();
        for (Opportunity opp : opps) {
            oppList.add(new Map<String, Object>{
                'name'        => opp.Id,
                'amount'      => opp.Amount,
                'probability' => opp.Probability / 100.0,
                'close_date'  => String.valueOf(opp.CloseDate)
            });
        }
        return new Map<String, Object>{
            'opportunities'     => oppList,
            'num_simulations'   => NUM_SIMULATIONS,
            'time_horizon_days' => horizonDays,
            'revenue_targets'   => new List<Decimal>{ revenueTarget }
        };
    }

    private static String callMonteCarloService(Map<String, Object> payload) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + SIMULATE_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(HTTP_TIMEOUT_MS);
        req.setBody(JSON.serialize(payload));

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new CalloutException(
                'Monte Carlo API returned status ' + res.getStatusCode()
                + ': ' + res.getBody()
            );
        }

        return res.getBody();
    }

    private static Map<String, Object> extractKeyStats(String responseBody) {
        Map<String, Object> result   = new Map<String, Object>();
        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(responseBody);

        Map<String, Object> stats = (Map<String, Object>) response.get('summary_statistics');
        if (stats != null) {
            result.put('mean', stats.get('mean'));
            result.put('p10',  stats.get('p10'));
            result.put('p90',  stats.get('p90'));
        }

        List<Object> targetList = (List<Object>) response.get('target_analysis');
        if (targetList != null && !targetList.isEmpty()) {
            Map<String, Object> t = (Map<String, Object>) targetList[0];
            result.put('probability_pct', t.get('probability_pct'));
        }

        return result;
    }

    private static String buildSummary(ActionOutput o, ActionInput input, Opportunity deal) {
        String targetStr = formatCurrency(input.revenueTarget);

        String summary = 'What-if analysis for "' + deal.Name + '":\n\n';
        summary += 'BASELINE (current pipeline): '
            + o.baselineProbabilityPct + ' chance of hitting ' + targetStr
            + '. Expected revenue: ' + formatCurrency(o.baselineExpectedRevenue) + '.\n\n';

        String changeDesc = describeModification(input);
        summary += 'SCENARIO (' + changeDesc + '): '
            + o.scenarioProbabilityPct + ' chance of hitting ' + targetStr
            + '. Expected revenue: ' + formatCurrency(o.scenarioExpectedRevenue) + '.\n\n';

        summary += 'Net impact: ' + o.probabilityChange
            + ' change in probability of hitting ' + targetStr + '.';

        return summary;
    }

    private static String describeModification(ActionInput input) {
        List<String> parts = new List<String>();
        if (input.newProbabilityPct != null) {
            parts.add('probability changed to ' + input.newProbabilityPct.setScale(0) + '%');
        }
        if (input.closeDateSlipDays != null) {
            parts.add('close date pushed ' + input.closeDateSlipDays + ' days');
        }
        return parts.isEmpty() ? 'no modification' : String.join(parts, ', ');
    }

    // ─── Utility Methods ──────────────────────────────────────────────────────

    private static Decimal parsePct(String pct) {
        if (pct == null) return 0;
        try {
            return Decimal.valueOf(pct.replace('%', '').trim());
        } catch (Exception e) {
            return 0;
        }
    }

    private static Integer daysToQuarterEnd() {
        Date today = Date.today();
        Integer quarterEndMonth = (((today.month() - 1) / 3) + 1) * 3;
        Integer lastDay = Date.daysInMonth(today.year(), quarterEndMonth);
        Date quarterEnd = Date.newInstance(today.year(), quarterEndMonth, lastDay);
        return today.daysBetween(quarterEnd);
    }

    private static Decimal toDecimal(Object value) {
        if (value == null)            return 0;
        if (value instanceof Decimal) return (Decimal) value;
        if (value instanceof Integer) return Decimal.valueOf((Integer) value);
        if (value instanceof Long)    return Decimal.valueOf((Long) value);
        return Decimal.valueOf(String.valueOf(value));
    }

    private static String formatCurrency(Decimal amount) {
        if (amount == null) return '$0';
        if (amount >= 1000000) return '$' + (amount / 1000000).setScale(1, RoundingMode.HALF_UP) + 'M';
        if (amount >= 1000)    return '$' + (amount / 1000).setScale(0, RoundingMode.HALF_UP) + 'K';
        return '$' + amount.setScale(0, RoundingMode.HALF_UP);
    }
}
