/**
 * PipelineSummaryAction.cls
 *
 * PURPOSE:
 *   Invocable Apex class that queries open Opportunities and returns a
 *   structured pipeline summary for the Agentforce Agent to deliver
 *   conversationally. Answers questions like:
 *     "What does my pipeline look like this quarter?"
 *     "How many deals do I have in each stage?"
 *     "What are my top 5 deals?"
 *
 * OUTPUT:
 *   Returns a natural language summary plus structured fields the agent
 *   can use to give detailed, accurate pipeline breakdowns.
 *
 * DATA PRIVACY:
 *   Opportunity names and account names stay within Salesforce — nothing
 *   is sent to an external service. All processing happens in Apex.
 *
 * @author  Salesforce Solution Engineering
 * @version 1.0
 * @apiVersion 62.0
 */
public with sharing class PipelineSummaryAction {

    public class ActionInput {

        @InvocableVariable(
            label='Time Horizon (Days)'
            description='Only include opportunities closing within this many days. Use 90 for this quarter, 180 for this half-year. Leave blank for all open pipeline.'
            required=false
        )
        public Integer timeHorizonDays;

        @InvocableVariable(
            label='Owner ID Filter'
            description='Salesforce User ID to filter by opportunity owner. Leave blank to include all reps.'
            required=false
        )
        public String ownerIdFilter;

        @InvocableVariable(
            label='Account ID Filter'
            description='Salesforce Account ID to limit the summary to a single account. Leave blank for all accounts.'
            required=false
        )
        public String accountIdFilter;

        @InvocableVariable(
            label='Maximum Deals to List'
            description='Maximum number of top deals to list by value. Default is 5.'
            required=false
        )
        public Integer maxTopDeals;
    }

    public class ActionOutput {

        @InvocableVariable(
            label='Summary'
            description='Natural language summary of the current pipeline state, ready to deliver to the user.'
        )
        public String summary;

        @InvocableVariable(
            label='Total Pipeline Value'
            description='Sum of all open opportunity amounts in USD.'
        )
        public Decimal totalPipelineValue;

        @InvocableVariable(
            label='Weighted Pipeline Value'
            description='Sum of (Amount x Probability) for all open opportunities — a more realistic revenue estimate.'
        )
        public Decimal weightedPipelineValue;

        @InvocableVariable(
            label='Total Deal Count'
            description='Total number of open opportunities included in the summary.'
        )
        public Integer totalDealCount;

        @InvocableVariable(
            label='Stage Breakdown JSON'
            description='JSON array of stage breakdowns: [{stage, count, totalValue, weightedValue}]'
        )
        public String stageBreakdownJson;

        @InvocableVariable(
            label='Top Deals JSON'
            description='JSON array of top deals by amount: [{name, amount, probability, stage, closeDate, accountName}]'
        )
        public String topDealsJson;

        @InvocableVariable(
            label='Success'
            description='True if the summary was generated successfully.'
        )
        public Boolean success;

        @InvocableVariable(
            label='Error Message'
            description='If success is false, contains the error description.'
        )
        public String errorMessage;
    }

    @InvocableMethod(
        label='Get Pipeline Summary'
        description='Queries open Opportunities and returns a pipeline summary broken down by stage, weighted value, and top deals. Use when the user asks for a pipeline overview, deal counts, stage breakdowns, or wants to see their top deals.'
        category='Pipeline Management'
    )
    public static List<ActionOutput> getSummary(List<ActionInput> inputs) {
        List<ActionOutput> outputs = new List<ActionOutput>();
        for (ActionInput input : inputs) {
            ActionOutput output = new ActionOutput();
            try {
                output = buildSummary(input);
                output.success = true;
            } catch (Exception e) {
                output.success = false;
                output.errorMessage = 'Error generating pipeline summary: ' + e.getMessage();
                System.debug(LoggingLevel.ERROR, 'PipelineSummaryAction error: ' + e.getMessage());
            }
            outputs.add(output);
        }
        return outputs;
    }

    private static ActionOutput buildSummary(ActionInput input) {
        Integer maxDeals = (input.maxTopDeals != null && input.maxTopDeals > 0) ? input.maxTopDeals : 5;

        // Build and execute the query
        List<Opportunity> opps = queryOpportunities(input);

        ActionOutput output = new ActionOutput();
        output.totalDealCount = opps.size();

        if (opps.isEmpty()) {
            output.summary = 'No open opportunities found matching the specified criteria. '
                + 'Try broadening the filters — for example, remove the time horizon or stage filter.';
            output.totalPipelineValue = 0;
            output.weightedPipelineValue = 0;
            output.stageBreakdownJson = '[]';
            output.topDealsJson = '[]';
            return output;
        }

        // Aggregate totals and stage breakdown
        Decimal totalValue = 0;
        Decimal weightedValue = 0;
        Map<String, StageAggregate> stageMap = new Map<String, StageAggregate>();

        for (Opportunity opp : opps) {
            Decimal amt = opp.Amount != null ? opp.Amount : 0;
            Decimal prob = opp.Probability != null ? opp.Probability / 100.0 : 0;

            totalValue += amt;
            weightedValue += amt * prob;

            if (!stageMap.containsKey(opp.StageName)) {
                stageMap.put(opp.StageName, new StageAggregate(opp.StageName));
            }
            stageMap.get(opp.StageName).addDeal(amt, prob);
        }

        output.totalPipelineValue = totalValue.setScale(2, RoundingMode.HALF_UP);
        output.weightedPipelineValue = weightedValue.setScale(2, RoundingMode.HALF_UP);

        // Build stage breakdown JSON
        List<Map<String, Object>> stageList = new List<Map<String, Object>>();
        for (StageAggregate sa : stageMap.values()) {
            stageList.add(sa.toMap());
        }
        output.stageBreakdownJson = JSON.serialize(stageList);

        // Build top deals JSON (top N by amount, already sorted DESC from query)
        List<Map<String, Object>> topDeals = new List<Map<String, Object>>();
        Integer count = 0;
        for (Opportunity opp : opps) {
            if (count >= maxDeals) break;
            topDeals.add(new Map<String, Object>{
                'name'        => opp.Name,
                'amount'      => opp.Amount,
                'probability' => opp.Probability,
                'stage'       => opp.StageName,
                'closeDate'   => String.valueOf(opp.CloseDate),
                'accountName' => opp.Account != null ? opp.Account.Name : null
            });
            count++;
        }
        output.topDealsJson = JSON.serialize(topDeals);

        // Build natural language summary
        output.summary = buildNarrativeSummary(output, stageMap, maxDeals, topDeals, input);

        return output;
    }

    private static List<Opportunity> queryOpportunities(ActionInput input) {
        List<String> whereClauses = new List<String>{
            'IsClosed = false',
            'Amount != null'
        };

        if (input.timeHorizonDays != null && input.timeHorizonDays > 0) {
            Date horizon = Date.today().addDays(input.timeHorizonDays);
            whereClauses.add('CloseDate <= ' + horizon.format());
            whereClauses.add('CloseDate >= TODAY');
        }

        if (String.isNotBlank(input.ownerIdFilter)) {
            whereClauses.add('OwnerId = \'' + String.escapeSingleQuotes(input.ownerIdFilter.trim()) + '\'');
        }

        if (String.isNotBlank(input.accountIdFilter)) {
            whereClauses.add('AccountId = \'' + String.escapeSingleQuotes(input.accountIdFilter.trim()) + '\'');
        }

        return Database.query(
            'SELECT Id, Name, Amount, Probability, StageName, CloseDate, Account.Name '
            + 'FROM Opportunity '
            + 'WHERE ' + String.join(whereClauses, ' AND ')
            + ' ORDER BY Amount DESC NULLS LAST '
            + 'LIMIT 500'
        );
    }

    private static String buildNarrativeSummary(
        ActionOutput output,
        Map<String, StageAggregate> stageMap,
        Integer maxDeals,
        List<Map<String, Object>> topDeals,
        ActionInput input
    ) {
        String horizon = input.timeHorizonDays != null
            ? 'closing in the next ' + input.timeHorizonDays + ' days'
            : 'currently open';

        String summary = 'You have ' + output.totalDealCount + ' opportunities ' + horizon
            + ', with a total pipeline of ' + formatCurrency(output.totalPipelineValue)
            + ' and a weighted pipeline of ' + formatCurrency(output.weightedPipelineValue) + '.\n';

        // Stage breakdown
        if (!stageMap.isEmpty()) {
            summary += '\nBy stage:';
            for (StageAggregate sa : stageMap.values()) {
                summary += '\n  ' + sa.stageName + ': ' + sa.dealCount + ' deal'
                    + (sa.dealCount != 1 ? 's' : '') + ' (' + formatCurrency(sa.totalValue) + ')';
            }
        }

        // Top deals
        if (!topDeals.isEmpty()) {
            summary += '\n\nTop ' + topDeals.size() + ' deal' + (topDeals.size() != 1 ? 's' : '') + ':';
            for (Map<String, Object> deal : topDeals) {
                summary += '\n  ' + deal.get('name')
                    + ' — ' + formatCurrency((Decimal) deal.get('amount'))
                    + ' (' + deal.get('stage') + ', closes ' + deal.get('closeDate') + ')';
            }
        }

        return summary;
    }

    // ── Inner helper class for stage aggregation ──────────────────────────────

    private class StageAggregate {
        public String stageName;
        public Integer dealCount = 0;
        public Decimal totalValue = 0;
        public Decimal weightedValue = 0;

        public StageAggregate(String stageName) {
            this.stageName = stageName;
        }

        public void addDeal(Decimal amount, Decimal probability) {
            dealCount++;
            totalValue += amount;
            weightedValue += amount * probability;
        }

        public Map<String, Object> toMap() {
            return new Map<String, Object>{
                'stage'         => stageName,
                'count'         => dealCount,
                'totalValue'    => totalValue.setScale(2, RoundingMode.HALF_UP),
                'weightedValue' => weightedValue.setScale(2, RoundingMode.HALF_UP)
            };
        }
    }

    // ── Utility ───────────────────────────────────────────────────────────────

    private static String formatCurrency(Decimal amount) {
        if (amount == null) return '$0';
        if (amount >= 1000000) return '$' + (amount / 1000000).setScale(1, RoundingMode.HALF_UP) + 'M';
        if (amount >= 1000) return '$' + (amount / 1000).setScale(0, RoundingMode.HALF_UP) + 'K';
        return '$' + amount.setScale(0, RoundingMode.HALF_UP);
    }
}
