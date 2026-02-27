# =============================================================================
# config.py — Application configuration
#
# All tunable settings are defined here using Pydantic's BaseSettings, which
# means every value can be overridden via environment variable without touching
# code. This is important for moving from local dev → Heroku → AWS without
# config drift.
#
# Why BaseSettings? Salesforce Solution Engineers often deploy to multiple orgs
# (sandbox, UAT, prod). Externalizing config means no code changes between
# environments — just set ENV VARS.
# =============================================================================

from pydantic_settings import BaseSettings, SettingsConfigDict
from typing import List


class Settings(BaseSettings):
    # ── Server ────────────────────────────────────────────────────────────────
    port: int = 8000
    host: str = "0.0.0.0"
    debug: bool = False

    # ── Simulation defaults ───────────────────────────────────────────────────
    # 10,000 runs gives a good distribution (~50ms) without being slow.
    # For a live demo, this is the right balance of "looks impressive" vs
    # "doesn't time out".
    default_num_simulations: int = 10_000
    max_num_simulations: int = 100_000
    max_opportunities: int = 500

    # ── Revenue targets to analyze by default (in USD) ───────────────────────
    # These are the thresholds the agent will report hit-probabilities for.
    # Tune these for your customer's actual pipeline targets.
    default_revenue_targets: List[float] = [
        1_000_000,
        5_000_000,
        10_000_000,
        25_000_000,
        50_000_000,
    ]

    # ── CORS — which origins can call this API ────────────────────────────────
    # Salesforce's Named Credential callout comes from Salesforce servers, not
    # a browser, so CORS doesn't technically apply to those. But we need CORS
    # open for the Postman / browser testing during setup. Restrict to your
    # org's My Domain in production.
    allowed_origins: List[str] = [
        "https://*.salesforce.com",
        "https://*.force.com",
        "https://*.lightning.force.com",
        "http://localhost:3000",
        "http://localhost:8080",
    ]

    # ── API metadata ──────────────────────────────────────────────────────────
    api_title: str = "Monte Carlo Revenue Forecast API"
    api_version: str = "1.0.0"
    api_description: str = (
        "Stateless Monte Carlo simulation service for Salesforce pipeline forecasting. "
        "Designed to be called from an Agentforce Agent Action via Named Credential."
    )

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")


# Module-level singleton — import this everywhere instead of re-instantiating
settings = Settings()
