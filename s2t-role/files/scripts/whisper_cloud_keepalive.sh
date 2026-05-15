#!/usr/bin/env bash
set -euo pipefail

S2T_AUTOLOAD_ENV_FILES="${S2T_AUTOLOAD_ENV_FILES:-1}"

load_env_file_if_exists() {
    local file="$1"
    [ -f "$file" ] || return 0
    set -a
    # shellcheck disable=SC1090
    . "$file"
    set +a
}

if [ "$S2T_AUTOLOAD_ENV_FILES" = "1" ]; then
    load_env_file_if_exists "/etc/s2t/s2t.env"
    if [ -n "${HOME:-}" ]; then
        load_env_file_if_exists "$HOME/.config/s2t/secrets.env"
        load_env_file_if_exists "$HOME/.config/s2t/s2t.env"
    fi
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "s2t-gcp-keepalive: missing curl" >&2
    exit 1
fi

PROVIDER="${S2T_ASR_PROVIDER:-local}"
GCP_URL="${S2T_GCP_WHISPER_URL:-}"
HEALTH_PATH="${S2T_GCP_WHISPER_HEALTH_PATH:-/health}"
INTERVAL_SEC="${S2T_GCP_KEEPALIVE_INTERVAL_SEC:-480}"
CONNECT_TIMEOUT_SEC="${S2T_GCP_KEEPALIVE_CONNECT_TIMEOUT_SEC:-3}"
TIMEOUT_SEC="${S2T_GCP_KEEPALIVE_TIMEOUT_SEC:-10}"
BEARER_TOKEN="${S2T_GCP_WHISPER_BEARER_TOKEN:-}"

if [ "$PROVIDER" != "gcp-l4" ]; then
    echo "s2t-gcp-keepalive: provider=$PROVIDER, keepalive disabled"
    exit 0
fi

if [ "${S2T_GCP_KEEPALIVE_ENABLED:-1}" != "1" ]; then
    echo "s2t-gcp-keepalive: disabled by S2T_GCP_KEEPALIVE_ENABLED"
    exit 0
fi

if [ -z "${GCP_URL//[[:space:]]/}" ]; then
    echo "s2t-gcp-keepalive: missing S2T_GCP_WHISPER_URL" >&2
    exit 1
fi

if [ -z "$HEALTH_PATH" ]; then
    HEALTH_PATH="/health"
elif [ "${HEALTH_PATH#/}" = "$HEALTH_PATH" ]; then
    HEALTH_PATH="/${HEALTH_PATH}"
fi

HEALTH_URL="${GCP_URL%/}${HEALTH_PATH}"

if ! [[ "${INTERVAL_SEC:-}" =~ ^[0-9]+$ ]] || [ "$INTERVAL_SEC" -lt 10 ]; then
    INTERVAL_SEC=480
fi
if ! [[ "${CONNECT_TIMEOUT_SEC:-}" =~ ^[0-9]+$ ]] || [ "$CONNECT_TIMEOUT_SEC" -lt 1 ]; then
    CONNECT_TIMEOUT_SEC=3
fi
if ! [[ "${TIMEOUT_SEC:-}" =~ ^[0-9]+$ ]] || [ "$TIMEOUT_SEC" -lt 1 ]; then
    TIMEOUT_SEC=10
fi

curl_auth_args=()
if [ -n "${BEARER_TOKEN:-}" ]; then
    curl_auth_args=(-H "Authorization: Bearer ${BEARER_TOKEN}")
fi

echo "s2t-gcp-keepalive: started health=${HEALTH_URL} interval=${INTERVAL_SEC}s"
while true; do
    timestamp="$(date -Is 2>/dev/null || date)"
    if curl -fsS \
        --connect-timeout "$CONNECT_TIMEOUT_SEC" \
        --max-time "$TIMEOUT_SEC" \
        "${curl_auth_args[@]}" \
        "$HEALTH_URL" >/dev/null; then
        echo "${timestamp} s2t-gcp-keepalive: ok"
    else
        rc="$?"
        echo "${timestamp} s2t-gcp-keepalive: failed rc=${rc}" >&2
    fi
    sleep "$INTERVAL_SEC"
done
