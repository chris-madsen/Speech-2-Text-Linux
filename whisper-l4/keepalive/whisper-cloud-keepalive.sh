#!/usr/bin/env bash
set -euo pipefail

# Defaults can be overridden in /etc/default/whisper-cloud-keepalive.
SERVICE_URL="${SERVICE_URL:-}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-480}"
CONNECT_TIMEOUT_SECONDS="${CONNECT_TIMEOUT_SECONDS:-5}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-20}"

if [ -f /etc/default/whisper-cloud-keepalive ]; then
  # shellcheck disable=SC1091
  source /etc/default/whisper-cloud-keepalive
fi

if [ -z "${SERVICE_URL:-}" ]; then
  echo "SERVICE_URL is required (set in /etc/default/whisper-cloud-keepalive)" >&2
  exit 1
fi

HEALTH_URL="${SERVICE_URL%/}/health"

echo "keepalive started: health=${HEALTH_URL} interval=${INTERVAL_SECONDS}s"
while true; do
  ts="$(date -Iseconds)"
  if curl -fsS --connect-timeout "${CONNECT_TIMEOUT_SECONDS}" --max-time "${REQUEST_TIMEOUT_SECONDS}" "${HEALTH_URL}" >/dev/null; then
    echo "${ts} keepalive ok"
  else
    rc="$?"
    echo "${ts} keepalive failed rc=${rc}" >&2
  fi
  sleep "${INTERVAL_SECONDS}"
done
