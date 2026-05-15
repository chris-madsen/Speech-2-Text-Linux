#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -m 0755 "${ROOT_DIR}/whisper-cloud-keepalive.sh" /usr/local/bin/whisper-cloud-keepalive.sh
install -m 0644 "${ROOT_DIR}/whisper-cloud-keepalive.service" /etc/systemd/system/whisper-cloud-keepalive.service

if [ ! -f /etc/default/whisper-cloud-keepalive ]; then
  cat >/etc/default/whisper-cloud-keepalive <<'EOC'
# Example:
# SERVICE_URL="https://whisper-l4-xxxxx-uc.a.run.app"
SERVICE_URL=""
INTERVAL_SECONDS=480
CONNECT_TIMEOUT_SECONDS=5
REQUEST_TIMEOUT_SECONDS=20
EOC
  chmod 0644 /etc/default/whisper-cloud-keepalive
fi

systemd-analyze verify /etc/systemd/system/whisper-cloud-keepalive.service
systemctl daemon-reload
systemctl enable --now whisper-cloud-keepalive.service
systemctl status whisper-cloud-keepalive.service --no-pager
