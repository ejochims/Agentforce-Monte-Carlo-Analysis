# =============================================================================
# Dockerfile — Monte Carlo Forecast API
#
# Builds a production-ready container for the FastAPI simulation service.
#
# DESIGN CHOICES:
#   - Python 3.11 slim base: small image, fast pulls
#   - Non-root user: security best practice for any deployment target
#   - Multi-stage is NOT used here (no compiled assets) — single stage is clean
#   - numpy is the only heavy dependency; everything else is lightweight
#
# BUILD:
#   docker build -t monte-carlo-forecast .
#
# RUN:
#   docker run -p 8000:8000 monte-carlo-forecast
# =============================================================================

FROM python:3.11-slim

# ── Metadata ──────────────────────────────────────────────────────────────────
LABEL maintainer="Salesforce Solution Engineering"
LABEL description="Monte Carlo Revenue Forecast API for Agentforce"
LABEL version="1.0.0"

# ── System dependencies ───────────────────────────────────────────────────────
# gcc is needed by some numpy builds on slim images
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    curl \
    && rm -rf /var/lib/apt/lists/*

# ── Create non-root user ──────────────────────────────────────────────────────
# Running as root in a container is a security anti-pattern.
# This user has no shell, no home directory privileges beyond /app.
RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 --gid appgroup --no-create-home --shell /bin/false appuser

# ── Set working directory ─────────────────────────────────────────────────────
WORKDIR /app

# ── Install Python dependencies ───────────────────────────────────────────────
# Copy requirements first so Docker layer caching works:
# If only app code changes (not requirements), this layer is reused on rebuild.
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# ── Copy application code ─────────────────────────────────────────────────────
COPY api/ .

# ── Set file ownership ────────────────────────────────────────────────────────
RUN chown -R appuser:appgroup /app

# ── Switch to non-root user ───────────────────────────────────────────────────
USER appuser

# ── Health check ─────────────────────────────────────────────────────────────
# Docker and ECS/Heroku use this to know when the container is ready.
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT:-8000}/health || exit 1

# ── Expose port ───────────────────────────────────────────────────────────────
EXPOSE 8000

# ── Start command ──────────────────────────────────────────────────────────────
# Use gunicorn with uvicorn workers for production.
# - 2 workers: good default for a compute-bound service
# - Use PORT env var (required by Heroku; defaults to 8000 elsewhere)
CMD gunicorn main:app \
    --workers 2 \
    --worker-class uvicorn.workers.UvicornWorker \
    --bind "0.0.0.0:${PORT:-8000}" \
    --timeout 60 \
    --access-logfile - \
    --error-logfile -
