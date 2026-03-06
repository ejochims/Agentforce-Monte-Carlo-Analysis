/**
 * ForecastScenariosActionHandler.cls
 *
 * PURPOSE:
 *   Runs three Monte Carlo simulations against the current user's open pipeline
 *   to produce the standard sales forecasting tiers: Commit, Most Likely, and
 *   Best Case. Each tier uses a different probability threshold to filter deals
 *   before running the simulation.
 *
 *   COMMIT     — Only deals with Probability >= 80% (high-confidence)
 *   MOST LIKELY — Deals with Probability >= 50% (likely to close)
 *   BEST CASE  — All open deals regardless of probability
 *
 * USAGE EXAMPLE:
 *   "What is my commit vs. best case this quarter?"
 *   → Agentforce calls this with revenueTarget = 25000000
 *   → Returns three scenario comparisons in one narrative
 *
 * CALLOUT BEHAVIOR:
 *   Makes up to 3 sequential HTTP callouts (one per scenario tier).
 *   Scenarios with no qualifying deals skip the callout and return 0%.
 *
 * @author  Salesforce Solution Engineering
 * @version 1.0
 */
public with sharing class ForecastScenariosActionHandler {

    private static final String NAMED_CREDENTIAL  = 'callout:MonteCarlo_API';
    private static final String SIMULATE_ENDPOINT = '/api/v1/simulate';
    private static final Integer HTTP_TIMEOUT_MS  = 30000;
    private static final Integer NUM_SIMULATIONS  = 10000;

    private static final Integer COMMIT_THRESHOLD      = 80;
    private static final Integer MOST_LIKELY_THRESHOLD = 50;

    // ─── Input ────────────────────────────────────────────────────────────────

    public class ActionInput {

        @InvocableVariable(
            label='Revenue Target (USD)'
            description='The dollar amount to forecast probability of hitting across all three scenario tiers. Example: 25000000 for $25M. Required.'
            required=true
        )
        public Decimal revenueTarget;

        @InvocableVariable(
            label='Time Horizon (Days)'
            description='Only include opportunities closing within this many days. Leave blank to default to end of the current calendar quarter.'
            required=false
        )
        public Integer timeHorizonDays;
    }

    // ─── Output ───────────────────────────────────────────────────────────────

    public class ActionOutput {

        @InvocableVariable(
            label='Overall Summary'
            description='A combined plain-English narrative comparing all three scenarios. Read this directly to the user.'
        )
        public String overallSummary;

        @InvocableVariable(label='Success' description='True if scenarios ran successfully.')
        public Boolean success;

        @InvocableVariable(label='Error Message' description='Error description if success is false.')
        public String errorMessage;

        // Commit (Probability >= 80%)
        @InvocableVariable(
            label='Commit Probability'
            description='Probability of hitting the revenue target using only deals with >=80% probability (your committed pipeline).'
        )
        public String commitProbabilityPct;

        @InvocableVariable(label='Commit Expected Revenue' description='Mean revenue outcome in Commit scenario (deals >=80% probability), in USD.')
        public Decimal commitExpectedRevenue;

        @InvocableVariable(label='Commit P10 Revenue' description='Pessimistic outcome in Commit scenario — 10th percentile.')
        public Decimal commitP10Revenue;

        @InvocableVariable(label='Commit P90 Revenue' description='Optimistic outcome in Commit scenario — 90th percentile.')
        public Decimal commitP90Revenue;

        @InvocableVariable(label='Commit Opportunities Count' description='Number of deals qualifying for the Commit scenario (>=80% probability).')
        public Integer commitOppsCount;

        // Most Likely (Probability >= 50%)
        @InvocableVariable(
            label='Most Likely Probability'
            description='Probability of hitting the revenue target including all deals with >=50% probability.'
        )
        public String mostLikelyProbabilityPct;

        @InvocableVariable(label='Most Likely Expected Revenue' description='Mean revenue outcome in Most Likely scenario (deals >=50% probability), in USD.')
        public Decimal mostLikelyExpectedRevenue;

        @InvocableVariable(label='Most Likely P10 Revenue' description='Pessimistic outcome in Most Likely scenario — 10th percentile.')
        public Decimal mostLikelyP10Revenue;

        @InvocableVariable(label='Most Likely P90 Revenue' description='Optimistic outcome in Most Likely scenario — 90th percentile.')
        public Decimal mostLikelyP90Revenue;

        @InvocableVariable(label='Most Likely Opportunities Count' description='Number of deals qualifying for the Most Likely scenario (>=50% probability).')
        public Integer mostLikelyOppsCount;

        // Best Case (all open deals)
        @InvocableVariable(
            label='Best Case Probability'
            description='Probability of hitting the revenue target including ALL open deals regardless of probability.'
        )
        public String bestCaseProbabilityPct;

        @InvocableVariable(label='Best Case Expected Revenue' description='Mean revenue outcome in Best Case scenario (all open deals), in USD.')
        public Decimal bestCaseExpectedRevenue;

        @InvocableVariable(label='Best Case P10 Revenue' description='Pessimistic outcome in Best Case scenario — 10th percentile.')
        public Decimal bestCaseP10Revenue;

        @InvocableVariable(label='Best Case P90 Revenue' description='Optimistic outcome in Best Case scenario — 90th percentile.')
        public Decimal bestCaseP90Revenue;

        @InvocableVariable(label='Best Case Opportunities Count' description='Total number of open deals in the Best Case scenario.')
        public Integer bestCaseOppsCount;
    }

    // ─── Invocable Entry Point ────────────────────────────────────────────────

    @InvocableMethod(
        label='Run Forecast Scenarios (Commit / Most Likely / Best Case)'
        description='Runs three Monte Carlo simulations to produce the standard sales forecasting tiers: Commit (deals >=80% probability), Most Likely (deals >=50%), and Best Case (all open deals). Use this when the user asks about scenario planning, forecast tiers, "what is my commit?", "what is my best case?", or wants to compare pessimistic vs. optimistic revenue outcomes.'
        category='Revenue Forecasting'
        callout=true
    )
    public static List<ActionOutput> runScenarios(List<ActionInput> inputs) {
        List<ActionOutput> outputs = new List<ActionOutput>();

        for (ActionInput input : inputs) {
            ActionOutput output = new ActionOutput();
            try {
                output = executeScenarios(input);
                output.success = true;
            } catch (CalloutException e) {
                output.success = false;
                output.errorMessage = 'Callout to Monte Carlo service failed: ' + e.getMessage()
                    + '. Check Named Credential "MonteCarlo_API" configuration.';
                System.debug(LoggingLevel.ERROR, 'ForecastScenariosActionHandler callout error: ' + e.getMessage());
            } catch (JSONException e) {
                output.success = false;
                output.errorMessage = 'Failed to parse simulation response: ' + e.getMessage();
                System.debug(LoggingLevel.ERROR, 'ForecastScenariosActionHandler JSON error: ' + e.getMessage());
            } catch (Exception e) {
                output.success = false;
                output.errorMessage = 'Unexpected error: ' + e.getMessage();
                System.debug(LoggingLevel.ERROR, 'ForecastScenariosActionHandler unexpected error: ' + e.getMessage());
            }
            outputs.add(output);
        }

        return outputs;
    }

    // ─── Private Implementation ───────────────────────────────────────────────

    private static ActionOutput executeScenarios(ActionInput input) {
        Integer horizonDays = input.timeHorizonDays != null
            ? input.timeHorizonDays
            : daysToQuarterEnd();

        List<Opportunity> allOpps = queryOpportunities(horizonDays);

        if (allOpps.isEmpty()) {
            ActionOutput empty = new ActionOutput();
            empty.success = true;
            empty.overallSummary = 'No open opportunities found closing within the next '
                + horizonDays + ' days. Try broadening the time horizon.';
            empty.commitOppsCount = 0;
            empty.mostLikelyOppsCount = 0;
            empty.bestCaseOppsCount = 0;
            return empty;
        }

        List<Opportunity> commitOpps     = filterByMinProbability(allOpps, COMMIT_THRESHOLD);
        List<Opportunity> mostLikelyOpps = filterByMinProbability(allOpps, MOST_LIKELY_THRESHOLD);
        List<Opportunity> bestCaseOpps   = allOpps;

        ActionOutput output = new ActionOutput();
        output.commitOppsCount     = commitOpps.size();
        output.mostLikelyOppsCount = mostLikelyOpps.size();
        output.bestCaseOppsCount   = bestCaseOpps.size();

        // Best Case — always has deals (allOpps is non-empty here)
        Map<String, Object> bc = simulateScenario(bestCaseOpps, horizonDays, input.revenueTarget);
        output.bestCaseProbabilityPct  = (String) bc.get('probability_pct');
        output.bestCaseExpectedRevenue = toDecimal(bc.get('mean'));
        output.bestCaseP10Revenue      = toDecimal(bc.get('p10'));
        output.bestCaseP90Revenue      = toDecimal(bc.get('p90'));

        // Most Likely
        if (!mostLikelyOpps.isEmpty()) {
            Map<String, Object> ml = simulateScenario(mostLikelyOpps, horizonDays, input.revenueTarget);
            output.mostLikelyProbabilityPct  = (String) ml.get('probability_pct');
            output.mostLikelyExpectedRevenue = toDecimal(ml.get('mean'));
            output.mostLikelyP10Revenue      = toDecimal(ml.get('p10'));
            output.mostLikelyP90Revenue      = toDecimal(ml.get('p90'));
        } else {
            output.mostLikelyProbabilityPct  = '0.0%';
            output.mostLikelyExpectedRevenue = 0;
        }

        // Commit
        if (!commitOpps.isEmpty()) {
            Map<String, Object> cm = simulateScenario(commitOpps, horizonDays, input.revenueTarget);
            output.commitProbabilityPct  = (String) cm.get('probability_pct');
            output.commitExpectedRevenue = toDecimal(cm.get('mean'));
            output.commitP10Revenue      = toDecimal(cm.get('p10'));
            output.commitP90Revenue      = toDecimal(cm.get('p90'));
        } else {
            output.commitProbabilityPct  = '0.0%';
            output.commitExpectedRevenue = 0;
        }

        output.overallSummary = buildSummary(output, input.revenueTarget);
        return output;
    }

    private static List<Opportunity> filterByMinProbability(List<Opportunity> opps, Integer minPct) {
        List<Opportunity> filtered = new List<Opportunity>();
        for (Opportunity opp : opps) {
            if (opp.Probability >= minPct) {
                filtered.add(opp);
            }
        }
        return filtered;
    }

    private static Map<String, Object> simulateScenario(
        List<Opportunity> opps,
        Integer horizonDays,
        Decimal revenueTarget
    ) {
        String responseBody = callMonteCarloService(buildRequestPayload(opps, horizonDays, revenueTarget));
        return extractKeyStats(responseBody);
    }

    private static List<Opportunity> queryOpportunities(Integer horizonDays) {
        Date horizonDate = Date.today().addDays(horizonDays);
        String soql = 'SELECT Id, Amount, Probability, CloseDate '
            + 'FROM Opportunity '
            + 'WHERE IsClosed = false '
            + 'AND Amount != null '
            + 'AND Probability != null '
            + 'AND CloseDate >= TODAY '
            + 'AND CloseDate <= :horizonDate '
            + 'ORDER BY CloseDate ASC LIMIT 500';
        return Database.query(soql);
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

    private static String buildSummary(ActionOutput o, Decimal target) {
        String t = formatCurrency(target);

        String summary = 'Here are your three forecast scenarios for ' + t + ':\n\n';

        summary += 'COMMIT (' + o.commitOppsCount + ' deals ≥80% probability): ';
        if (o.commitOppsCount > 0) {
            summary += o.commitProbabilityPct + ' chance of hitting ' + t
                + '. Expected: ' + formatCurrency(o.commitExpectedRevenue) + '.';
        } else {
            summary += 'No high-confidence deals in pipeline.';
        }

        summary += '\n\nMOST LIKELY (' + o.mostLikelyOppsCount + ' deals ≥50% probability): ';
        if (o.mostLikelyOppsCount > 0) {
            summary += o.mostLikelyProbabilityPct + ' chance of hitting ' + t
                + '. Expected: ' + formatCurrency(o.mostLikelyExpectedRevenue) + '.';
        } else {
            summary += 'No deals above 50% probability.';
        }

        summary += '\n\nBEST CASE (' + o.bestCaseOppsCount + ' total open deals): ';
        summary += o.bestCaseProbabilityPct + ' chance of hitting ' + t
            + '. Expected: ' + formatCurrency(o.bestCaseExpectedRevenue)
            + ', ranging from ' + formatCurrency(o.bestCaseP10Revenue)
            + ' to ' + formatCurrency(o.bestCaseP90Revenue) + '.';

        return summary;
    }

    // ─── Utility Methods ──────────────────────────────────────────────────────

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
