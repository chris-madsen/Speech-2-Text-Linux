#!/usr/bin/env bash
set -euo pipefail

export UVICORN_HOST="${UVICORN_HOST:-0.0.0.0}"
export UVICORN_PORT="${PORT:-8080}"

exec uvicorn api.main:app --host "$UVICORN_HOST" --port "$UVICORN_PORT" --workers 1
