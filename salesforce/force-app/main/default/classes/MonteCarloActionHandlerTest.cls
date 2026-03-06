/**
 * MonteCarloActionHandlerTest.cls
 *
 * Unit tests for MonteCarloActionHandler. Since the handler makes an HTTP
 * callout to the FastAPI service, all tests use a mock HTTP response —
 * Salesforce test execution cannot make real callouts.
 *
 * HOW TO RUN:
 *   sf apex run test --class-names MonteCarloActionHandlerTest --target-org <alias> --synchronous
 *
 * @author  Salesforce Solution Engineering
 * @version 2.0
 */
@isTest
private class MonteCarloActionHandlerTest {

    // ─── Mock HTTP Responses ─────────────────────────────────────────────────

    private class MockSuccessCallout implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(buildMockResponseBody());
            return res;
        }
    }

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
     * Realistic JSON response body matching the SimulationResponse schema.
     * The target_analysis array has one entry (for the single revenueTarget passed in).
     */
    private static String buildMockResponseBody() {
        return '{'
            + '"summary_statistics": {'
            + '  "mean": 22400000.0,'
            + '  "median": 22800000.0,'
            + '  "std_dev": 3100000.0,'
            + '  "p10": 18100000.0,'
            + '  "p25": 20500000.0,'
            + '  "p75": 24300000.0,'
            + '  "p90": 27600000.0,'
            + '  "min_outcome": 9000000.0,'
            + '  "max_outcome": 35000000.0,'
            + '  "total_pipeline_value": 45000000.0,'
            + '  "weighted_pipeline_value": 24750000.0'
            + '},'
            + '"target_analysis": ['
            + '  {"target": 25000000.0, "probability": 0.6830, "probability_pct": "68.3%"}'
            + '],'
            + '"histogram_buckets": ['
            + '  {"range_low": 9000000.0, "range_high": 14000000.0, "label": "$9M \u2013 $14M", "count": 210, "frequency": 0.021}'
            + '],'
            + '"metadata": {'
            + '  "num_simulations": 10000,'
            + '  "opportunities_included": 18,'
            + '  "opportunities_filtered_out": 0,'
            + '  "compute_time_ms": 52.1,'
            + '  "timestamp": "2026-03-06T10:30:00Z",'
            + '  "time_horizon_days": 25,'
            + '  "api_version": "1.0.0"'
            + '}'
            + '}';
    }

    // ─── Test Data ────────────────────────────────────────────────────────────

    private static List<Opportunity> createTestOpportunities() {
        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(
                Name = 'Test Deal A',
                Amount = 5000000,
                Probability = 75,
                CloseDate = Date.today().addDays(45),
                StageName = 'Proposal/Price Quote'
            ),
            new Opportunity(
                Name = 'Test Deal B',
                Amount = 8000000,
                Probability = 60,
                CloseDate = Date.today().addDays(60),
                StageName = 'Value Proposition'
            ),
            new Opportunity(
                Name = 'Test Deal C',
                Amount = 3500000,
                Probability = 85,
                CloseDate = Date.today().addDays(20),
                StageName = 'Id. Decision Makers'
            )
        };
        insert opps;
        return opps;
    }

    // ─── Test Cases ───────────────────────────────────────────────────────────

    /**
     * Happy path: service responds with 200 and a $25M target.
     * All output fields should be populated.
     */
    @isTest
    static void testHappyPath() {
        createTestOpportunities();

        MonteCarloActionHandler.ActionInput input = new MonteCarloActionHandler.ActionInput();
        input.revenueTarget = 25000000;
        input.timeHorizonDays = 90;

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
        System.assertEquals(22400000.0, output.expectedRevenue, 'Expected revenue should match mock');
        System.assertEquals(18100000.0, output.p10Revenue, 'P10 should match mock');
        System.assertEquals(27600000.0, output.p90Revenue, 'P90 should match mock');
        System.assertEquals(18, output.opportunitiesAnalyzed, 'Should match mock metadata');
        System.assertEquals('68.3%', output.targetProbabilityPct, 'Target probability should match mock');
    }

    /**
     * Summary should mention the target probability and opportunity count.
     */
    @isTest
    static void testNarrativeSummaryContent() {
        createTestOpportunities();

        MonteCarloActionHandler.ActionInput input = new MonteCarloActionHandler.ActionInput();
        input.revenueTarget = 25000000;
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
        System.assert(
            output.summary.contains('68.3%'),
            'Summary should include the target hit probability'
        );
        System.assert(
            output.summary.contains('$25M') || output.summary.contains('25'),
            'Summary should reference the revenue target'
        );
    }

    /**
     * Empty pipeline: no opportunities in time window → success with helpful message,
     * no HTTP callout made.
     */
    @isTest
    static void testEmptyPipeline() {
        // No opportunities inserted — pipeline is empty

        MonteCarloActionHandler.ActionInput input = new MonteCarloActionHandler.ActionInput();
        input.revenueTarget = 25000000;
        input.timeHorizonDays = 1; // 1-day window — no deals close this fast

        Test.startTest();
        List<MonteCarloActionHandler.ActionOutput> outputs =
            MonteCarloActionHandler.runForecast(
                new List<MonteCarloActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        MonteCarloActionHandler.ActionOutput output = outputs[0];
        System.assert(output.success, 'Empty pipeline should still be success = true');
        System.assertEquals(0, output.opportunitiesAnalyzed);
        System.assertNotEquals(null, output.summary);
        System.assert(
            output.summary.toLowerCase().contains('no open'),
            'Summary should explain no opportunities were found'
        );
    }

    /**
     * Callout failure: 500 from the service → success=false with errorMessage.
     * No exception should propagate to the caller.
     */
    @isTest
    static void testCalloutFailure() {
        createTestOpportunities();

        MonteCarloActionHandler.ActionInput input = new MonteCarloActionHandler.ActionInput();
        input.revenueTarget = 25000000;
        input.timeHorizonDays = 90;

        Test.setMock(HttpCalloutMock.class, new MockErrorCallout());
        Test.startTest();
        List<MonteCarloActionHandler.ActionOutput> outputs =
            MonteCarloActionHandler.runForecast(
                new List<MonteCarloActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        MonteCarloActionHandler.ActionOutput output = outputs[0];
        System.assert(!output.success, 'Expected success = false on 500 response');
        System.assertNotEquals(null, output.errorMessage);
        System.assert(output.errorMessage.length() > 0);
    }

    /**
     * Quarter-end auto-calculation: when timeHorizonDays is null, the Apex class
     * should calculate days to end of current quarter and still find opportunities.
     */
    @isTest
    static void testDefaultQuarterEnd() {
        createTestOpportunities(); // Close in 20-60 days — within any quarter end

        MonteCarloActionHandler.ActionInput input = new MonteCarloActionHandler.ActionInput();
        input.revenueTarget = 25000000;
        // timeHorizonDays intentionally omitted → defaults to quarter end

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<MonteCarloActionHandler.ActionOutput> outputs =
            MonteCarloActionHandler.runForecast(
                new List<MonteCarloActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        // Should succeed without a timeHorizonDays value
        System.assert(
            outputs[0].success || outputs[0].opportunitiesAnalyzed == 0,
            'Should handle missing timeHorizonDays gracefully'
        );
    }

    /**
     * Batch invocation: Agentforce can call with multiple inputs simultaneously.
     * Each input must produce exactly one corresponding output.
     */
    @isTest
    static void testBatchInvocation() {
        createTestOpportunities();

        MonteCarloActionHandler.ActionInput input1 = new MonteCarloActionHandler.ActionInput();
        input1.revenueTarget = 25000000;
        input1.timeHorizonDays = 90;

        MonteCarloActionHandler.ActionInput input2 = new MonteCarloActionHandler.ActionInput();
        input2.revenueTarget = 10000000;
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
