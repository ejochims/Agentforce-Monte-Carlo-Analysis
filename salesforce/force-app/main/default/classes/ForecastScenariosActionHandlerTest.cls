/**
 * ForecastScenariosActionHandlerTest.cls
 *
 * Unit tests for ForecastScenariosActionHandler. The handler makes up to 3
 * HTTP callouts (one per scenario tier), so all tests use a mock that returns
 * the same realistic response for each callout.
 *
 * HOW TO RUN:
 *   sf apex run test --class-names ForecastScenariosActionHandlerTest --target-org <alias> --synchronous
 *
 * @author  Salesforce Solution Engineering
 * @version 1.0
 */
@isTest
private class ForecastScenariosActionHandlerTest {

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
            + '  "mean": 18500000.0,'
            + '  "median": 18200000.0,'
            + '  "std_dev": 2800000.0,'
            + '  "p10": 14200000.0,'
            + '  "p25": 16100000.0,'
            + '  "p75": 20900000.0,'
            + '  "p90": 23100000.0,'
            + '  "min_outcome": 8000000.0,'
            + '  "max_outcome": 30000000.0,'
            + '  "total_pipeline_value": 38000000.0,'
            + '  "weighted_pipeline_value": 21500000.0'
            + '},'
            + '"target_analysis": ['
            + '  {"target": 25000000.0, "probability": 0.5420, "probability_pct": "54.2%"}'
            + '],'
            + '"histogram_buckets": [],'
            + '"metadata": {'
            + '  "num_simulations": 10000,'
            + '  "opportunities_included": 12,'
            + '  "opportunities_filtered_out": 0,'
            + '  "compute_time_ms": 48.3,'
            + '  "timestamp": "2026-03-06T10:30:00Z",'
            + '  "time_horizon_days": 90,'
            + '  "api_version": "1.0.0"'
            + '}'
            + '}';
    }

    // ─── Test Data ────────────────────────────────────────────────────────────

    /**
     * Creates a mix of deals across all three probability tiers:
     *  - 2 deals >= 80% (Commit)
     *  - 2 deals >= 50% but < 80% (Most Likely only)
     *  - 1 deal < 50% (Best Case only)
     */
    private static void createTestOpportunities() {
        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(
                Name = 'High Confidence Deal A',
                Amount = 8000000,
                Probability = 90,
                CloseDate = Date.today().addDays(20),
                StageName = 'Id. Decision Makers'
            ),
            new Opportunity(
                Name = 'High Confidence Deal B',
                Amount = 5000000,
                Probability = 85,
                CloseDate = Date.today().addDays(30),
                StageName = 'Id. Decision Makers'
            ),
            new Opportunity(
                Name = 'Likely Deal C',
                Amount = 6000000,
                Probability = 65,
                CloseDate = Date.today().addDays(45),
                StageName = 'Proposal/Price Quote'
            ),
            new Opportunity(
                Name = 'Likely Deal D',
                Amount = 4000000,
                Probability = 55,
                CloseDate = Date.today().addDays(60),
                StageName = 'Value Proposition'
            ),
            new Opportunity(
                Name = 'Long Shot Deal E',
                Amount = 12000000,
                Probability = 30,
                CloseDate = Date.today().addDays(75),
                StageName = 'Needs Analysis'
            )
        };
        insert opps;
    }

    // ─── Test Cases ───────────────────────────────────────────────────────────

    /**
     * Happy path: three tiers all have deals. All output fields populated.
     */
    @isTest
    static void testHappyPath() {
        createTestOpportunities();

        ForecastScenariosActionHandler.ActionInput input = new ForecastScenariosActionHandler.ActionInput();
        input.revenueTarget   = 25000000;
        input.timeHorizonDays = 90;

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<ForecastScenariosActionHandler.ActionOutput> outputs =
            ForecastScenariosActionHandler.runScenarios(
                new List<ForecastScenariosActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        ForecastScenariosActionHandler.ActionOutput o = outputs[0];

        System.assert(o.success, 'Expected success = true, got: ' + o.errorMessage);
        System.assertNotEquals(null, o.overallSummary, 'Summary should not be null');
        System.assert(o.overallSummary.length() > 0);

        // All three tiers should have deal counts
        System.assert(o.commitOppsCount > 0,     'Should have commit-tier deals');
        System.assert(o.mostLikelyOppsCount > 0, 'Should have most-likely-tier deals');
        System.assert(o.bestCaseOppsCount > 0,   'Should have best-case deals');

        // Best case should have the most deals (superset)
        System.assert(o.bestCaseOppsCount >= o.mostLikelyOppsCount);
        System.assert(o.mostLikelyOppsCount >= o.commitOppsCount);

        // Verify key fields populated from mock
        System.assertEquals('54.2%', o.bestCaseProbabilityPct);
        System.assertEquals(18500000.0, o.bestCaseExpectedRevenue);
        System.assertEquals(14200000.0, o.bestCaseP10Revenue);
        System.assertEquals(23100000.0, o.bestCaseP90Revenue);
    }

    /**
     * Summary should contain all three tier labels.
     */
    @isTest
    static void testSummaryContainsAllTiers() {
        createTestOpportunities();

        ForecastScenariosActionHandler.ActionInput input = new ForecastScenariosActionHandler.ActionInput();
        input.revenueTarget   = 25000000;
        input.timeHorizonDays = 90;

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<ForecastScenariosActionHandler.ActionOutput> outputs =
            ForecastScenariosActionHandler.runScenarios(
                new List<ForecastScenariosActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        String summary = outputs[0].overallSummary;
        System.assert(summary.contains('COMMIT'),      'Summary should mention COMMIT tier');
        System.assert(summary.contains('MOST LIKELY'), 'Summary should mention MOST LIKELY tier');
        System.assert(summary.contains('BEST CASE'),   'Summary should mention BEST CASE tier');
        System.assert(summary.contains('$25M'),        'Summary should reference the target');
    }

    /**
     * Tier filtering: Commit should only count deals >= 80%.
     */
    @isTest
    static void testTierFiltering() {
        createTestOpportunities(); // 2 deals >= 80%, 4 deals >= 50%, 5 total

        ForecastScenariosActionHandler.ActionInput input = new ForecastScenariosActionHandler.ActionInput();
        input.revenueTarget   = 25000000;
        input.timeHorizonDays = 90;

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<ForecastScenariosActionHandler.ActionOutput> outputs =
            ForecastScenariosActionHandler.runScenarios(
                new List<ForecastScenariosActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        ForecastScenariosActionHandler.ActionOutput o = outputs[0];
        System.assert(o.success);
        System.assertEquals(2, o.commitOppsCount,     'Commit: only 2 deals >=80%');
        System.assertEquals(4, o.mostLikelyOppsCount, 'Most Likely: 4 deals >=50%');
        System.assertEquals(5, o.bestCaseOppsCount,   'Best Case: all 5 deals');
    }

    /**
     * Empty pipeline: no opportunities → success with helpful message, no callout.
     */
    @isTest
    static void testEmptyPipeline() {
        ForecastScenariosActionHandler.ActionInput input = new ForecastScenariosActionHandler.ActionInput();
        input.revenueTarget   = 25000000;
        input.timeHorizonDays = 1;

        Test.startTest();
        List<ForecastScenariosActionHandler.ActionOutput> outputs =
            ForecastScenariosActionHandler.runScenarios(
                new List<ForecastScenariosActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        ForecastScenariosActionHandler.ActionOutput o = outputs[0];
        System.assert(o.success, 'Empty pipeline should still succeed');
        System.assertEquals(0, o.commitOppsCount);
        System.assertEquals(0, o.mostLikelyOppsCount);
        System.assertEquals(0, o.bestCaseOppsCount);
        System.assert(o.overallSummary.toLowerCase().contains('no open'));
    }

    /**
     * Callout failure on first scenario → success=false with errorMessage.
     */
    @isTest
    static void testCalloutFailure() {
        createTestOpportunities();

        ForecastScenariosActionHandler.ActionInput input = new ForecastScenariosActionHandler.ActionInput();
        input.revenueTarget   = 25000000;
        input.timeHorizonDays = 90;

        Test.setMock(HttpCalloutMock.class, new MockErrorCallout());
        Test.startTest();
        List<ForecastScenariosActionHandler.ActionOutput> outputs =
            ForecastScenariosActionHandler.runScenarios(
                new List<ForecastScenariosActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        ForecastScenariosActionHandler.ActionOutput o = outputs[0];
        System.assert(!o.success, 'Should fail on 500 response');
        System.assertNotEquals(null, o.errorMessage);
        System.assert(o.errorMessage.length() > 0);
    }

    /**
     * Quarter-end auto-calculation: timeHorizonDays null → defaults to quarter end.
     */
    @isTest
    static void testDefaultQuarterEnd() {
        createTestOpportunities();

        ForecastScenariosActionHandler.ActionInput input = new ForecastScenariosActionHandler.ActionInput();
        input.revenueTarget = 25000000;
        // timeHorizonDays intentionally omitted

        Test.setMock(HttpCalloutMock.class, new MockSuccessCallout());
        Test.startTest();
        List<ForecastScenariosActionHandler.ActionOutput> outputs =
            ForecastScenariosActionHandler.runScenarios(
                new List<ForecastScenariosActionHandler.ActionInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        System.assert(
            outputs[0].success || outputs[0].bestCaseOppsCount == 0,
            'Should handle missing timeHorizonDays gracefully'
        );
    }
}
