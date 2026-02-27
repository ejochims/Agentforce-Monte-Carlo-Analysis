# =============================================================================
# models.py — Request/Response data models
#
# Pydantic v2 models define exactly what data comes IN and goes OUT of the API.
# Think of these as the "contract" — if a payload violates these rules, FastAPI
# automatically returns a 422 error with a clear message before our code runs.
#
# For Salesforce External Services, these models also drive the generated
# OpenAPI spec — so clean models = clean schema = easier External Service setup.
# =============================================================================

from pydantic import BaseModel, Field, field_validator, model_validator
from typing import List, Optional
from datetime import date, datetime


# ─── Input Models ─────────────────────────────────────────────────────────────

class Opportunity(BaseModel):
    """
    Represents a single Salesforce Opportunity for simulation.

    Maps directly to the Salesforce Opportunity object fields that the
    Apex handler will query. We intentionally exclude account names and
    contact data — only statistical inputs needed for forecasting.
    """

    name: str = Field(
        description="Opportunity name or identifier. Used only for tracking — not in computation.",
        max_length=255,
        examples=["Q1 Enterprise Deal - Acme Corp"]
    )
    amount: float = Field(
        description="Expected deal value in USD. Must be positive.",
        gt=0,
        examples=[250000.0]
    )
    probability: float = Field(
        description="Win probability as a decimal between 0.0 and 1.0. Maps to Salesforce Opportunity.Probability / 100.",
        ge=0.0,
        le=1.0,
        examples=[0.75]
    )
    close_date: date = Field(
        description="Expected close date (YYYY-MM-DD). Used to filter by time_horizon_days.",
        examples=["2025-03-31"]
    )

    @field_validator("amount")
    @classmethod
    def amount_must_be_reasonable(cls, v: float) -> float:
        """Guard against obviously bad data — a single deal over $10B is likely a data entry error."""
        if v > 10_000_000_000:
            raise ValueError("Amount exceeds $10B — please verify this is correct.")
        return round(v, 2)


class SimulationRequest(BaseModel):
    """
    Full request payload for the /simulate endpoint.

    The Apex class builds this payload and posts it to the Named Credential.
    The Agentforce LLM orchestrator never sees this directly — it talks to
    the Apex class, which translates natural language intent into this struct.
    """

    opportunities: List[Opportunity] = Field(
        description="List of open opportunities to include in the simulation.",
        min_length=1,
        max_length=500
    )
    num_simulations: int = Field(
        default=10_000,
        description="Number of Monte Carlo iterations to run. More = more accurate, slower. 10,000 is a good default.",
        ge=100,
        le=100_000
    )
    time_horizon_days: Optional[int] = Field(
        default=None,
        description="If set, only include opportunities with close_date within this many days from today.",
        ge=1,
        le=730,
        examples=[90]
    )
    revenue_targets: Optional[List[float]] = Field(
        default=None,
        description="Revenue amounts to calculate hit-probability for. Defaults to [1M, 5M, 10M, 25M, 50M].",
        examples=[[5_000_000, 10_000_000, 20_000_000]]
    )

    @model_validator(mode="after")
    def validate_targets_are_positive(self) -> "SimulationRequest":
        if self.revenue_targets:
            for t in self.revenue_targets:
                if t <= 0:
                    raise ValueError(f"Revenue target must be positive, got: {t}")
        return self


# ─── Output Models ────────────────────────────────────────────────────────────

class SummaryStatistics(BaseModel):
    """
    Descriptive statistics computed across all simulation runs.

    These are the numbers that let the Agent say things like:
    "Your expected revenue is $8.2M, but there's meaningful upside to $12M."
    """

    mean: float = Field(description="Average (expected) total revenue across all simulations.")
    median: float = Field(description="Middle value — half of simulations landed above, half below.")
    std_dev: float = Field(description="Standard deviation — measures spread/uncertainty in the forecast.")
    p10: float = Field(description="10th percentile — pessimistic scenario (only 10% of outcomes were lower).")
    p25: float = Field(description="25th percentile — conservative scenario.")
    p75: float = Field(description="75th percentile — optimistic scenario.")
    p90: float = Field(description="90th percentile — very optimistic scenario (only 10% of outcomes were higher).")
    min_outcome: float = Field(description="Worst-case result across all simulations.")
    max_outcome: float = Field(description="Best-case result across all simulations.")
    total_pipeline_value: float = Field(description="Sum of all opportunity amounts (100% win rate scenario).")
    weighted_pipeline_value: float = Field(description="Sum of (amount × probability) for each opportunity — the 'expected value' without simulation.")


class TargetAnalysis(BaseModel):
    """Probability of achieving a specific revenue target."""

    target: float = Field(description="The revenue target in USD.")
    probability: float = Field(description="Fraction of simulations that met or exceeded this target (0.0–1.0).")
    probability_pct: str = Field(description="Human-readable probability, e.g. '72.4%'. Ready for the Agent to speak aloud.")


class HistogramBucket(BaseModel):
    """
    One bar in a revenue distribution histogram.

    These buckets let a frontend chart show the shape of the forecast
    distribution — useful in a Slack canvas or Einstein Analytics dashboard.
    """

    range_low: float = Field(description="Lower bound of this bucket (inclusive).")
    range_high: float = Field(description="Upper bound of this bucket (exclusive).")
    label: str = Field(description="Human-readable range label, e.g. '$8M – $9M'.")
    count: int = Field(description="Number of simulation runs that fell in this range.")
    frequency: float = Field(description="Fraction of runs in this bucket (count / num_simulations).")


class SimulationMetadata(BaseModel):
    """Operational metadata about the simulation run itself."""

    num_simulations: int
    opportunities_included: int
    opportunities_filtered_out: int
    compute_time_ms: float = Field(description="Wall-clock time for the simulation in milliseconds.")
    timestamp: datetime
    time_horizon_days: Optional[int]
    api_version: str = "1.0.0"


class SimulationResponse(BaseModel):
    """
    Complete response payload returned to the Apex callout handler.

    The Apex class deserializes this and hands it to the Agentforce Agent,
    which uses summary_statistics and target_analysis to compose a
    conversational response like:
    'Based on your current pipeline, you have a 68% chance of hitting $10M
     this quarter. Your expected revenue is $9.4M, with a realistic range
     of $7.2M to $11.8M.'
    """

    summary_statistics: SummaryStatistics
    target_analysis: List[TargetAnalysis]
    histogram_buckets: List[HistogramBucket]
    metadata: SimulationMetadata


class HealthResponse(BaseModel):
    """Simple health check — used by load balancers and the Salesforce Named Credential test."""

    status: str = "ok"
    version: str
    timestamp: datetime
