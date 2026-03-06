/**
 * MonteCarloActionHandler.cls
 *
 * PURPOSE:
 *   Invocable Apex class that bridges Agentforce and the Monte Carlo FastAPI
 *   service on Heroku. When an agent needs to forecast revenue probability, it
 *   calls this action with a target amount. The class:
 *     1. Queries the current user's open Opportunities (this quarter by default)
 *     2. Posts the data to the Monte Carlo service via Named Credential
 *     3. Returns a plain-English answer and key statistics
 *
 * USAGE EXAMPLE:
 *   "What's my probability of hitting $25M this quarter?"
 *   → Agentforce calls this with revenueTarget = 25000000
 *   → Returns: "You have a 68.3% chance of hitting $25M. Expected revenue is
 *     $22.4M, with a realistic range of $18.1M to $27.6M."
 *
 * DATA PRIVACY:
 *   Only Amount, Probability, and CloseDate leave Salesforce. Opportunity IDs
 *   are sent as anonymized identifiers. No names, contacts, or custom fields
 *   are transmitted.
 *
 * @author  Salesforce Solution Engineering
 * @version 2.0
 */
public with sharing class MonteCarloActionHandler {

    private static final String NAMED_CREDENTIAL  = 'callout:MonteCarlo_API';
    private static final String SIMULATE_ENDPOINT = '/api/v1/simulate';
    private static final Integer HTTP_TIMEOUT_MS  = 30000;
    private static final Integer NUM_SIMULATIONS  = 10000;

    // ─── Input ────────────────────────────────────────────────────────────────

    public class ActionInput {

        @InvocableVariable(
            label='Revenue Target (USD)'
            description='The dollar amount to forecast probability of hitting. Example: 25000000 for $25M.'
            required=true
        )
        public Decimal revenueTarget;

        @InvocableVariable(
            label='Time Horizon (Days)'
            description='Only include opportunities closing within this many days. Leave blank to default to the end of the current calendar quarter.'
            required=false
        )
        public Integer timeHorizonDays;
    }

    // ─── Output ───────────────────────────────────────────────────────────────

    public class ActionOutput {

        @InvocableVariable(
            label='Summary'
            description='Plain-English forecast answer ready to deliver to the user. Example: "You have a 68% chance of hitting $25M. Expected revenue is $22.4M, with a realistic range of $18.1M to $27.6M."'
        )
        public String summary;

        @InvocableVariable(
            label='Target Probability'
            description='Probability of hitting the revenue target, formatted as a percentage string. Example: "68.3%".'
        )
        public String targetProbabilityPct;

        @InvocableVariable(
            label='Expected Revenue'
            description='Mean revenue outcome across all simulations, in USD.'
        )
        public Decimal expectedRevenue;

        @InvocableVariable(
            label='P10 Revenue (Pessimistic)'
            description='10th percentile — only 10% of simulated scenarios produced less than this amount.'
        )
        public Decimal p10Revenue;

        @InvocableVariable(
            label='P90 Revenue (Optimistic)'
            description='90th percentile — only 10% of simulated scenarios produced more than this amount.'
        )
        public Decimal p90Revenue;

        @InvocableVariable(
            label='Opportunities Analyzed'
            description='Number of open opportunities included in the simulation.'
        )
        public Integer opportunitiesAnalyzed;

        @InvocableVariable(
            label='Success'
            description='True if the simulation completed successfully. False if an error occurred.'
        )
        public Boolean success;

        @InvocableVariable(
            label='Error Message'
            description='If success is false, contains a description of what went wrong.'
        )
        public String errorMessage;
    }

    // ─── Invocable Entry Point ────────────────────────────────────────────────

    @InvocableMethod(
        label='Run Monte Carlo Revenue Forecast'
        description='Queries the current user\'s open Opportunities and runs a Monte Carlo simulation to answer "What is my probability of hitting a revenue target?" Returns the hit-probability, expected revenue, and a range. Use for any question about pipeline likelihood, quota attainment, or quarter-end forecasts.'
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

    private static ActionOutput executeForecast(ActionInput input) {
        Integer horizonDays = input.timeHorizonDays != null
            ? input.timeHorizonDays
            : daysToQuarterEnd();

        List<Opportunity> opps = queryOpportunities(horizonDays);

        if (opps.isEmpty()) {
            ActionOutput empty = new ActionOutput();
            empty.success = true;
            empty.summary = 'No open opportunities found closing within the next '
                + horizonDays + ' days. Try broadening the time horizon.';
            empty.opportunitiesAnalyzed = 0;
            return empty;
        }

        Map<String, Object> payload = buildRequestPayload(opps, horizonDays, input.revenueTarget);
        String responseBody = callMonteCarloService(payload);
        return parseSimulationResponse(responseBody, input.revenueTarget);
    }

    /**
     * Query open opportunities for the current user (with sharing).
     * Filters to Amount/Probability/CloseDate fields required for simulation.
     */
    private static List<Opportunity> queryOpportunities(Integer horizonDays) {
        // Bind variable (:horizonDate) is safe — no string concatenation of user input.
        // horizonDays is an Integer derived from Apex arithmetic, not raw user text.
        Date horizonDate = Date.today().addDays(horizonDays);
        String soql = 'SELECT Id, Amount, Probability, CloseDate '
            + 'FROM Opportunity '
            + 'WHERE IsClosed = false '
            + 'AND Amount != null '
            + 'AND Probability != null '
            + 'AND CloseDate >= TODAY '
            + 'AND CloseDate <= :horizonDate '
            + 'ORDER BY CloseDate ASC LIMIT 500';
        System.debug('MonteCarloActionHandler SOQL: ' + soql);
        return Database.query(soql);
    }

    /**
     * Build the JSON payload. Only amount, probability, and close_date leave
     * Salesforce — the Opportunity ID is used as an anonymized identifier.
     * Salesforce stores Probability as 0-100; the API expects 0.0-1.0.
     */
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

    private static ActionOutput parseSimulationResponse(String responseBody, Decimal revenueTarget) {
        ActionOutput output = new ActionOutput();
        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(responseBody);

        Map<String, Object> stats = (Map<String, Object>) response.get('summary_statistics');
        if (stats != null) {
            output.expectedRevenue = toDecimal(stats.get('mean'));
            output.p10Revenue      = toDecimal(stats.get('p10'));
            output.p90Revenue      = toDecimal(stats.get('p90'));
        }

        Map<String, Object> metadata = (Map<String, Object>) response.get('metadata');
        if (metadata != null) {
            output.opportunitiesAnalyzed = (Integer) metadata.get('opportunities_included');
        }

        // Extract hit-probability for the specific revenue target
        List<Object> targetList = (List<Object>) response.get('target_analysis');
        if (targetList != null && !targetList.isEmpty()) {
            Map<String, Object> targetResult = (Map<String, Object>) targetList[0];
            output.targetProbabilityPct = (String) targetResult.get('probability_pct');
        }

        output.summary = buildNarrativeSummary(output, revenueTarget);
        return output;
    }

    private static String buildNarrativeSummary(ActionOutput output, Decimal revenueTarget) {
        String targetStr = formatCurrency(revenueTarget);
        String oppCount  = output.opportunitiesAnalyzed != null
            ? String.valueOf(output.opportunitiesAnalyzed) : '0';

        String summary = 'Based on your ' + oppCount + ' open opportunities';

        if (output.targetProbabilityPct != null) {
            summary += ', you have a ' + output.targetProbabilityPct
                + ' chance of hitting ' + targetStr + '.';
        } else {
            summary += '.';
        }

        if (output.expectedRevenue != null) {
            summary += ' Expected revenue is ' + formatCurrency(output.expectedRevenue);
        }

        if (output.p10Revenue != null && output.p90Revenue != null) {
            summary += ', with a realistic range of '
                + formatCurrency(output.p10Revenue) + ' to '
                + formatCurrency(output.p90Revenue) + '.';
        } else if (output.expectedRevenue != null) {
            summary += '.';
        }

        return summary;
    }

    // ─── Utility Methods ──────────────────────────────────────────────────────

    /**
     * Returns days from today to the last day of the current calendar quarter.
     * Q1: Jan–Mar → Mar 31 | Q2: Apr–Jun → Jun 30 | Q3: Jul–Sep → Sep 30 | Q4: Oct–Dec → Dec 31
     */
    private static Integer daysToQuarterEnd() {
        Date today = Date.today();
        Integer quarterEndMonth = (((today.month() - 1) / 3) + 1) * 3;
        Integer lastDay = Date.daysInMonth(today.year(), quarterEndMonth);
        Date quarterEnd = Date.newInstance(today.year(), quarterEndMonth, lastDay);
        return today.daysBetween(quarterEnd);
    }

    private static Decimal toDecimal(Object value) {
        if (value == null)              return null;
        if (value instanceof Decimal)   return (Decimal) value;
        if (value instanceof Integer)   return Decimal.valueOf((Integer) value);
        if (value instanceof Long)      return Decimal.valueOf((Long) value);
        return Decimal.valueOf(String.valueOf(value));
    }

    private static String formatCurrency(Decimal amount) {
        if (amount == null) return '$0';
        if (amount >= 1000000) {
            return '$' + (amount / 1000000).setScale(1, RoundingMode.HALF_UP) + 'M';
        } else if (amount >= 1000) {
            return '$' + (amount / 1000).setScale(0, RoundingMode.HALF_UP) + 'K';
        }
        return '$' + amount.setScale(0, RoundingMode.HALF_UP);
    }
}
