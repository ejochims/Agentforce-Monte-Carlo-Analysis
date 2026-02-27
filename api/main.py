# =============================================================================
# main.py — FastAPI application entry point
#
# This file wires together all the pieces: routing, middleware, error handling,
# and the OpenAPI schema endpoint that Salesforce External Services needs.
#
# ARCHITECTURE NOTE:
#   This service is intentionally stateless — no database, no sessions, no
#   caching. Every request is fully self-contained. This makes it trivially
#   deployable to Heroku, AWS Lambda, or any container platform, and ensures
#   data never persists outside a single request lifecycle.
#
# SALESFORCE INTEGRATION:
#   Salesforce calls this via Named Credential → External Service.
#   The /api/v1/schema endpoint returns the OpenAPI spec that Salesforce
#   uses to understand the API shape during External Service registration.
# =============================================================================

import json
from datetime import datetime, timezone
from typing import Any, Dict

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from config import settings
from models import HealthResponse, SimulationRequest, SimulationResponse
from simulation import run_full_simulation

# ─── App Initialization ───────────────────────────────────────────────────────

app = FastAPI(
    title=settings.api_title,
    version=settings.api_version,
    description=settings.api_description,
    # These docs URLs are great for demo/dev but should be disabled in prod
    docs_url="/docs",
    redoc_url="/redoc",
    openapi_url="/openapi.json",
)

# ─── CORS Middleware ───────────────────────────────────────────────────────────
# Allows Salesforce Setup UI and Postman to call this during configuration.
# Named Credential callouts from Salesforce servers bypass CORS, but browser-
# based calls (e.g., from Setup → External Services → Test) need this.
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_origin_regex=r"https://.*\.(salesforce|force|lightning\.force)\.com",
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Content-Type", "Authorization", "X-Salesforce-Org-Id"],
)


# ─── Global Error Handler ──────────────────────────────────────────────────────
@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """
    Catch-all error handler — ensures we always return JSON, never an HTML
    error page. Salesforce's HTTP callout parser will fail on HTML responses.
    """
    return JSONResponse(
        status_code=500,
        content={
            "error": "internal_server_error",
            "message": str(exc) if settings.debug else "An unexpected error occurred.",
            "path": str(request.url.path),
        },
    )


# ─── Health Check ─────────────────────────────────────────────────────────────
@app.get(
    "/health",
    response_model=HealthResponse,
    summary="Health Check",
    description="Returns 200 OK when the service is running. Used by load balancers and Salesforce Named Credential connectivity tests.",
    tags=["Operations"],
)
async def health_check() -> HealthResponse:
    return HealthResponse(
        status="ok",
        version=settings.api_version,
        timestamp=datetime.now(timezone.utc),
    )


# ─── OpenAPI Schema Endpoint ───────────────────────────────────────────────────
@app.get(
    "/api/v1/schema",
    summary="OpenAPI 3.0 Schema",
    description=(
        "Returns the OpenAPI 3.0 specification for this service. "
        "Use this URL when registering this API as an External Service in Salesforce Setup. "
        "Note: Returns OpenAPI 3.0 (not 3.1) for Salesforce compatibility."
    ),
    tags=["Operations"],
    response_class=JSONResponse,
)
async def get_schema() -> Dict[str, Any]:
    """
    Serves the OpenAPI schema in a format compatible with Salesforce External Services.

    Salesforce External Services requires OpenAPI 3.0 (not 3.1). FastAPI generates
    3.1 by default, so we generate a compatible 3.0 version here.

    During External Service registration in Salesforce Setup:
      Setup → Integrations → External Services → New → Enter this URL
    """
    schema = build_openapi_30_schema()
    return JSONResponse(content=schema)


# ─── Monte Carlo Simulation Endpoint ──────────────────────────────────────────
@app.post(
    "/api/v1/simulate",
    response_model=SimulationResponse,
    summary="Run Monte Carlo Revenue Forecast",
    description=(
        "Accepts a list of Salesforce Opportunities and runs a Monte Carlo simulation "
        "to produce a revenue forecast distribution. Returns summary statistics, "
        "target hit-probabilities, and histogram data. "
        "Called by the MonteCarloActionHandler Apex class via Named Credential."
    ),
    tags=["Simulation"],
)
async def simulate(request: SimulationRequest) -> SimulationResponse:
    """
    Primary endpoint: runs the simulation and returns forecast results.

    The Apex handler posts to this endpoint with opportunity data queried from
    the Salesforce org. This service runs the math and returns structured results
    that the Agentforce Agent formats into a conversational response.
    """
    try:
        result = run_full_simulation(
            opportunities=request.opportunities,
            num_simulations=request.num_simulations,
            time_horizon_days=request.time_horizon_days,
            revenue_targets=request.revenue_targets,
        )
        return result
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))
    except MemoryError:
        raise HTTPException(
            status_code=400,
            detail=f"Simulation too large. Reduce num_simulations or opportunity count.",
        )


# ─── OpenAPI 3.0 Schema Builder ───────────────────────────────────────────────

def build_openapi_30_schema() -> Dict[str, Any]:
    """
    Hand-crafted OpenAPI 3.0 schema for Salesforce External Services compatibility.

    Why hand-craft instead of using FastAPI's built-in? FastAPI generates OpenAPI 3.1,
    and Salesforce External Services (as of Winter '25) only supports 3.0. The key
    differences are: nullable fields use `nullable: true` instead of anyOf+null,
    and the info structure is slightly different.
    """
    return {
        "openapi": "3.0.3",
        "info": {
            "title": settings.api_title,
            "description": settings.api_description,
            "version": settings.api_version,
            "contact": {
                "name": "Salesforce Solution Engineering",
            },
        },
        "servers": [
            {
                "url": "/",
                "description": "This server — configure base URL in Salesforce Named Credential",
            }
        ],
        "paths": {
            "/health": {
                "get": {
                    "operationId": "healthCheck",
                    "summary": "Health Check",
                    "description": "Returns 200 OK when the service is operational.",
                    "tags": ["Operations"],
                    "responses": {
                        "200": {
                            "description": "Service is healthy",
                            "content": {
                                "application/json": {
                                    "schema": {"$ref": "#/components/schemas/HealthResponse"}
                                }
                            },
                        }
                    },
                }
            },
            "/api/v1/simulate": {
                "post": {
                    "operationId": "runMonteCarloSimulation",
                    "summary": "Run Monte Carlo Revenue Forecast",
                    "description": (
                        "Accepts pipeline opportunities and runs a Monte Carlo simulation. "
                        "Returns revenue distribution statistics and target hit-probabilities."
                    ),
                    "tags": ["Simulation"],
                    "requestBody": {
                        "required": True,
                        "content": {
                            "application/json": {
                                "schema": {"$ref": "#/components/schemas/SimulationRequest"}
                            }
                        },
                    },
                    "responses": {
                        "200": {
                            "description": "Simulation results",
                            "content": {
                                "application/json": {
                                    "schema": {"$ref": "#/components/schemas/SimulationResponse"}
                                }
                            },
                        },
                        "422": {
                            "description": "Validation error — check request payload format",
                            "content": {
                                "application/json": {
                                    "schema": {"$ref": "#/components/schemas/ErrorResponse"}
                                }
                            },
                        },
                    },
                }
            },
        },
        "components": {
            "schemas": {
                "Opportunity": {
                    "type": "object",
                    "required": ["name", "amount", "probability", "close_date"],
                    "properties": {
                        "name": {"type": "string", "description": "Opportunity name or identifier."},
                        "amount": {"type": "number", "format": "double", "description": "Deal value in USD. Must be > 0."},
                        "probability": {"type": "number", "format": "double", "minimum": 0.0, "maximum": 1.0, "description": "Win probability (0.0 to 1.0)."},
                        "close_date": {"type": "string", "format": "date", "description": "Expected close date (YYYY-MM-DD)."},
                    },
                },
                "SimulationRequest": {
                    "type": "object",
                    "required": ["opportunities"],
                    "properties": {
                        "opportunities": {
                            "type": "array",
                            "items": {"$ref": "#/components/schemas/Opportunity"},
                            "minItems": 1,
                            "maxItems": 500,
                        },
                        "num_simulations": {"type": "integer", "default": 10000, "minimum": 100, "maximum": 100000, "description": "Number of simulation iterations."},
                        "time_horizon_days": {"type": "integer", "nullable": True, "minimum": 1, "maximum": 730, "description": "Filter to deals closing within N days."},
                        "revenue_targets": {"type": "array", "items": {"type": "number"}, "nullable": True, "description": "Revenue targets to compute hit probabilities for."},
                    },
                },
                "SummaryStatistics": {
                    "type": "object",
                    "properties": {
                        "mean": {"type": "number", "description": "Average revenue across all simulation runs."},
                        "median": {"type": "number", "description": "Median revenue outcome."},
                        "std_dev": {"type": "number", "description": "Standard deviation — measure of forecast uncertainty."},
                        "p10": {"type": "number", "description": "10th percentile — pessimistic scenario."},
                        "p25": {"type": "number", "description": "25th percentile — conservative scenario."},
                        "p75": {"type": "number", "description": "75th percentile — optimistic scenario."},
                        "p90": {"type": "number", "description": "90th percentile — best-case scenario."},
                        "min_outcome": {"type": "number", "description": "Minimum revenue across all runs."},
                        "max_outcome": {"type": "number", "description": "Maximum revenue across all runs."},
                        "total_pipeline_value": {"type": "number", "description": "Sum of all amounts (100% win scenario)."},
                        "weighted_pipeline_value": {"type": "number", "description": "Sum of amount × probability per deal."},
                    },
                },
                "TargetAnalysis": {
                    "type": "object",
                    "properties": {
                        "target": {"type": "number", "description": "Revenue target in USD."},
                        "probability": {"type": "number", "description": "Hit probability (0.0 to 1.0)."},
                        "probability_pct": {"type": "string", "description": "Human-readable probability, e.g. '72.4%'."},
                    },
                },
                "HistogramBucket": {
                    "type": "object",
                    "properties": {
                        "range_low": {"type": "number"},
                        "range_high": {"type": "number"},
                        "label": {"type": "string", "description": "Formatted range, e.g. '$8M – $9M'."},
                        "count": {"type": "integer"},
                        "frequency": {"type": "number", "description": "Fraction of runs in this bucket."},
                    },
                },
                "SimulationMetadata": {
                    "type": "object",
                    "properties": {
                        "num_simulations": {"type": "integer"},
                        "opportunities_included": {"type": "integer"},
                        "opportunities_filtered_out": {"type": "integer"},
                        "compute_time_ms": {"type": "number"},
                        "timestamp": {"type": "string", "format": "date-time"},
                        "time_horizon_days": {"type": "integer", "nullable": True},
                        "api_version": {"type": "string"},
                    },
                },
                "SimulationResponse": {
                    "type": "object",
                    "properties": {
                        "summary_statistics": {"$ref": "#/components/schemas/SummaryStatistics"},
                        "target_analysis": {"type": "array", "items": {"$ref": "#/components/schemas/TargetAnalysis"}},
                        "histogram_buckets": {"type": "array", "items": {"$ref": "#/components/schemas/HistogramBucket"}},
                        "metadata": {"$ref": "#/components/schemas/SimulationMetadata"},
                    },
                },
                "HealthResponse": {
                    "type": "object",
                    "properties": {
                        "status": {"type": "string"},
                        "version": {"type": "string"},
                        "timestamp": {"type": "string", "format": "date-time"},
                    },
                },
                "ErrorResponse": {
                    "type": "object",
                    "properties": {
                        "detail": {"type": "string"},
                    },
                },
            }
        },
    }


# ─── Local Dev Entry Point ─────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host=settings.host,
        port=settings.port,
        reload=settings.debug,
        log_level="debug" if settings.debug else "info",
    )
