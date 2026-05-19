#!/usr/bin/env bash
set -euo pipefail

uid="${UID:-$(id -u)}"
log_file="${S2T_LOG_FILE:-/run/user/${uid}/s2t/s2t.log}"
max_bytes="${S2T_LOGROTATE_MAX_BYTES:-10485760}" # 10 MiB by default
keep="${S2T_LOGROTATE_KEEP:-5}"

if [[ ! "${max_bytes}" =~ ^[0-9]+$ ]] || [[ "${max_bytes}" -lt 1024 ]]; then
  echo "s2t-logrotate: invalid S2T_LOGROTATE_MAX_BYTES='${max_bytes}'" >&2
  exit 2
fi
if [[ ! "${keep}" =~ ^[0-9]+$ ]] || [[ "${keep}" -lt 1 ]]; then
  echo "s2t-logrotate: invalid S2T_LOGROTATE_KEEP='${keep}'" >&2
  exit 2
fi

mkdir -p "$(dirname "$log_file")"
touch "$log_file"

lock_file="${log_file}.rotate.lock"
exec 9>"$lock_file"
flock -n 9 || exit 0

size="$(stat -c '%s' "$log_file" 2>/dev/null || echo 0)"
if [[ "${size}" -lt "${max_bytes}" ]]; then
  exit 0
fi

for ((i=keep; i>=1; i--)); do
  src="${log_file}.${i}"
  dst="${log_file}.$((i+1))"
  if [[ -f "${src}" ]]; then
    mv -f "${src}" "${dst}"
  fi
done

cp -f "${log_file}" "${log_file}.1"
: > "${log_file}"
chmod 0644 "${log_file}" "${log_file}.1" || true

echo "s2t-logrotate: rotated ${log_file} (size=${size}, keep=${keep})"
