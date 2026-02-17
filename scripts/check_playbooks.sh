#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

venv="${VENV:-.venv}"

if [[ -x "$venv/bin/ansible-playbook" ]]; then
  ansible_playbook="$(cd "$venv" && pwd)/bin/ansible-playbook"
else
  ansible_playbook="ansible-playbook"
fi

echo "==> ansible-playbook syntax-check"
"$ansible_playbook" --syntax-check -i "localhost," -c local install.yml
"$ansible_playbook" --syntax-check -i "localhost," -c local uninstall.yml

echo "==> uninstall.yml safety checks"
if rg -n "^\\s*handlers\\s*:" uninstall.yml >/dev/null; then
  echo "ERROR: uninstall.yml must not define handlers (they can run unprivileged and fail daemon-reload)."
  exit 1
fi

if rg -n "notify:\\s*Reload Systemd" uninstall.yml >/dev/null; then
  echo "ERROR: uninstall.yml must not notify Reload Systemd handler."
  exit 1
fi

if ! rg -n "systemctl\\s+daemon-reload\\s+--timeout=" uninstall.yml >/dev/null; then
  echo "ERROR: uninstall.yml must reload systemd with an explicit timeout."
  exit 1
fi

echo "==> regression tests"
"$repo_root/scripts/regression_tests.sh"

echo "OK"
