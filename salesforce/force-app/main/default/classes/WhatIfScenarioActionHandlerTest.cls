/**
 * WhatIfScenarioActionHandlerTest.cls
 *
 * Unit tests for WhatIfScenarioActionHandler. The handler makes 2 HTTP
 * callouts per execution (baseline + scenario), so all tests use a mock
 * that returns the same realistic response for each callout.
 *
 * HOW TO RUN:
 *   sf apex run test --class-names WhatIfScenarioActionHandlerTest --target-org <alias> --synchronous
 *
 * @author  Salesforce Solution Engineering
 * @version 1.0
 */
@isTest
private class WhatIfScenarioActionHandlerTest {

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
            + '"histogram_buckets": [],'
            + '"metadata": {'
            + '  "num_simulations": 10000,'
            + '  "opportunities_included": 5,'
            + '  "opportunities_filtered_out": 0,'
            + '  "compute_time_ms": 51.2,'
            + '  "timestamp": "2026-03-06T10:30:00Z",'
            + '  "time_horizon_days": 90,'
            + '  "api_version": "1.0.0"'
            + '}'
            + '}';
    }

    // ─── Test Data ────────────────────────────────────────────────────────────

    private static List<Opportunity> createTestOpportunities() {
        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(
                Name = 'Acme Corp Enterprise Deal',
                Amount = 8000000,
                Probability = 70,
                CloseDate = Date.today().addDays(45),
                StageName = 'Proposal/Price Quote'
            ),
            new Opportunity(
                Name = 'TechCo Platform License',
                Amount = 5000000,
                Probability = 55,
                CloseDate = Date.today().addDays(60),
                StageName = 'Value Proposition'
            ),
            new Opportunity(
                Name = 'GlobalBank Analytics Suite',
                Amount = 12000000,
                Probability = 40,
                CloseDate = Date.today().addDays(75),
                StageName = 'Needs Analysis'
            )
        };
        insert opps;
        return opps;
    }

    // ─── Test Cases ───────────────────────────────────────────────────────────

    /**
     * Happy path: finds deal by name, runs baseline + scenario, returns comparison.
     */
    @isTest
    static void testHappyPathProbabilityChange() {
        createTestOpportunities();

        WhatIfScenarioActionHandler.ActionInput input = new WhatIfScenarioActionHandler.ActionInput();
        input.dealSearchTerm   = 'Acme';
        input.revenueTarget    = 25000000;
        input.newProbabilityPct = 95;
        input.timeHorizonDays  = 90;

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<WhatIfScenarioActionHandler.ActionOutput> outputs =
            WhatIfScenarioActionHandler.runWhatIf(
                new List<WhatIfScenarioActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        WhatIfScenarioActionHandler.ActionOutput o = outputs[0];

        System.assert(o.success, 'Expected success = true, got: ' + o.errorMessage);
        System.assertNotEquals(null, o.dealFound,         'Should identify the matched deal');
        System.assert(o.dealFound.contains('Acme'),       'Deal found should be the Acme deal');
        System.assertNotEquals(null, o.overallSummary);
        System.assert(o.overallSummary.length() > 0);
        System.assertNotEquals(null, o.baselineProbabilityPct);
        System.assertNotEquals(null, o.scenarioProbabilityPct);
        System.assertNotEquals(null, o.probabilityChange);

        // Verify stats from mock
        System.assertEquals(22400000.0, o.baselineExpectedRevenue);
        System.assertEquals(22400000.0, o.scenarioExpectedRevenue); // same mock for both calls
        System.assertEquals('68.3%', o.baselineProbabilityPct);
    }

    /**
     * Close date slip: modifying close date days should still run successfully.
     */
    @isTest
    static void testCloseDateSlip() {
        createTestOpportunities();

        WhatIfScenarioActionHandler.ActionInput input = new WhatIfScenarioActionHandler.ActionInput();
        input.dealSearchTerm     = 'TechCo';
        input.revenueTarget      = 25000000;
        input.closeDateSlipDays  = 30;
        input.timeHorizonDays    = 90;

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<WhatIfScenarioActionHandler.ActionOutput> outputs =
            WhatIfScenarioActionHandler.runWhatIf(
                new List<WhatIfScenarioActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        WhatIfScenarioActionHandler.ActionOutput o = outputs[0];
        System.assert(o.success);
        System.assert(o.dealFound.contains('TechCo'), 'Should match TechCo deal');
        System.assert(o.overallSummary.contains('30 days'), 'Summary should describe the slip');
    }

    /**
     * Combined change: both probability and close date modified simultaneously.
     */
    @isTest
    static void testCombinedModification() {
        createTestOpportunities();

        WhatIfScenarioActionHandler.ActionInput input = new WhatIfScenarioActionHandler.ActionInput();
        input.dealSearchTerm    = 'GlobalBank';
        input.revenueTarget     = 25000000;
        input.newProbabilityPct = 80;
        input.closeDateSlipDays = 15;
        input.timeHorizonDays   = 90;

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<WhatIfScenarioActionHandler.ActionOutput> outputs =
            WhatIfScenarioActionHandler.runWhatIf(
                new List<WhatIfScenarioActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        WhatIfScenarioActionHandler.ActionOutput o = outputs[0];
        System.assert(o.success);
        System.assert(o.dealFound.contains('GlobalBank'));
        System.assert(o.overallSummary.contains('80%'));
        System.assert(o.overallSummary.contains('15 days'));
    }

    /**
     * Deal not found: search term doesn't match any opportunity.
     */
    @isTest
    static void testDealNotFound() {
        createTestOpportunities();

        WhatIfScenarioActionHandler.ActionInput input = new WhatIfScenarioActionHandler.ActionInput();
        input.dealSearchTerm    = 'Nonexistent Company XYZ';
        input.revenueTarget     = 25000000;
        input.newProbabilityPct = 90;
        input.timeHorizonDays   = 90;

        Test.startTest();
        List<WhatIfScenarioActionHandler.ActionOutput> outputs =
            WhatIfScenarioActionHandler.runWhatIf(
                new List<WhatIfScenarioActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        WhatIfScenarioActionHandler.ActionOutput o = outputs[0];
        System.assert(o.success, 'Not found should still return success = true with a message');
        System.assert(o.overallSummary.toLowerCase().contains('could not find'));
    }

    /**
     * Empty pipeline: no open opportunities at all.
     */
    @isTest
    static void testEmptyPipeline() {
        WhatIfScenarioActionHandler.ActionInput input = new WhatIfScenarioActionHandler.ActionInput();
        input.dealSearchTerm    = 'Acme';
        input.revenueTarget     = 25000000;
        input.newProbabilityPct = 90;
        input.timeHorizonDays   = 1;

        Test.startTest();
        List<WhatIfScenarioActionHandler.ActionOutput> outputs =
            WhatIfScenarioActionHandler.runWhatIf(
                new List<WhatIfScenarioActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        WhatIfScenarioActionHandler.ActionOutput o = outputs[0];
        System.assert(o.success, 'Empty pipeline should still succeed');
        System.assertNotEquals(null, o.overallSummary);
    }

    /**
     * Callout failure: 500 from service → success=false with errorMessage.
     */
    @isTest
    static void testCalloutFailure() {
        createTestOpportunities();

        WhatIfScenarioActionHandler.ActionInput input = new WhatIfScenarioActionHandler.ActionInput();
        input.dealSearchTerm    = 'Acme';
        input.revenueTarget     = 25000000;
        input.newProbabilityPct = 90;
        input.timeHorizonDays   = 90;

        Test.setMock(HttpCalloutMock.class, new MockErrorCallout());
        Test.startTest();
        List<WhatIfScenarioActionHandler.ActionOutput> outputs =
            WhatIfScenarioActionHandler.runWhatIf(
                new List<WhatIfScenarioActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        WhatIfScenarioActionHandler.ActionOutput o = outputs[0];
        System.assert(!o.success, 'Should fail on 500 response');
        System.assertNotEquals(null, o.errorMessage);
    }

    /**
     * Summary mentions BASELINE and SCENARIO labels and the net probability change.
     */
    @isTest
    static void testSummaryStructure() {
        createTestOpportunities();

        WhatIfScenarioActionHandler.ActionInput input = new WhatIfScenarioActionHandler.ActionInput();
        input.dealSearchTerm    = 'Acme';
        input.revenueTarget     = 25000000;
        input.newProbabilityPct = 95;
        input.timeHorizonDays   = 90;

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<WhatIfScenarioActionHandler.ActionOutput> outputs =
            WhatIfScenarioActionHandler.runWhatIf(
                new List<WhatIfScenarioActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        String summary = outputs[0].overallSummary;
        System.assert(summary.contains('BASELINE'),  'Summary should contain BASELINE section');
        System.assert(summary.contains('SCENARIO'),  'Summary should contain SCENARIO section');
        System.assert(summary.contains('Net impact'), 'Summary should contain net impact line');
        System.assert(summary.contains('$25M'),      'Summary should reference the target');
    }
}
