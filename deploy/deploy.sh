#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Deployment helper for Monte Carlo Forecast API
#
# Supports three deployment targets:
#   local    — docker-compose up (for development and demos)
#   heroku   — Heroku Container Registry (easiest cloud option for demos)
#   lambda   — AWS Lambda via Mangum adapter (serverless, cheapest at scale)
#
# USAGE:
#   ./deploy/deploy.sh local
#   ./deploy/deploy.sh heroku --app my-monte-carlo-app
#   ./deploy/deploy.sh lambda --function-name monte-carlo-forecast
#
# PREREQUISITES by target:
#   local:  Docker Desktop running
#   heroku: heroku CLI installed, logged in, app created
#   lambda: AWS CLI configured, ECR repo created, SAM CLI installed
# =============================================================================

set -euo pipefail  # Exit on error, undefined var, or pipe failure

# ── Color output helpers ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Script directory — ensure we run from repo root ───────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# ─────────────────────────────────────────────────────────────────────────────
# TARGET: local
# Starts the service with docker-compose, hot-reload enabled.
# Great for demos — maps to http://localhost:8000
# ─────────────────────────────────────────────────────────────────────────────
deploy_local() {
    info "Starting Monte Carlo API locally with docker-compose..."

    # Check .env exists (copy from example if not)
    if [ ! -f ".env" ]; then
        warn ".env not found — copying from .env.example"
        cp .env.example .env
        warn "Edit .env with your config before restarting."
    fi

    docker-compose -f deploy/docker-compose.yml up --build "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# TARGET: heroku
# Deploys to Heroku using Container Registry.
# Requires: heroku CLI, logged in, app already created.
#
# USAGE: ./deploy/deploy.sh heroku --app your-app-name
# ─────────────────────────────────────────────────────────────────────────────
deploy_heroku() {
    # Parse --app flag
    APP_NAME=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app) APP_NAME="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [ -z "${APP_NAME}" ]; then
        error "Heroku app name required. Usage: ./deploy.sh heroku --app your-app-name"
    fi

    info "Deploying to Heroku app: ${APP_NAME}"

    # Verify heroku CLI is available
    command -v heroku &>/dev/null || error "heroku CLI not installed. Install at https://devcenter.heroku.com/articles/heroku-cli"

    # Log in to Heroku Container Registry
    info "Logging in to Heroku Container Registry..."
    heroku container:login

    # Build and push the image
    info "Building and pushing Docker image..."
    heroku container:push web \
        --app "${APP_NAME}" \
        --context-path . \
        --dockerfile deploy/Dockerfile

    # Release the new image
    info "Releasing new image..."
    heroku container:release web --app "${APP_NAME}"

    # Confirm the app is running
    APP_URL="https://${APP_NAME}.herokuapp.com"
    info "Waiting for app to start..."
    sleep 5
    if curl -sf "${APP_URL}/health" > /dev/null; then
        success "Deployment successful! Service running at ${APP_URL}"
        success "Health check: ${APP_URL}/health"
        success "API docs:     ${APP_URL}/docs"
        success "Schema URL:   ${APP_URL}/api/v1/schema  ← Use this in Salesforce External Services"
    else
        warn "App deployed but health check not yet responding. Check: heroku logs --app ${APP_NAME} --tail"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# TARGET: lambda
# Deploys to AWS Lambda as a container image using Mangum adapter.
# Requires: AWS CLI configured, ECR repo, SAM CLI.
#
# USAGE: ./deploy/deploy.sh lambda --function-name monte-carlo-forecast
# ─────────────────────────────────────────────────────────────────────────────
deploy_lambda() {
    FUNCTION_NAME="monte-carlo-forecast"
    AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
    AWS_ACCOUNT_ID=""

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --function-name) FUNCTION_NAME="$2"; shift 2 ;;
            --region) AWS_REGION="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Verify AWS CLI
    command -v aws &>/dev/null || error "AWS CLI not installed. Install at https://aws.amazon.com/cli/"

    # Get AWS account ID
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${FUNCTION_NAME}"

    info "Deploying to AWS Lambda: ${FUNCTION_NAME} in ${AWS_REGION}"

    # Create ECR repo if it doesn't exist
    info "Ensuring ECR repository exists..."
    aws ecr describe-repositories --repository-names "${FUNCTION_NAME}" --region "${AWS_REGION}" &>/dev/null || \
        aws ecr create-repository --repository-name "${FUNCTION_NAME}" --region "${AWS_REGION}"

    # Build the Lambda-compatible image
    # Note: The Dockerfile needs a Mangum-wrapped handler for Lambda.
    # For Lambda, we override the CMD to use the Lambda handler entry point.
    info "Building Lambda container image..."
    docker build \
        --platform linux/amd64 \
        --build-arg DEPLOY_TARGET=lambda \
        -t "${FUNCTION_NAME}:latest" \
        -f deploy/Dockerfile .

    # Push to ECR
    info "Pushing image to ECR..."
    aws ecr get-login-password --region "${AWS_REGION}" | \
        docker login --username AWS --password-stdin "${ECR_URI}"

    docker tag "${FUNCTION_NAME}:latest" "${ECR_URI}:latest"
    docker push "${ECR_URI}:latest"

    # Update the Lambda function (assumes function already exists)
    info "Updating Lambda function..."
    aws lambda update-function-code \
        --function-name "${FUNCTION_NAME}" \
        --image-uri "${ECR_URI}:latest" \
        --region "${AWS_REGION}"

    success "Lambda deployment complete!"
    info "Add API Gateway in front for a public URL."
    info "Recommended timeout: 30s | Memory: 512MB"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main — parse target and dispatch
# ─────────────────────────────────────────────────────────────────────────────
TARGET="${1:-}"
shift || true

case "${TARGET}" in
    local)   deploy_local "$@" ;;
    heroku)  deploy_heroku "$@" ;;
    lambda)  deploy_lambda "$@" ;;
    "")      error "Deployment target required. Usage: ./deploy.sh [local|heroku|lambda]" ;;
    *)       error "Unknown target: '${TARGET}'. Valid targets: local, heroku, lambda" ;;
esac
