# =============================================================================
# test_simulation.py — Unit tests for the Monte Carlo simulation engine
#
# These tests verify that:
#   1. The simulation math produces statistically correct results
#   2. Edge cases (no deals, 100% probability, 0% probability) work correctly
#   3. The time horizon filter works
#   4. The API endpoint validates inputs correctly
#
# RUN TESTS:
#   cd api && pip install pytest httpx && pytest ../tests/ -v
#
# WHY TEST MONTE CARLO?
#   With random simulations, we can't assert exact values, but we CAN assert
#   statistical properties that should hold over many runs:
#   - A deal with 100% probability should always be won
#   - A deal with 0% probability should never be won
#   - The mean should converge to the expected value (sum of amount × probability)
# =============================================================================

import sys
import os
import pytest
from datetime import date, timedelta

# Add the api/ directory to the Python path so we can import our modules
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "api"))

import numpy as np
from models import Opportunity, SimulationRequest
from simulation import (
    filter_opportunities_by_horizon,
    run_monte_carlo,
    compute_summary_statistics,
    compute_target_analysis,
    compute_histogram,
    run_full_simulation,
)


# ─── Test Fixtures ─────────────────────────────────────────────────────────────

@pytest.fixture
def sample_opportunities():
    """A realistic set of opportunities for testing."""
    today = date.today()
    return [
        Opportunity(name="Deal A", amount=1_000_000, probability=0.9, close_date=today + timedelta(days=30)),
        Opportunity(name="Deal B", amount=500_000,   probability=0.5, close_date=today + timedelta(days=60)),
        Opportunity(name="Deal C", amount=2_000_000, probability=0.25, close_date=today + timedelta(days=90)),
        Opportunity(name="Deal D", amount=750_000,   probability=0.75, close_date=today + timedelta(days=120)),
    ]


@pytest.fixture
def certain_opportunity():
    """A deal guaranteed to close (100% probability)."""
    return [Opportunity(name="Certain", amount=1_000_000, probability=1.0, close_date=date.today() + timedelta(days=30))]


@pytest.fixture
def impossible_opportunity():
    """A deal guaranteed to NOT close (0% probability)."""
    return [Opportunity(name="Impossible", amount=1_000_000, probability=0.0, close_date=date.today() + timedelta(days=30))]


# ─── Test: Monte Carlo Core Math ──────────────────────────────────────────────

class TestMonteCarloMath:

    def test_certain_deal_always_won(self, certain_opportunity):
        """A 100% probability deal should always be won in every simulation."""
        outcomes = run_monte_carlo(certain_opportunity, num_simulations=1000)
        assert np.all(outcomes == 1_000_000), "100% probability deal should win every simulation"

    def test_impossible_deal_never_won(self, impossible_opportunity):
        """A 0% probability deal should never be won in any simulation."""
        outcomes = run_monte_carlo(impossible_opportunity, num_simulations=1000)
        assert np.all(outcomes == 0), "0% probability deal should never win"

    def test_mean_converges_to_expected_value(self, sample_opportunities):
        """
        The mean of many simulations should converge to the sum of (amount × probability).
        This is the law of large numbers — our most important correctness check.
        """
        expected_value = sum(o.amount * o.probability for o in sample_opportunities)
        # 1M * 0.9 + 500K * 0.5 + 2M * 0.25 + 750K * 0.75 = 900K + 250K + 500K + 562.5K = 2.2125M

        outcomes = run_monte_carlo(sample_opportunities, num_simulations=50_000)
        simulated_mean = np.mean(outcomes)

        # Allow 2% tolerance — should be much tighter with 50K runs
        tolerance = expected_value * 0.02
        assert abs(simulated_mean - expected_value) < tolerance, (
            f"Simulated mean {simulated_mean:.0f} should be within 2% of "
            f"expected value {expected_value:.0f}"
        )

    def test_output_shape(self, sample_opportunities):
        """Output array should have exactly num_simulations elements."""
        num_sims = 5000
        outcomes = run_monte_carlo(sample_opportunities, num_simulations=num_sims)
        assert len(outcomes) == num_sims, f"Expected {num_sims} outcomes, got {len(outcomes)}"

    def test_outcomes_are_non_negative(self, sample_opportunities):
        """Revenue can never be negative — a deal can only be won or lost, not reversed."""
        outcomes = run_monte_carlo(sample_opportunities, num_simulations=1000)
        assert np.all(outcomes >= 0), "All revenue outcomes must be non-negative"

    def test_outcomes_bounded_by_total_pipeline(self, sample_opportunities):
        """Revenue can never exceed the sum of all deal amounts."""
        total = sum(o.amount for o in sample_opportunities)
        outcomes = run_monte_carlo(sample_opportunities, num_simulations=1000)
        assert np.all(outcomes <= total + 0.01), f"Outcomes cannot exceed total pipeline ({total})"

    def test_empty_opportunities_returns_zeros(self):
        """Empty opportunity list should return all-zero outcomes."""
        outcomes = run_monte_carlo([], num_simulations=1000)
        assert np.all(outcomes == 0)
        assert len(outcomes) == 1000


# ─── Test: Summary Statistics ─────────────────────────────────────────────────

class TestSummaryStatistics:

    def test_percentiles_are_ordered(self, sample_opportunities):
        """Percentiles must be monotonically increasing: p10 ≤ p25 ≤ median ≤ p75 ≤ p90."""
        outcomes = run_monte_carlo(sample_opportunities, num_simulations=10_000)
        stats = compute_summary_statistics(outcomes, sample_opportunities)

        assert stats.p10 <= stats.p25 <= stats.median <= stats.p75 <= stats.p90, (
            f"Percentiles not ordered: p10={stats.p10}, p25={stats.p25}, "
            f"median={stats.median}, p75={stats.p75}, p90={stats.p90}"
        )

    def test_min_max_bounds(self, sample_opportunities):
        """Min and max should be within [0, total_pipeline]."""
        total = sum(o.amount for o in sample_opportunities)
        outcomes = run_monte_carlo(sample_opportunities, num_simulations=5_000)
        stats = compute_summary_statistics(outcomes, sample_opportunities)

        assert stats.min_outcome >= 0
        assert stats.max_outcome <= total + 0.01

    def test_weighted_pipeline_calculation(self, sample_opportunities):
        """Weighted pipeline (sum of amount×prob) should match manual calculation."""
        outcomes = run_monte_carlo(sample_opportunities, num_simulations=100)
        stats = compute_summary_statistics(outcomes, sample_opportunities)

        expected_weighted = (
            1_000_000 * 0.9 +
            500_000   * 0.5 +
            2_000_000 * 0.25 +
            750_000   * 0.75
        )
        assert abs(stats.weighted_pipeline_value - expected_weighted) < 0.01

    def test_total_pipeline_calculation(self, sample_opportunities):
        """Total pipeline should equal sum of all amounts."""
        outcomes = run_monte_carlo(sample_opportunities, num_simulations=100)
        stats = compute_summary_statistics(outcomes, sample_opportunities)
        expected_total = 1_000_000 + 500_000 + 2_000_000 + 750_000
        assert abs(stats.total_pipeline_value - expected_total) < 0.01


# ─── Test: Target Analysis ────────────────────────────────────────────────────

class TestTargetAnalysis:

    def test_impossible_target_probability_near_zero(self, certain_opportunity):
        """Probability of hitting $10B from a $1M deal should be ~0%."""
        outcomes = run_monte_carlo(certain_opportunity, num_simulations=1000)
        results = compute_target_analysis(outcomes, [10_000_000_000], num_simulations=1000)
        assert results[0].probability < 0.01

    def test_easy_target_probability_near_one(self, certain_opportunity):
        """Probability of hitting $0 revenue should be 100%."""
        outcomes = run_monte_carlo(certain_opportunity, num_simulations=1000)
        results = compute_target_analysis(outcomes, [0.01], num_simulations=1000)
        assert results[0].probability > 0.99

    def test_targets_are_sorted(self, sample_opportunities):
        """Returned targets should be in ascending order."""
        outcomes = run_monte_carlo(sample_opportunities, num_simulations=1000)
        results = compute_target_analysis(
            outcomes, [5_000_000, 1_000_000, 2_000_000], num_simulations=1000
        )
        targets = [r.target for r in results]
        assert targets == sorted(targets), "Targets should be returned in ascending order"

    def test_probability_pct_format(self, sample_opportunities):
        """probability_pct should look like '72.4%'."""
        outcomes = run_monte_carlo(sample_opportunities, num_simulations=1000)
        results = compute_target_analysis(outcomes, [1_000_000], num_simulations=1000)
        pct_str = results[0].probability_pct
        assert pct_str.endswith("%")
        float(pct_str.rstrip("%"))  # Should be parseable as float — raises if not

    def test_probabilities_monotonically_decrease(self, sample_opportunities):
        """Higher revenue targets should have lower (or equal) hit probability."""
        outcomes = run_monte_carlo(sample_opportunities, num_simulations=10_000)
        results = compute_target_analysis(
            outcomes, [500_000, 1_000_000, 2_000_000, 5_000_000], num_simulations=10_000
        )
        probs = [r.probability for r in results]
        for i in range(len(probs) - 1):
            assert probs[i] >= probs[i + 1], (
                f"Probability for lower target ({probs[i]}) should be >= "
                f"probability for higher target ({probs[i + 1]})"
            )


# ─── Test: Time Horizon Filter ────────────────────────────────────────────────

class TestTimeHorizonFilter:

    def test_filter_removes_future_deals(self):
        """Deals closing beyond the horizon should be excluded."""
        today = date.today()
        opps = [
            Opportunity(name="Close Soon", amount=100_000, probability=0.9, close_date=today + timedelta(days=30)),
            Opportunity(name="Far Future", amount=999_999, probability=0.9, close_date=today + timedelta(days=365)),
        ]
        filtered, excluded = filter_opportunities_by_horizon(opps, time_horizon_days=90)
        assert len(filtered) == 1
        assert filtered[0].name == "Close Soon"
        assert excluded == 1

    def test_no_filter_returns_all(self, sample_opportunities):
        """None time_horizon_days should return all opportunities."""
        filtered, excluded = filter_opportunities_by_horizon(sample_opportunities, None)
        assert len(filtered) == len(sample_opportunities)
        assert excluded == 0

    def test_filter_excludes_past_deals(self):
        """Deals with close_date in the past should be excluded (already closed period)."""
        opps = [
            Opportunity(name="Past Deal",   amount=100_000, probability=0.5, close_date=date.today() - timedelta(days=10)),
            Opportunity(name="Future Deal", amount=200_000, probability=0.5, close_date=date.today() + timedelta(days=30)),
        ]
        filtered, excluded = filter_opportunities_by_horizon(opps, time_horizon_days=90)
        assert len(filtered) == 1
        assert filtered[0].name == "Future Deal"


# ─── Test: Histogram ──────────────────────────────────────────────────────────

class TestHistogram:

    def test_histogram_frequencies_sum_to_one(self, sample_opportunities):
        """All histogram bucket frequencies should sum to 1.0."""
        outcomes = run_monte_carlo(sample_opportunities, num_simulations=10_000)
        buckets = compute_histogram(outcomes, num_buckets=10)
        total_freq = sum(b.frequency for b in buckets)
        assert abs(total_freq - 1.0) < 0.001, f"Frequencies sum to {total_freq}, expected ~1.0"

    def test_histogram_counts_sum_to_simulations(self, sample_opportunities):
        """All histogram bucket counts should sum to num_simulations."""
        num_sims = 5000
        outcomes = run_monte_carlo(sample_opportunities, num_simulations=num_sims)
        buckets = compute_histogram(outcomes, num_buckets=10)
        total_count = sum(b.count for b in buckets)
        assert total_count == num_sims, f"Counts sum to {total_count}, expected {num_sims}"


# ─── Test: Full Integration ───────────────────────────────────────────────────

class TestFullSimulation:

    def test_full_simulation_returns_all_fields(self, sample_opportunities):
        """Full simulation response should have all required output sections."""
        result = run_full_simulation(
            opportunities=sample_opportunities,
            num_simulations=1000,
            time_horizon_days=None,
            revenue_targets=[1_000_000, 5_000_000],
        )
        assert result.summary_statistics is not None
        assert len(result.target_analysis) == 2
        assert len(result.histogram_buckets) > 0
        assert result.metadata is not None
        assert result.metadata.num_simulations == 1000
        assert result.metadata.opportunities_included == 4

    def test_full_simulation_with_horizon_filter(self, sample_opportunities):
        """Simulation with a tight time horizon should exclude distant deals."""
        result = run_full_simulation(
            opportunities=sample_opportunities,
            num_simulations=1000,
            time_horizon_days=45,  # Only deals in next 45 days
            revenue_targets=None,
        )
        # Only Deal A (30 days) should be included; B=60, C=90, D=120 days out
        assert result.metadata.opportunities_included == 1
        assert result.metadata.opportunities_filtered_out == 3

    def test_metadata_compute_time_is_positive(self, sample_opportunities):
        """Compute time should be a positive number."""
        result = run_full_simulation(
            opportunities=sample_opportunities,
            num_simulations=1000,
            time_horizon_days=None,
            revenue_targets=None,
        )
        assert result.metadata.compute_time_ms > 0


# ─── Test: Input Validation ───────────────────────────────────────────────────

class TestInputValidation:

    def test_opportunity_probability_must_be_0_to_1(self):
        """Probability outside [0, 1] should raise a validation error."""
        with pytest.raises(Exception):
            Opportunity(name="Bad", amount=100_000, probability=1.5, close_date=date.today())

    def test_opportunity_amount_must_be_positive(self):
        """Negative or zero amount should fail validation."""
        with pytest.raises(Exception):
            Opportunity(name="Bad", amount=-100, probability=0.5, close_date=date.today())

    def test_simulation_request_requires_opportunities(self):
        """Empty opportunities list should fail validation."""
        with pytest.raises(Exception):
            SimulationRequest(opportunities=[])
