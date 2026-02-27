# =============================================================================
# simulation.py — Monte Carlo simulation engine
#
# This is the mathematical core of the service. It takes a list of
# opportunities (each with an amount and a win probability) and runs thousands
# of simulated "quarter-end" scenarios to produce a revenue distribution.
#
# HOW MONTE CARLO WORKS (for workshop facilitators):
#   Imagine flipping a weighted coin for every deal — if a deal has 70%
#   probability, it's like a coin that lands "won" 70% of the time.
#   We flip all coins simultaneously, sum the won amounts, and record the
#   total. Do this 10,000 times and you get a realistic distribution of
#   possible quarter-end outcomes.
#
# WHY NUMPY?
#   Pure Python loops would take ~10 seconds for 10,000 runs × 200 deals.
#   NumPy runs the same computation in ~50ms using vectorized C operations.
#   This is the only dependency we truly need (no pandas, no scipy).
# =============================================================================

import numpy as np
import time
from datetime import date, datetime, timezone
from typing import List, Optional

from models import (
    Opportunity,
    SummaryStatistics,
    TargetAnalysis,
    HistogramBucket,
    SimulationMetadata,
    SimulationResponse,
)
from config import settings


def filter_opportunities_by_horizon(
    opportunities: List[Opportunity],
    time_horizon_days: Optional[int],
) -> tuple[List[Opportunity], int]:
    """
    Filter opportunities to only those closing within the time window.

    Returns (filtered_list, count_removed).
    If time_horizon_days is None, all opportunities pass through.
    """
    if time_horizon_days is None:
        return opportunities, 0

    cutoff = date.today()
    from datetime import timedelta
    horizon_date = cutoff + timedelta(days=time_horizon_days)

    included = [o for o in opportunities if cutoff <= o.close_date <= horizon_date]
    excluded_count = len(opportunities) - len(included)
    return included, excluded_count


def run_monte_carlo(
    opportunities: List[Opportunity],
    num_simulations: int,
) -> np.ndarray:
    """
    Core simulation: run N independent revenue scenarios and return results.

    For each simulation run:
      1. Draw a uniform random number [0, 1] for each opportunity
      2. If random < probability → deal is won (include its amount)
      3. Sum all won amounts → one revenue scenario
    Repeat N times using NumPy's vectorized operations.

    Returns a 1D numpy array of shape (num_simulations,) with revenue totals.
    """
    if not opportunities:
        return np.zeros(num_simulations)

    # Build arrays for vectorized math — one element per opportunity
    amounts = np.array([o.amount for o in opportunities], dtype=np.float64)        # shape: (n_deals,)
    probabilities = np.array([o.probability for o in opportunities], dtype=np.float64)  # shape: (n_deals,)

    # Generate all random numbers at once: shape (num_simulations, n_deals)
    # Each row = one simulation run; each column = one deal's random draw
    random_draws = np.random.uniform(0, 1, size=(num_simulations, len(opportunities)))

    # Won matrix: True where random draw < probability (deal is won)
    # Broadcasting: probabilities shape (n_deals,) broadcasts across rows
    won_matrix = random_draws < probabilities  # shape: (num_simulations, n_deals)

    # For each simulation, sum the amounts of won deals
    # won_matrix * amounts: element-wise multiply (won=1×amount, lost=0×amount)
    # .sum(axis=1): sum across deals for each simulation run
    revenue_per_run = (won_matrix * amounts).sum(axis=1)  # shape: (num_simulations,)

    return revenue_per_run


def compute_summary_statistics(
    outcomes: np.ndarray,
    opportunities: List[Opportunity],
) -> SummaryStatistics:
    """Compute descriptive statistics from the simulation outcome distribution."""

    total_pipeline = sum(o.amount for o in opportunities)
    weighted_pipeline = sum(o.amount * o.probability for o in opportunities)

    return SummaryStatistics(
        mean=float(np.mean(outcomes)),
        median=float(np.median(outcomes)),
        std_dev=float(np.std(outcomes)),
        p10=float(np.percentile(outcomes, 10)),
        p25=float(np.percentile(outcomes, 25)),
        p75=float(np.percentile(outcomes, 75)),
        p90=float(np.percentile(outcomes, 90)),
        min_outcome=float(np.min(outcomes)),
        max_outcome=float(np.max(outcomes)),
        total_pipeline_value=round(total_pipeline, 2),
        weighted_pipeline_value=round(weighted_pipeline, 2),
    )


def compute_target_analysis(
    outcomes: np.ndarray,
    targets: List[float],
    num_simulations: int,
) -> List[TargetAnalysis]:
    """
    For each revenue target, calculate what fraction of simulations hit it.

    Example: if 7,200 out of 10,000 runs exceeded $10M, that's a 72.0% probability.
    This is the key number the Agentforce Agent surfaces conversationally.
    """
    results = []
    for target in sorted(targets):
        hit_count = int(np.sum(outcomes >= target))
        probability = hit_count / num_simulations

        # Format target as a human-readable label (e.g., "$10.0M")
        if target >= 1_000_000:
            target_label = f"${target / 1_000_000:.1f}M"
        elif target >= 1_000:
            target_label = f"${target / 1_000:.0f}K"
        else:
            target_label = f"${target:,.0f}"

        results.append(TargetAnalysis(
            target=round(target, 2),
            probability=round(probability, 4),
            probability_pct=f"{probability * 100:.1f}%",
        ))
    return results


def compute_histogram(
    outcomes: np.ndarray,
    num_buckets: int = 12,
) -> List[HistogramBucket]:
    """
    Bin the simulation outcomes into N buckets for visualization.

    Returns a list of buckets with counts and frequencies — ready to
    feed into a chart library or display in Slack as a text histogram.
    """
    counts, bin_edges = np.histogram(outcomes, bins=num_buckets)
    num_simulations = len(outcomes)
    buckets = []

    for i in range(len(counts)):
        low = float(bin_edges[i])
        high = float(bin_edges[i + 1])
        count = int(counts[i])

        # Format bucket label using appropriate scale
        def fmt(v: float) -> str:
            if v >= 1_000_000:
                return f"${v / 1_000_000:.1f}M"
            elif v >= 1_000:
                return f"${v / 1_000:.0f}K"
            else:
                return f"${v:,.0f}"

        buckets.append(HistogramBucket(
            range_low=round(low, 2),
            range_high=round(high, 2),
            label=f"{fmt(low)} – {fmt(high)}",
            count=count,
            frequency=round(count / num_simulations, 4) if num_simulations > 0 else 0.0,
        ))

    return buckets


def run_full_simulation(
    opportunities: List[Opportunity],
    num_simulations: int,
    time_horizon_days: Optional[int],
    revenue_targets: Optional[List[float]],
) -> SimulationResponse:
    """
    Orchestrate the full simulation pipeline and return a complete response.

    This is the single entry point called by the FastAPI route handler.
    Steps:
      1. Filter opportunities by time horizon
      2. Run Monte Carlo iterations
      3. Compute statistics, target probabilities, histogram
      4. Wrap in metadata and return
    """
    start_time = time.perf_counter()

    # Step 1: Filter by time horizon
    filtered_opps, excluded_count = filter_opportunities_by_horizon(
        opportunities, time_horizon_days
    )

    # Step 2: Determine revenue targets
    targets = revenue_targets if revenue_targets else settings.default_revenue_targets

    # Step 3: Run simulation
    outcomes = run_monte_carlo(filtered_opps, num_simulations)

    # Step 4: Compute all derived statistics
    summary_stats = compute_summary_statistics(outcomes, filtered_opps)
    target_analysis = compute_target_analysis(outcomes, targets, num_simulations)
    histogram = compute_histogram(outcomes)

    # Step 5: Build metadata
    elapsed_ms = (time.perf_counter() - start_time) * 1000
    metadata = SimulationMetadata(
        num_simulations=num_simulations,
        opportunities_included=len(filtered_opps),
        opportunities_filtered_out=excluded_count,
        compute_time_ms=round(elapsed_ms, 2),
        timestamp=datetime.now(timezone.utc),
        time_horizon_days=time_horizon_days,
    )

    return SimulationResponse(
        summary_statistics=summary_stats,
        target_analysis=target_analysis,
        histogram_buckets=histogram,
        metadata=metadata,
    )
