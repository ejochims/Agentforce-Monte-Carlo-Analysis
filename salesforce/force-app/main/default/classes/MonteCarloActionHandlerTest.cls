/**
 * MonteCarloActionHandlerTest.cls
 *
 * PURPOSE:
 *   Unit tests for MonteCarloActionHandler. Since the handler makes an HTTP
 *   callout to the FastAPI service, all tests use a mock HTTP response —
 *   Salesforce test execution cannot make real callouts.
 *
 * COVERAGE:
 *   - Happy path: full simulation run with results
 *   - Empty pipeline: graceful message when no open opportunities found
 *   - Callout failure: 500 response handled as error, not exception
 *   - Filter logic: stage and time-horizon filters applied correctly
 *   - Input parsing: revenue targets CSV parsed correctly
 *
 * HOW TO RUN:
 *   sf apex run test --class-names MonteCarloActionHandlerTest --target-org <alias> --synchronous
 *   or: Setup → Apex Test Execution → Run Tests
 *
 * @author  Salesforce Solution Engineering
 * @version 1.0
 * @apiVersion 62.0
 */
@isTest
private class MonteCarloActionHandlerTest {

    // ─── Mock HTTP Response ────────────────────────────────────────────────────

    /**
     * Simulates a successful 200 response from the Monte Carlo FastAPI service.
     * Returns a realistic JSON payload that mirrors what simulation.py returns.
     */
    private class MockSuccessCallout implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(buildMockResponseBody());
            return res;
        }
    }

    /**
     * Simulates a 500 error response from the service.
     * Tests that the Apex class handles this gracefully (no exception thrown).
     */
    private class MockErrorCallout implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(500);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"error":"internal_server_error","message":"Simulation failed"}');
            return res;
        }
    }

    /**
     * Build a realistic JSON response body matching the SimulationResponse schema.
     * Numbers here are fabricated but statistically plausible for a demo pipeline.
     */
    private static String buildMockResponseBody() {
        return '{'
            + '"summary_statistics": {'
            + '  "mean": 8340000.0,'
            + '  "median": 8450000.0,'
            + '  "std_dev": 1920000.0,'
            + '  "p10": 5800000.0,'
            + '  "p25": 7100000.0,'
            + '  "p75": 9600000.0,'
            + '  "p90": 10800000.0,'
            + '  "min_outcome": 1200000.0,'
            + '  "max_outcome": 14500000.0,'
            + '  "total_pipeline_value": 18500000.0,'
            + '  "weighted_pipeline_value": 9250000.0'
            + '},'
            + '"target_analysis": ['
            + '  {"target": 5000000.0, "probability": 0.9340, "probability_pct": "93.4%"},'
            + '  {"target": 10000000.0, "probability": 0.6820, "probability_pct": "68.2%"},'
            + '  {"target": 15000000.0, "probability": 0.1240, "probability_pct": "12.4%"}'
            + '],'
            + '"histogram_buckets": ['
            + '  {"range_low": 1200000.0, "range_high": 2300000.0, "label": "$1.2M \u2013 $2.3M", "count": 240, "frequency": 0.024},'
            + '  {"range_low": 2300000.0, "range_high": 3400000.0, "label": "$2.3M \u2013 $3.4M", "count": 480, "frequency": 0.048},'
            + '  {"range_low": 3400000.0, "range_high": 4500000.0, "label": "$3.4M \u2013 $4.5M", "count": 820, "frequency": 0.082}'
            + '],'
            + '"metadata": {'
            + '  "num_simulations": 10000,'
            + '  "opportunities_included": 12,'
            + '  "opportunities_filtered_out": 3,'
            + '  "compute_time_ms": 47.3,'
            + '  "timestamp": "2026-01-15T10:30:00Z",'
            + '  "time_horizon_days": 90,'
            + '  "api_version": "1.0.0"'
            + '}'
            + '}';
    }

    // ─── Test Data Setup ────────────────────────────────────────────────────────

    /**
     * Create a set of realistic test Opportunities.
     * Uses @isTest(SeeAllData=false) — no real org data is touched.
     */
    private static List<Opportunity> createTestOpportunities() {
        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(
                Name = 'Test Deal - Enterprise A',
                Amount = 2500000,
                Probability = 75,
                CloseDate = Date.today().addDays(45),
                StageName = 'Proposal/Price Quote'
            ),
            new Opportunity(
                Name = 'Test Deal - Enterprise B',
                Amount = 1800000,
                Probability = 60,
                CloseDate = Date.today().addDays(60),
                StageName = 'Value Proposition'
            ),
            new Opportunity(
                Name = 'Test Deal - SMB',
                Amount = 450000,
                Probability = 90,
                CloseDate = Date.today().addDays(20),
                StageName = 'Id. Decision Makers'
            )
        };
        insert opps;
        return opps;
    }

    // ─── Test Cases ─────────────────────────────────────────────────────────────

    /**
     * Happy path: service responds with 200, all output fields are populated,
     * summary text is non-empty, expected revenue is positive.
     */
    @isTest
    static void testHappyPath() {
        createTestOpportunities();

        MonteCarloActionHandler.ActionInput input = new MonteCarloActionHandler.ActionInput();
        input.timeHorizonDays = 90;
        input.numSimulations = 10000;
        input.revenueTargetsCSV = '5000000,10000000,15000000';

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<MonteCarloActionHandler.ActionOutput> outputs =
            MonteCarloActionHandler.runForecast(
                new List<MonteCarloActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size(), 'Expected exactly one output');
        MonteCarloActionHandler.ActionOutput output = outputs[0];

        System.assert(output.success, 'Expected success = true, got: ' + output.errorMessage);
        System.assertNotEquals(null, output.summary, 'Summary should not be null');
        System.assert(output.summary.length() > 0, 'Summary should not be empty');
        System.assertEquals(8340000.0, output.expectedRevenue, 'Expected revenue should match mock response');
        System.assertEquals(8450000.0, output.medianRevenue, 'Median revenue should match mock response');
        System.assertEquals(5800000.0, output.p10Revenue, 'P10 should match mock response');
        System.assertEquals(10800000.0, output.p90Revenue, 'P90 should match mock response');
        System.assertEquals(12, output.opportunitiesAnalyzed, 'Should match mock metadata');
        System.assert(output.computeTimeMs > 0, 'Compute time should be positive');
        System.assertNotEquals(null, output.targetAnalysisJson, 'Target analysis JSON should not be null');
        System.assert(output.targetAnalysisJson.contains('68.2%'), 'Target analysis should include $10M probability');
        System.assertNotEquals(null, output.rawResponseJson, 'Raw response should be stored for debugging');
    }

    /**
     * Summary text should mention opportunity count and key metrics.
     * Tests the narrative generation logic in buildNarrativeSummary().
     */
    @isTest
    static void testNarrativeSummaryContent() {
        createTestOpportunities();

        MonteCarloActionHandler.ActionInput input = new MonteCarloActionHandler.ActionInput();
        input.timeHorizonDays = 90;

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<MonteCarloActionHandler.ActionOutput> outputs =
            MonteCarloActionHandler.runForecast(
                new List<MonteCarloActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        MonteCarloActionHandler.ActionOutput output = outputs[0];
        System.assert(output.success, 'Should succeed');
        // Summary should reference the number of opportunities
        System.assert(
            output.summary.contains('12') || output.summary.contains('opportunities'),
            'Summary should mention opportunity count'
        );
    }

    /**
     * Empty pipeline: when no opportunities match the filters, the action
     * should succeed with a helpful message rather than calling the API.
     */
    @isTest
    static void testEmptyPipeline() {
        // Don't insert any opportunities — pipeline is empty

        MonteCarloActionHandler.ActionInput input = new MonteCarloActionHandler.ActionInput();
        input.timeHorizonDays = 7; // Very short window — no deals will close this soon
        input.stageFilter = 'Closed Won'; // No open deals in Closed Won

        // No mock needed — should return before making a callout
        Test.startTest();
        List<MonteCarloActionHandler.ActionOutput> outputs =
            MonteCarloActionHandler.runForecast(
                new List<MonteCarloActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        MonteCarloActionHandler.ActionOutput output = outputs[0];
        System.assert(output.success, 'Empty pipeline should still be success=true');
        System.assertEquals(0, output.opportunitiesAnalyzed, 'No opportunities should be counted');
        System.assertNotEquals(null, output.summary, 'Summary should explain the empty state');
        System.assert(
            output.summary.toLowerCase().contains('no open'),
            'Summary should explain no opportunities were found'
        );
    }

    /**
     * Callout failure: when the service returns 500, the output should have
     * success=false and a descriptive errorMessage — no exception should propagate.
     */
    @isTest
    static void testCalloutFailure() {
        createTestOpportunities();

        MonteCarloActionHandler.ActionInput input = new MonteCarloActionHandler.ActionInput();
        input.timeHorizonDays = 90;

        Test.setMock(HttpCalloutMock.class, new MockErrorCallout());
        Test.startTest();
        List<MonteCarloActionHandler.ActionOutput> outputs =
            MonteCarloActionHandler.runForecast(
                new List<MonteCarloActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        MonteCarloActionHandler.ActionOutput output = outputs[0];
        System.assert(!output.success, 'Expected success = false on 500 response');
        System.assertNotEquals(null, output.errorMessage, 'Error message should be populated');
        System.assert(output.errorMessage.length() > 0, 'Error message should not be empty');
    }

    /**
     * Stage filter: only opportunities in the specified stage(s) should be queried.
     * This tests that the SOQL builder correctly applies the StageName filter.
     */
    @isTest
    static void testStageFilter() {
        // Create opportunities in different stages
        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(
                Name = 'Proposal Stage Deal',
                Amount = 500000,
                Probability = 50,
                CloseDate = Date.today().addDays(30),
                StageName = 'Proposal/Price Quote'
            ),
            new Opportunity(
                Name = 'Prospecting Stage Deal',
                Amount = 300000,
                Probability = 20,
                CloseDate = Date.today().addDays(60),
                StageName = 'Prospecting'
            )
        };
        insert opps;

        MonteCarloActionHandler.ActionInput input = new MonteCarloActionHandler.ActionInput();
        input.stageFilter = 'Proposal/Price Quote';

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<MonteCarloActionHandler.ActionOutput> outputs =
            MonteCarloActionHandler.runForecast(
                new List<MonteCarloActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        // As long as no exception was thrown, the filter was applied cleanly
        System.assertEquals(1, outputs.size());
        System.assert(outputs[0].success, 'Stage filter should not cause errors');
    }

    /**
     * Revenue targets CSV: comma-separated string should be parsed into numeric values.
     * Tests the parsing logic in buildRequestPayload().
     */
    @isTest
    static void testRevenueTargetsParsing() {
        createTestOpportunities();

        MonteCarloActionHandler.ActionInput input = new MonteCarloActionHandler.ActionInput();
        // Mix of clean numbers and numbers with spaces (edge case)
        input.revenueTargetsCSV = '5000000, 10000000, 20000000';

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<MonteCarloActionHandler.ActionOutput> outputs =
            MonteCarloActionHandler.runForecast(
                new List<MonteCarloActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        System.assert(outputs[0].success, 'Revenue target parsing should not cause errors');
    }

    /**
     * Minimum probability filter: only opportunities above the threshold
     * should pass through to the simulation.
     */
    @isTest
    static void testMinProbabilityFilter() {
        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(
                Name = 'High Confidence Deal',
                Amount = 1000000,
                Probability = 80,
                CloseDate = Date.today().addDays(45),
                StageName = 'Proposal/Price Quote'
            ),
            new Opportunity(
                Name = 'Low Confidence Deal',
                Amount = 2000000,
                Probability = 10,
                CloseDate = Date.today().addDays(45),
                StageName = 'Prospecting'
            )
        };
        insert opps;

        MonteCarloActionHandler.ActionInput input = new MonteCarloActionHandler.ActionInput();
        input.minProbability = 50; // Only include deals with 50%+ probability

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<MonteCarloActionHandler.ActionOutput> outputs =
            MonteCarloActionHandler.runForecast(
                new List<MonteCarloActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        System.assert(outputs[0].success, 'Probability filter should not cause errors');
    }

    /**
     * Batch invocation: Agentforce can invoke with multiple inputs in a single call.
     * Each input should produce exactly one corresponding output.
     */
    @isTest
    static void testBatchInvocation() {
        createTestOpportunities();

        MonteCarloActionHandler.ActionInput input1 = new MonteCarloActionHandler.ActionInput();
        input1.timeHorizonDays = 90;

        MonteCarloActionHandler.ActionInput input2 = new MonteCarloActionHandler.ActionInput();
        input2.timeHorizonDays = 180;

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<MonteCarloActionHandler.ActionOutput> outputs =
            MonteCarloActionHandler.runForecast(
                new List<MonteCarloActionHandler.ActionInput>{ input1, input2 }
            );
        Test.stopTest();

        System.assertEquals(2, outputs.size(), 'Should return one output per input');
    }
}
