#!/usr/bin/env bash
set -euo pipefail

systemctl disable --now whisper-cloud-keepalive.service || true
rm -f /etc/systemd/system/whisper-cloud-keepalive.service
rm -f /usr/local/bin/whisper-cloud-keepalive.sh
systemctl daemon-reload

echo "whisper-cloud-keepalive removed"
