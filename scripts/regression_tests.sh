#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
controller="$repo_root/s2t-role/files/scripts/controller.sh"
monitor_script="$repo_root/s2t-role/files/scripts/monitor.py"
whisper_server_script="$repo_root/s2t-role/files/scripts/whisper_server.sh"
dataset_etl_script="$repo_root/s2t-role/files/scripts/dataset_etl_daemon.py"
codex_bridge_script="$repo_root/s2t-role/files/scripts/codex_correction_bridge.py"
rabbitmq_publish_script="$repo_root/s2t-role/files/scripts/rabbitmq_publish.py"
rabbitmq_drain_script="$repo_root/s2t-role/files/scripts/rabbitmq_drain_daemon.py"
monitor_unit="$repo_root/s2t-role/files/s2t-monitor.service"
whisper_unit="$repo_root/s2t-role/files/s2t-whisper.service"
dataset_etl_unit="$repo_root/s2t-role/files/s2t-dataset-etl.service"
codex_bridge_unit="$repo_root/s2t-role/files/s2t-codex-bridge.service"
rabbitmq_unit="$repo_root/s2t-role/files/s2t-rabbitmq.service"
rabbitmq_drain_unit="$repo_root/s2t-role/files/s2t-rabbitmq-drain.service"
s2t_target_unit="$repo_root/s2t-role/files/s2t.target"
rabbitmq_quadlet="$repo_root/s2t-role/files/s2t-rabbitmq.container"
keyd_conf="$repo_root/s2t-role/files/keyd.conf"
user_env_file="$repo_root/s2t-role/templates/s2t.user.env.default.j2"
tasks_main="$repo_root/s2t-role/tasks/main.yml"
handlers_main="$repo_root/s2t-role/handlers/main.yml"
uninstall_playbook="$repo_root/uninstall.yml"
dataset_builder="$repo_root/scripts/build_dataset.py"
system_env_file="$repo_root/s2t-role/files/s2t.env"
flake_file="$repo_root/s2t-role/files/flake.nix"

# Runtime tests provide explicit env and should not import host-level user/system
# overrides unless the test explicitly verifies env autoload behavior.
export S2T_AUTOLOAD_ENV_FILES=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  if ! rg -n --quiet -- "$pattern" "$file"; then
    fail "Expected pattern '$pattern' in $file"
  fi
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if rg -n --quiet -- "$pattern" "$file"; then
    fail "Unexpected pattern '$pattern' in $file"
  fi
}

assert_number_less_than() {
  local left="$1"
  local right="$2"
  local label="$3"
  if [ "$left" -ge "$right" ]; then
    fail "$label expected $left < $right"
  fi
}

write_fake_pw_record() {
  local fakebin="$1"
  cat >"$fakebin/pw-record" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${@: -1}"
mkdir -p "$(dirname "$out")"
: > "$out"
printf '1234123412341234123412341234123412341234123412341234123412341234' >>"$out"
trap 'exit 0' TERM INT
while true; do
  printf '1234' >>"$out"
  sleep 0.02
done
EOF
  chmod +x "$fakebin/pw-record"
}

write_fake_pw_record_capture_args() {
  local fakebin="$1"
  cat >"$fakebin/pw-record" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_PW_RECORD_ARGS_FILE:?}"
printf '%s\n' "$@" >"$FAKE_PW_RECORD_ARGS_FILE"
out="${@: -1}"
mkdir -p "$(dirname "$out")"
: > "$out"
printf '1234123412341234123412341234123412341234123412341234123412341234' >>"$out"
trap 'exit 0' TERM INT
while true; do
  printf '1234' >>"$out"
  sleep 0.02
done
EOF
  chmod +x "$fakebin/pw-record"
}

write_fake_pw_record_delayed_payload_on_term() {
  local fakebin="$1"
  cat >"$fakebin/pw-record" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${@: -1}"
mkdir -p "$(dirname "$out")"
dd if=/dev/zero of="$out" bs=44 count=1 status=none
exec 3>>"$out"
trap '(sleep 0.18; dd if=/dev/zero bs=6400 count=1 status=none >&3 || true; exec 3>&-) & exit 0' TERM INT
while true; do
  sleep 0.2
done
EOF
  chmod +x "$fakebin/pw-record"
}

write_fake_curl() {
  local fakebin="$1"
  cat >"$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
file_path=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-F" ]; then
    shift
    arg="${1:-}"
    case "$arg" in
      file=@*)
        file_path="${arg#file=@}"
        file_path="${file_path%%;*}"
        ;;
    esac
  fi
  shift || true
done
if [ -n "$file_path" ] && [ ! -f "$file_path" ]; then
  echo "input file not found '$file_path'" >&2
  exit 26
fi
sleep "${FAKE_CURL_DELAY_SEC:-0}"
printf '{"text":"%s"}\n' "${FAKE_CURL_TEXT:-ok}"
EOF
  chmod +x "$fakebin/curl"
}

write_fake_curl_capture_args() {
  local fakebin="$1"
  cat >"$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_CURL_ARGS_FILE:?}"
printf '%s\n' "$@" >"$FAKE_CURL_ARGS_FILE"
printf '{"text":"ok"}\n'
EOF
  chmod +x "$fakebin/curl"
}

write_fake_jq() {
  local fakebin="$1"
  cat >"$fakebin/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input="$(cat)"
printf '%s\n' "$input" | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
EOF
  chmod +x "$fakebin/jq"
}

write_fake_xdotool() {
  local fakebin="$1"
  cat >"$fakebin/xdotool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$fakebin/xdotool"
}

write_fake_xclip() {
  local fakebin="$1"
  cat >"$fakebin/xclip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null || true
# Emulate xclip behavior that leaves a clipboard owner process alive.
sleep 30 &
disown || true
exit 0
EOF
  chmod +x "$fakebin/xclip"
}

write_fake_xclip_read_fail() {
  local fakebin="$1"
  cat >"$fakebin/xclip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [ "$arg" = "-o" ]; then
    exit 1
  fi
done
if [ -n "${FAKE_XCLIP_WRITE_MARKER:-}" ]; then
  cat >/dev/null || true
  printf 'xclip-write\n' >>"$FAKE_XCLIP_WRITE_MARKER"
else
  cat >/dev/null || true
fi
exit 0
EOF
  chmod +x "$fakebin/xclip"
}

write_fake_xdotool_capture_type() {
  local fakebin="$1"
  cat >"$fakebin/xdotool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "type" ] && [ -n "${FAKE_XDOTOOL_TYPE_MARKER:-}" ]; then
  printf '%s\n' "$*" >>"$FAKE_XDOTOOL_TYPE_MARKER"
fi
exit 0
EOF
  chmod +x "$fakebin/xdotool"
}

write_fake_sox() {
  local fakebin="$1"
  cat >"$fakebin/sox" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--i" ] && [ "${2:-}" = "-D" ]; then
  printf '%s\n' "${FAKE_SOX_DURATION:-1.234000}"
  exit 0
fi
exit 1
EOF
  chmod +x "$fakebin/sox"
}

write_fake_ffmpeg() {
  local fakebin="$1"
  cat >"$fakebin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input=""
output="${@: -1}"
fmt=""
while [ $# -gt 0 ]; do
  if [ "${1:-}" = "-i" ]; then
    shift
    input="${1:-}"
    shift || true
    continue
  fi
  if [ "${1:-}" = "-f" ]; then
    shift
    fmt="${1:-}"
    shift || true
    continue
  fi
  shift || true
done
[ -n "$input" ] || exit 2
[ -n "$output" ] || exit 2
if [[ "$output" == *.tmp ]] && [ "$fmt" != "wav" ]; then
  echo "Invalid argument: output format not specified for temporary file" >&2
  exit 1
fi
mkdir -p "$(dirname "$output")"
cp "$input" "$output"
EOF
  chmod +x "$fakebin/ffmpeg"
}

write_fake_wpctl() {
  local fakebin="$1"
  cat >"$fakebin/wpctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  inspect)
    cat "${FAKE_WPCTL_INSPECT_FILE:-/dev/null}"
    ;;
  status)
    cat "${FAKE_WPCTL_STATUS_FILE:-/dev/null}"
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$fakebin/wpctl"
}

write_fake_pactl_sources() {
  local fakebin="$1"
  cat >"$fakebin/pactl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "list" ] && [ "${2:-}" = "short" ] && [ "${3:-}" = "sources" ]; then
  cat "${FAKE_PACTL_SOURCES_FILE:-/dev/null}"
  exit 0
fi
exit 1
EOF
  chmod +x "$fakebin/pactl"
}

write_fake_arecord_capture_args() {
  local fakebin="$1"
  cat >"$fakebin/arecord" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-l" ]; then
  cat "${FAKE_ARECORD_LIST_FILE:-/dev/null}"
  exit 0
fi
: "${FAKE_ARECORD_ARGS_FILE:?}"
printf '%s\n' "$@" >"$FAKE_ARECORD_ARGS_FILE"
out="${@: -1}"
mkdir -p "$(dirname "$out")"
: >"$out"
printf '1234123412341234123412341234123412341234123412341234123412341234' >>"$out"
trap 'exit 0' TERM INT
while true; do
  printf '1234' >>"$out"
  sleep 0.02
done
EOF
  chmod +x "$fakebin/arecord"
}

write_fake_python_google_v1_empty_v2_retry() {
  local fakebin="$1"
  local real_python="$2"
  cat >"$fakebin/python3" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "-c" ]; then
  code="\${2:-}"
  if [[ "\$code" == *"import google.cloud.speech_v2"* ]]; then
    exit 0
  fi
  exec "$real_python" "\$@"
fi
if [ "\${1:-}" = "-" ]; then
  payload="\$(cat)"
  if [[ "\$payload" == *"import http.client"* ]]; then
    # google(v1): emulate successful empty response
    exit 0
  fi
  if [[ "\$payload" == *"from google.cloud.speech_v2 import SpeechClient"* ]]; then
    printf '%s' "\${FAKE_GOOGLE_V2_TEXT:-v2-retry-text}"
    exit 0
  fi
  exec "$real_python" "\$@" <<<"\$payload"
fi
exec "$real_python" "\$@"
EOF
  chmod +x "$fakebin/python3"
}

write_fake_python_google_v1_delayed_success() {
  local fakebin="$1"
  local real_python="$2"
  cat >"$fakebin/python3" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "-c" ]; then
  code="\${2:-}"
  if [[ "\$code" == *"import google.cloud.speech_v2"* ]]; then
    exit 1
  fi
  exec "$real_python" "\$@"
fi
if [ "\${1:-}" = "-" ]; then
  payload="\$(cat)"
  if [[ "\$payload" == *"import http.client"* ]]; then
    sleep "\${FAKE_GOOGLE_V1_DELAY_SEC:-0}"
    printf '%s' "\${FAKE_GOOGLE_V1_TEXT:-google-delayed-ok}"
    exit 0
  fi
  exec "$real_python" "\$@" <<<"\$payload"
fi
exec "$real_python" "\$@"
EOF
  chmod +x "$fakebin/python3"
}

write_fake_python_google_v1_empty_until_no_alt() {
  local fakebin="$1"
  local real_python="$2"
  cat >"$fakebin/python3" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "-c" ]; then
  code="\${2:-}"
  if [[ "\$code" == *"import google.cloud.speech_v2"* ]]; then
    exit 1
  fi
  exec "$real_python" "\$@"
fi
if [ "\${1:-}" = "-" ]; then
  payload="\$(cat)"
  if [[ "\$payload" == *"import http.client"* ]]; then
    if [ -n "\${S2T_GOOGLE_ALT_LANGUAGE_CODES:-}" ]; then
      exit 0
    fi
    printf '%s' "\${FAKE_GOOGLE_V1_TEXT:-google-no-alt-ok}"
    exit 0
  fi
  exec "$real_python" "\$@" <<<"\$payload"
fi
exec "$real_python" "\$@"
EOF
  chmod +x "$fakebin/python3"
}

write_fake_python_google_v1_short_until_no_alt() {
  local fakebin="$1"
  local real_python="$2"
  cat >"$fakebin/python3" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "-c" ]; then
  code="\${2:-}"
  if [[ "\$code" == *"import google.cloud.speech_v2"* ]]; then
    exit 1
  fi
  exec "$real_python" "\$@"
fi
if [ "\${1:-}" = "-" ]; then
  payload="\$(cat)"
  if [[ "\$payload" == *"import http.client"* ]]; then
    if [ -n "\${S2T_GOOGLE_ALT_LANGUAGE_CODES:-}" ]; then
      printf '%s' "\${FAKE_GOOGLE_V1_SHORT_TEXT:-ok}"
      exit 0
    fi
    printf '%s' "\${FAKE_GOOGLE_V1_TEXT:-google-short-guard-ok}"
    exit 0
  fi
  exec "$real_python" "\$@" <<<"\$payload"
fi
exec "$real_python" "\$@"
EOF
  chmod +x "$fakebin/python3"
}

write_fake_python_google_v2() {
  local fakebin="$1"
  local real_python="$2"
  cat >"$fakebin/python3" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "-c" ]; then
  code="\${2:-}"
  if [[ "\$code" == *"import google.cloud.speech_v2"* ]]; then
    exit 0
  fi
  exec "$real_python" "\$@"
fi
if [ "\${1:-}" = "-" ]; then
  case "\${S2T_GOOGLE_V2_LANGUAGE_CODES:-}" in
    ru-RU) exit 0 ;;
    en-US) printf 'fallback transcript'; exit 0 ;;
    *) exit 0 ;;
  esac
fi
exec "$real_python" "\$@"
EOF
  chmod +x "$fakebin/python3"
}

write_fake_whisper_cli() {
  local fakebin="$1"
  cat >"$fakebin/whisper-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prefix=""
while [ $# -gt 0 ]; do
  case "$1" in
    -of|--output-file)
      shift
      prefix="${1:-}"
      ;;
  esac
  shift || true
done
[ -n "$prefix" ] || exit 2
printf '%s\n' "${FAKE_WHISPER_TEXT:-whisper output}" > "${prefix}.txt"
printf 'whisper failure marker\n' >&2
exit "${FAKE_WHISPER_RC:-0}"
EOF
  chmod +x "$fakebin/whisper-cli"
}

write_fake_codex_validator() {
  local fakebin="$1"
  cat >"$fakebin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out_file=""
reply="${FAKE_CODEX_REPLY-}"
while [ $# -gt 0 ]; do
  if [ "$1" = "--output-last-message" ]; then
    shift
    out_file="${1:-}"
  fi
  shift || true
done
[ -n "$out_file" ] || exit 2
if [ -z "$reply" ]; then
  reply='{"verdict":"accept","confidence":0.95,"reason":"looks consistent"}'
fi
printf '%s\n' "$reply" >"$out_file"
exit "${FAKE_CODEX_RC:-0}"
EOF
  chmod +x "$fakebin/codex"
}

test_ansible_sudo_precheck() {
  assert_contains "$tasks_main" "Check passwordless sudo availability"
  assert_contains "$tasks_main" "sudo -n true"
}

test_target_user_resolution() {
  assert_contains "$tasks_main" "Resolve S2T target user"
  assert_contains "$tasks_main" "ansible_env.SUDO_USER"
  assert_contains "$tasks_main" "s2t_target_user \\| default\\(''\\)"
  assert_contains "$repo_root/s2t-role/defaults/main.yml" "^s2t_target_user: \"\"$"
  assert_contains "$tasks_main" "s2t_target_home"
  assert_contains "$tasks_main" "s2t_target_uid"
}

test_linger_autostart_setup() {
  assert_contains "$tasks_main" "Enable lingering for target user"
  assert_contains "$tasks_main" "loginctl enable-linger"
  assert_contains "$tasks_main" "Disable lingering for target user"
  assert_contains "$tasks_main" "loginctl disable-linger"
  assert_contains "$repo_root/s2t-role/defaults/main.yml" "^s2t_enable_linger: false"
}

test_keyd_menu_hotkey_mapping() {
  assert_contains "$keyd_conf" '^rightalt = f24$'
  assert_not_contains "$keyd_conf" '^compose = f24$'
  assert_not_contains "$keyd_conf" '^menu = f24$'
  assert_not_contains "$keyd_conf" '^rightmeta = f24$'
}

test_user_env_is_authoritative() {
  assert_contains "$tasks_main" "Install per-user override env file"
  assert_contains "$tasks_main" 'template:'
  assert_contains "$tasks_main" 'src: "s2t.user.env.default.j2"'
  assert_contains "$tasks_main" "force: \"\\{\\{ s2t_user_env_force \\}\\}\""
  assert_contains "$repo_root/s2t-role/defaults/main.yml" "^s2t_user_env_force: true"
}

test_user_env_change_restarts_monitor() {
  assert_contains "$handlers_main" "Restart S2T Monitor \\(User\\)"
  if ! awk '
    BEGIN { in_block=0; found=0 }
    /^- name: Install per-user override env file/ { in_block=1; next }
    /^- name:/ && in_block { in_block=0 }
    in_block && /Restart S2T Monitor \(User\)/ { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$tasks_main"; then
    fail "Install per-user override env file must notify Restart S2T Monitor (User)"
  fi
}

test_model_download_best_effort() {
  assert_contains "$tasks_main" "Download default model \\(user, best effort\\)"
  assert_contains "$tasks_main" "s2t_model_download_retries"
  assert_contains "$tasks_main" "s2t_model_download_timeout"
  assert_contains "$tasks_main" "s2t_model_download_strict"
}

test_paste_fallback_default() {
  assert_contains "$controller" 'S2T_PASTE_KEYS_FALLBACK="\$\{S2T_PASTE_KEYS_FALLBACK:-shift\+insert\}"'
}

test_max_record_limit_support() {
  assert_contains "$controller" 'S2T_MAX_RECORD_SECONDS="\$\{S2T_MAX_RECORD_SECONDS:-0\}"'
  assert_contains "$controller" 'timeout --signal=TERM "\$\{S2T_MAX_RECORD_SECONDS\}s"'
}

test_capture_fail_fallback_controls_present() {
  assert_contains "$controller" 'CAPTURE_FAIL_FILE="\$RUNTIME_DIR/capture_fail.count"'
  assert_contains "$controller" 'CAPTURE_DEFAULT_UNTIL_FILE="\$RUNTIME_DIR/capture_default_until_ms"'
  assert_contains "$controller" 'S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD="\$\{S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD:-2\}"'
  assert_contains "$controller" 'S2T_CAPTURE_DEFAULT_COOLDOWN_SEC="\$\{S2T_CAPTURE_DEFAULT_COOLDOWN_SEC:-300\}"'
  assert_contains "$controller" 'capture_fail_count\(\)'
  assert_contains "$controller" 'increment_capture_fail_count\(\)'
  assert_contains "$controller" 'reset_capture_fail_count\(\)'
  assert_contains "$controller" 'capture_default_mode_active\(\)'
  assert_contains "$controller" 'forcing pw-record target=default'
}

test_network_only_controls_present() {
  assert_contains "$controller" 'S2T_NETWORK_ONLY="\$\{S2T_NETWORK_ONLY:-0\}"'
  assert_contains "$controller" 'S2T_MAX_RESPONSE_SECONDS="\$\{S2T_MAX_RESPONSE_SECONDS:-0\}"'
  assert_contains "$controller" 'S2T_LOG_VERBOSE="\$\{S2T_LOG_VERBOSE:-0\}"'
  assert_contains "$controller" 'S2T_PRESERVE_CLIPBOARD_STRICT="\$\{S2T_PRESERVE_CLIPBOARD_STRICT:-0\}"'
  assert_contains "$controller" 'S2T_AVOID_LOOPBACK_SOURCE="\$\{S2T_AVOID_LOOPBACK_SOURCE:-1\}"'
  assert_contains "$controller" 'S2T_AUDIO_TARGET_EXCLUDE_RE="\$\{S2T_AUDIO_TARGET_EXCLUDE_RE:-snd_aloop\|loopback\|monitor\}"'
  assert_contains "$controller" 'S2T_GOOGLE_CONNECT_TIMEOUT_SEC="\$\{S2T_GOOGLE_CONNECT_TIMEOUT_SEC:-3\}"'
  assert_contains "$controller" 'S2T_SKIP_LOCAL_FALLBACK_ON_TIMEOUT="\$\{S2T_SKIP_LOCAL_FALLBACK_ON_TIMEOUT:-1\}"'
  assert_contains "$controller" 'S2T_GOOGLE_V2_ON_EMPTY="\$\{S2T_GOOGLE_V2_ON_EMPTY:-1\}"'
  assert_contains "$controller" 'S2T_GOOGLE_DYNAMIC_TIMEOUT="\$\{S2T_GOOGLE_DYNAMIC_TIMEOUT:-1\}"'
  assert_contains "$controller" 'S2T_GOOGLE_TIMEOUT_PER_AUDIO_SEC="\$\{S2T_GOOGLE_TIMEOUT_PER_AUDIO_SEC:-0.25\}"'
  assert_contains "$controller" 'S2T_GOOGLE_TIMEOUT_MAX_SEC="\$\{S2T_GOOGLE_TIMEOUT_MAX_SEC:-20\}"'
  assert_contains "$controller" 'S2T_ENABLE_ALSA_CAPTURE_FALLBACK="\$\{S2T_ENABLE_ALSA_CAPTURE_FALLBACK:-1\}"'
  assert_contains "$controller" 'S2T_TRANSCRIBE_STALE_SEC="\$\{S2T_TRANSCRIBE_STALE_SEC:-20\}"'
  assert_contains "$controller" 'S2T_TRANSCRIBE_ACQUIRE_RETRY_MS="\$\{S2T_TRANSCRIBE_ACQUIRE_RETRY_MS:-1200\}"'
  assert_contains "$controller" 'transcribe: stale lock owner'
  assert_contains "$controller" 'network-only enabled, skipping local fallback'
}

test_google_dynamic_short_model_controls_present() {
  assert_contains "$controller" 'S2T_GOOGLE_SHORT_MODEL="\$\{S2T_GOOGLE_SHORT_MODEL:-latest_short\}"'
  assert_contains "$controller" 'S2T_GOOGLE_SHORT_AUDIO_SEC="\$\{S2T_GOOGLE_SHORT_AUDIO_SEC:-4\}"'
  assert_contains "$controller" 'S2T_GOOGLE_ALT_LANGUAGE_CODES="\$\{S2T_GOOGLE_ALT_LANGUAGE_CODES-en-US\}"'
  assert_contains "$controller" 'S2T_GOOGLE_RETRY_ON_EMPTY="\$\{S2T_GOOGLE_RETRY_ON_EMPTY:-0\}"'
  assert_contains "$controller" 'S2T_GOOGLE_RETRY_ON_SHORT="\$\{S2T_GOOGLE_RETRY_ON_SHORT:-1\}"'
  assert_contains "$controller" 'S2T_GOOGLE_SHORT_RESULT_AUDIO_SEC="\$\{S2T_GOOGLE_SHORT_RESULT_AUDIO_SEC:-4\}"'
  assert_contains "$controller" 'S2T_GOOGLE_MIN_CHARS_PER_AUDIO_SEC="\$\{S2T_GOOGLE_MIN_CHARS_PER_AUDIO_SEC:-3.5\}"'
  assert_contains "$controller" 'google_request_model='
  assert_contains "$controller" 'google_retry_model='
  assert_contains "$controller" 'google empty with .*; retry ->'
  assert_contains "$controller" 'retry same model without alt languages'
  assert_contains "$controller" 'timing: google_retry_noalt_ms='
  assert_contains "$controller" 'timing: google_retry_ms='
  assert_contains "$controller" 'S2T_GOOGLE_MODEL="\$google_request_model" \\'
  assert_contains "$controller" 'S2T_GOOGLE_REQUEST_TIMEOUT_SEC="\$google_timeout_for_call"'
  assert_contains "$controller" 'transcribe_with_google\)'
}

test_local_provider_disables_server_timeout() {
  assert_contains "$controller" 'local server_timeout_sec="\$S2T_SERVER_TIMEOUT_SEC"'
  assert_contains "$controller" 'if \[ "\$S2T_ASR_PROVIDER" = "local" \]; then'
  assert_contains "$controller" 'server_timeout_sec=0'
}

test_monitor_controller_override_support() {
  assert_contains "$monitor_script" 'CONTROLLER_ENV_VAR = "S2T_CONTROLLER"'
  assert_contains "$monitor_script" 'controller_override = os.environ.get\(CONTROLLER_ENV_VAR, ""\)\.strip\(\)'
  assert_contains "$monitor_unit" '^Environment=S2T_MONITOR_LOCK_PATH=/tmp/s2t-monitor-global.lock$'
  assert_contains "$monitor_unit" '^Environment=S2T_CONTROLLER=/etc/s2t/scripts/controller.sh$'
  assert_contains "$monitor_unit" '^Restart=on-failure$'
  assert_contains "$monitor_script" 'No graphical session variables \(DISPLAY/WAYLAND_DISPLAY\); exiting monitor\.'
}

test_monitor_global_lock_support() {
  assert_contains "$monitor_script" '^import fcntl$'
  assert_contains "$monitor_script" 'GLOBAL_LOCK_ENV_VAR = "S2T_MONITOR_LOCK_PATH"'
  assert_contains "$monitor_script" 'GLOBAL_LOCK_DEFAULT = "/tmp/s2t-monitor-global.lock"'
  assert_contains "$monitor_script" 'def acquire_global_lock\(\):'
  assert_contains "$monitor_script" 'except PermissionError:'
  assert_contains "$monitor_script" 'lock_file = open\(lock_path, "r"\)'
  assert_contains "$monitor_script" 'fcntl\.flock\(lock_file\.fileno\(\), fcntl\.LOCK_EX \| fcntl\.LOCK_NB\)'
}

test_monitor_hotkey_resilience_controls_present() {
  assert_contains "$monitor_script" 'KEY_RIGHTALT = evdev\.ecodes\.KEY_RIGHTALT'
  assert_contains "$monitor_script" 'KEY_MENU = evdev\.ecodes\.KEY_MENU'
  assert_contains "$monitor_script" 'KEY_PRIMARY_ENV_VAR = "S2T_MONITOR_PRIMARY_KEY"'
  assert_contains "$monitor_script" 'KEY_FALLBACK_ENV_VAR = "S2T_MONITOR_FALLBACK_KEYS"'
  assert_contains "$monitor_script" 'IDLE_REOPEN_ENV_VAR = "S2T_MONITOR_IDLE_REOPEN_SEC"'
  assert_contains "$monitor_script" 'No hotkey events for'
  assert_contains "$monitor_script" 'reopening input device'
  assert_contains "$monitor_unit" '^Environment=S2T_MONITOR_PRIMARY_KEY=F24$'
  assert_contains "$monitor_unit" '^Environment=S2T_MONITOR_FALLBACK_KEYS=RIGHTALT,MENU$'
  assert_contains "$monitor_unit" '^Environment=S2T_MONITOR_IDLE_REOPEN_SEC=90$'
}

test_systemd_cgroup_limits_present() {
  assert_contains "$whisper_unit" '^Nice=10'
  assert_contains "$whisper_unit" '^CPUQuota=500%'
  assert_contains "$whisper_unit" '^CPUWeight=25'
  assert_contains "$whisper_unit" '^MemoryMax=3G'
  assert_contains "$whisper_unit" '^TasksMax=64'
  assert_contains "$monitor_unit" '^CPUQuota=50%'
  assert_contains "$monitor_unit" '^MemoryMax=256M'
  assert_contains "$monitor_unit" '^TasksMax=32'
}

test_dataset_etl_service_setup_present() {
  assert_contains "$dataset_etl_unit" '^ExecStart=/etc/s2t/result/bin/python3 /etc/s2t/scripts/dataset_etl_daemon.py$'
  assert_contains "$dataset_etl_unit" '^CPUQuota=75%$'
  assert_contains "$dataset_etl_unit" '^MemoryMax=512M$'
  assert_contains "$dataset_etl_unit" '^TasksMax=32$'
  assert_contains "$tasks_main" 'Copy dataset etl unit'
  assert_contains "$tasks_main" 'Enable s2t-dataset-etl user service'
  assert_contains "$tasks_main" 's2t-whisper s2t-monitor s2t-dataset-etl'
  assert_contains "$tasks_main" '- build_dataset.py'
  assert_contains "$tasks_main" '- dataset_etl_daemon.py'
  assert_contains "$uninstall_playbook" 'Stop and disable s2t-dataset-etl user service'
  assert_contains "$uninstall_playbook" 'Remove s2t-dataset-etl unit'
  assert_contains "$dataset_etl_script" 'Asynchronous dataset ETL daemon for S2T correction jobs.'
  assert_contains "$flake_file" 'ffmpeg'
}

test_codex_bridge_service_setup_present() {
  assert_contains "$codex_bridge_unit" '^ExecStart=/etc/s2t/result/bin/python3 /etc/s2t/scripts/codex_correction_bridge.py$'
  assert_contains "$codex_bridge_unit" '^CPUQuota=20%$'
  assert_contains "$codex_bridge_unit" '^MemoryMax=256M$'
  assert_contains "$codex_bridge_unit" '^TasksMax=32$'
  assert_contains "$tasks_main" 'Copy codex bridge unit'
  assert_contains "$tasks_main" 'Enable s2t-codex-bridge user service'
  assert_contains "$tasks_main" '- codex_correction_bridge.py'
  assert_contains "$handlers_main" 'Restart S2T Codex Bridge \(User\)'
  assert_contains "$uninstall_playbook" 'Stop and disable s2t-codex-bridge user service'
  assert_contains "$uninstall_playbook" 'Remove s2t-codex-bridge unit'
  assert_contains "$codex_bridge_script" 'Bridge Codex user chat messages to s2t-controller submit-correction'
  assert_contains "$codex_bridge_script" 'correction_rejection_reason\('
  assert_contains "$codex_bridge_script" 'diagnostic/log-like message'
  assert_contains "$codex_bridge_script" 'contains backticks/code fragment'
  assert_contains "$user_env_file" '^S2T_CODEX_BRIDGE_ENABLED=1$'
  assert_contains "$user_env_file" '^S2T_CODEX_BRIDGE_WINDOW_SEC=30$'
  assert_contains "$user_env_file" '^S2T_CODEX_BRIDGE_MAX_PENDING_AGE_SEC=600$'
  assert_contains "$user_env_file" '^S2T_CODEX_BRIDGE_MIN_SHARED_TOKENS=2$'
  assert_contains "$user_env_file" '^S2T_CODEX_BRIDGE_MIN_TOKEN_OVERLAP=0.2$'
  assert_contains "$user_env_file" '^S2T_CODEX_BRIDGE_BACKFILL_EXISTING=0$'
  assert_contains "$system_env_file" '^S2T_CODEX_BRIDGE_ENABLED=1$'
  assert_contains "$system_env_file" '^S2T_CODEX_BRIDGE_MAX_PENDING_AGE_SEC=600$'
  assert_contains "$system_env_file" '^S2T_CODEX_BRIDGE_BACKFILL_EXISTING=0$'
}

test_rabbitmq_queue_setup_present() {
  assert_contains "$flake_file" 'podman'
  assert_contains "$flake_file" 'shadow'
  assert_contains "$flake_file" 'p.pika'
  assert_contains "$controller" 'S2T_QUEUE_BACKEND="\$\{S2T_QUEUE_BACKEND:-file\}"'
  assert_contains "$controller" 'S2T_RABBITMQ_PUBLISHER="\$\{S2T_RABBITMQ_PUBLISHER:-/etc/s2t/scripts/rabbitmq_publish.py\}"'
  assert_contains "$controller" 'enqueue_dataset_job_rabbit\(\)'
  assert_contains "$controller" 'backend_fallback=file'
  assert_contains "$rabbitmq_publish_script" 'Publish S2T dataset queue jobs to RabbitMQ'
  assert_contains "$rabbitmq_publish_script" 'channel.confirm_delivery\(\)'
  assert_contains "$rabbitmq_drain_script" 'Drain RabbitMQ S2T jobs into local file queue'
  assert_contains "$rabbitmq_drain_script" 'queue backend is'
  assert_contains "$rabbitmq_unit" '^Environment=PATH=/etc/s2t/result/bin:'
  assert_contains "$rabbitmq_unit" '^Environment=PODMAN_BIN_DEFAULT=/etc/s2t/result/bin/podman$'
  assert_contains "$rabbitmq_unit" '^EnvironmentFile=/etc/s2t/s2t.env$'
  assert_contains "$rabbitmq_unit" '^ExecCondition=/bin/bash -lc '
  assert_contains "$rabbitmq_unit" 'newuidmap/newgidmap must be setuid root'
  assert_contains "$rabbitmq_unit" 'S2T_PODMAN_BIN'
  assert_contains "$rabbitmq_unit" 'S2T_RABBITMQ_IMAGE'
  assert_contains "$rabbitmq_unit" '^ExecStart=/bin/bash -lc '
  assert_contains "$rabbitmq_unit" '^ExecStop=/bin/bash -lc '
  assert_contains "$rabbitmq_unit" '^Restart=on-failure$'
  assert_contains "$rabbitmq_unit" '^CPUQuota=150%$'
  assert_contains "$rabbitmq_unit" '^MemoryMax=500M$'
  assert_contains "$rabbitmq_unit" '^TasksMax=256$'
  assert_contains "$rabbitmq_unit" '--memory=500m'
  assert_contains "$rabbitmq_drain_unit" '^ExecStart=/etc/s2t/result/bin/python3 /etc/s2t/scripts/rabbitmq_drain_daemon.py$'
  assert_contains "$rabbitmq_drain_unit" '^Requires=s2t-rabbitmq.service$'
  assert_contains "$rabbitmq_drain_unit" '^BindsTo=s2t-rabbitmq.service$'
  assert_contains "$rabbitmq_drain_unit" '^ExecCondition=/bin/bash -lc '
  assert_contains "$rabbitmq_drain_unit" '^CPUQuota=25%$'
  assert_contains "$rabbitmq_drain_unit" '^MemoryMax=256M$'
  assert_contains "$s2t_target_unit" '^Description=S2T Stack \(User\)$'
  assert_contains "$s2t_target_unit" 's2t-rabbitmq.service'
  assert_contains "$monitor_unit" '^PartOf=s2t.target$'
  assert_contains "$whisper_unit" '^PartOf=s2t.target$'
  assert_contains "$dataset_etl_unit" '^PartOf=s2t.target$'
  assert_contains "$codex_bridge_unit" '^PartOf=s2t-monitor.service s2t.target$'
  assert_contains "$rabbitmq_quadlet" '^Image=docker.io/library/rabbitmq:3.13-management$'
  assert_contains "$rabbitmq_quadlet" '^PublishPort=127.0.0.1:5672:5672$'
  assert_contains "$tasks_main" 'Copy rabbitmq unit'
  assert_contains "$tasks_main" 'Copy rabbitmq drain unit'
  assert_contains "$tasks_main" 'Copy s2t stack target unit'
  assert_contains "$tasks_main" 'Copy rabbitmq Quadlet container definition'
  assert_contains "$tasks_main" 'Enable s2t-rabbitmq user service'
  assert_contains "$tasks_main" 'Enable s2t-rabbitmq-drain user service'
  assert_contains "$tasks_main" 'Enable s2t target unit'
  assert_contains "$tasks_main" 'Install uidmap helpers for rootless podman \(Debian family\)'
  assert_contains "$tasks_main" 'Check rootless podman uidmap helper readiness'
  assert_contains "$tasks_main" 'podman-user-generator'
  assert_contains "$handlers_main" 'Restart S2T RabbitMQ Drain \(User\)'
  assert_contains "$uninstall_playbook" 'Stop and disable s2t-rabbitmq user service'
  assert_contains "$uninstall_playbook" 'Stop and disable s2t-rabbitmq-drain user service'
  assert_contains "$uninstall_playbook" 'Remove s2t-rabbitmq unit'
  assert_contains "$uninstall_playbook" 'Remove s2t-rabbitmq-drain unit'
  assert_contains "$uninstall_playbook" 'Remove rabbitmq Quadlet definition'
  assert_contains "$user_env_file" '^S2T_QUEUE_BACKEND=rabbitmq$'
  assert_contains "$user_env_file" '^S2T_RABBITMQ_URL=amqp://s2t:s2t@127.0.0.1:5672/%2F$'
  assert_contains "$user_env_file" '^S2T_RABBITMQ_QUEUE=s2t.dataset.jobs$'
  assert_contains "$user_env_file" '^S2T_RABBITMQ_PUBLISHER=/etc/s2t/scripts/rabbitmq_publish.py$'
  assert_contains "$user_env_file" '^S2T_PODMAN_BIN=$'
  assert_contains "$user_env_file" '^S2T_RABBITMQ_IMAGE=docker.io/library/rabbitmq:3.13-management$'
  assert_contains "$system_env_file" '^S2T_QUEUE_BACKEND=rabbitmq$'
  assert_contains "$system_env_file" '^S2T_RABBITMQ_QUEUE=s2t.dataset.jobs$'
  assert_contains "$system_env_file" '^S2T_PODMAN_BIN=$'
  assert_contains "$system_env_file" '^S2T_RABBITMQ_IMAGE=docker.io/library/rabbitmq:3.13-management$'
}

test_dataset_etl_llm_validation_controls_present() {
  assert_contains "$dataset_etl_script" 'S2T_DATASET_VALIDATE_PAIRS'
  assert_contains "$dataset_etl_script" 'S2T_DATASET_VALIDATE_WITH_LLM'
  assert_contains "$dataset_etl_script" 'S2T_DATASET_LLM_VALIDATOR_CMD'
  assert_contains "$dataset_etl_script" 'S2T_DATASET_LLM_REQUIRED'
  assert_contains "$dataset_etl_script" 'S2T_DATASET_ASR_PROBE_ENABLED'
  assert_contains "$dataset_etl_script" 'run_llm_validation\('
  assert_contains "$dataset_etl_script" 'probe_audio_transcript\('
  assert_contains "$dataset_etl_script" 'split_jobs_by_validation\('
  assert_contains "$dataset_etl_script" 'llm validation failed'
  assert_contains "$user_env_file" '^S2T_DATASET_VALIDATE_WITH_LLM=0$'
  assert_contains "$user_env_file" '^S2T_DATASET_LLM_REQUIRED=0$'
  assert_contains "$user_env_file" '^S2T_DATASET_LLM_TIMEOUT_SEC=45$'
  assert_contains "$user_env_file" '^S2T_DATASET_QUARANTINE_MODE=copy$'
  assert_contains "$user_env_file" '^S2T_DATASET_CLUSTER_ON_SUBMIT=1$'
  assert_contains "$user_env_file" '^S2T_DATASET_MULTI_SEGMENT_GAP_SEC=20$'
  assert_contains "$user_env_file" '^S2T_DATASET_MULTI_SEGMENT_MAX_COUNT=6$'
  assert_contains "$user_env_file" '^S2T_DATASET_LOG_VERBOSE=1$'
  assert_contains "$user_env_file" '^S2T_DATASET_LOG_MAX_BYTES=2097152$'
  assert_contains "$user_env_file" '^S2T_DATASET_LOG_KEEP=5$'
  assert_contains "$system_env_file" '^S2T_DATASET_VALIDATE_WITH_LLM=0$'
  assert_contains "$system_env_file" '^S2T_DATASET_QUARANTINE_MODE=copy$'
}

test_dataset_collection_controls_present() {
  assert_contains "$controller" 'LAST_SAMPLE_META_FILE="\$RUNTIME_DIR/last_sample.meta"'
  assert_contains "$controller" 'S2T_AUTOLOAD_ENV_FILES="\$\{S2T_AUTOLOAD_ENV_FILES:-1\}"'
  assert_contains "$controller" 'load_env_file_if_exists "/etc/s2t/s2t.env"'
  assert_contains "$controller" 'load_env_file_if_exists "\$HOME/.config/s2t/s2t.env"'
  assert_contains "$controller" 'S2T_DATASET_ROOT="\$\{S2T_DATASET_ROOT:-\$\{XDG_DATA_HOME:-\$HOME/.local/share\}/s2t/dataset\}"'
  assert_contains "$controller" 'S2T_DATASET_PENDING_DIR="\$\{S2T_DATASET_PENDING_DIR:-\$\{S2T_DATASET_ROOT\}/pending\}"'
  assert_contains "$controller" 'S2T_DATASET_ENQUEUE_CORRECTION="\$\{S2T_DATASET_ENQUEUE_CORRECTION:-1\}"'
  assert_contains "$controller" 'S2T_DATASET_AUTO_SUBMIT_RAW="\$\{S2T_DATASET_AUTO_SUBMIT_RAW:-0\}"'
  assert_contains "$controller" 'S2T_DATASET_CLUSTER_ON_SUBMIT="\$\{S2T_DATASET_CLUSTER_ON_SUBMIT:-1\}"'
  assert_contains "$controller" 'S2T_DATASET_MULTI_SEGMENT_GAP_SEC="\$\{S2T_DATASET_MULTI_SEGMENT_GAP_SEC:-20\}"'
  assert_contains "$controller" 'S2T_DATASET_MULTI_SEGMENT_MAX_COUNT="\$\{S2T_DATASET_MULTI_SEGMENT_MAX_COUNT:-6\}"'
  assert_contains "$controller" 'S2T_QUEUE_BACKEND="\$\{S2T_QUEUE_BACKEND:-file\}"'
  assert_contains "$controller" 'S2T_RABBITMQ_PUBLISHER="\$\{S2T_RABBITMQ_PUBLISHER:-/etc/s2t/scripts/rabbitmq_publish.py\}"'
  assert_contains "$controller" 'dataset: staged pending sample id=\$sample_id \(awaiting submit-correction\)'
  assert_contains "$controller" 'record_training_sample\(\)'
  assert_contains "$controller" 'pending_sample_ids_for_submit\(\)'
  assert_contains "$controller" 'submit_correction\(\)'
  assert_contains "$controller" 'submit-correction'
  assert_contains "$user_env_file" '^S2T_DATASET_ROOT='
  assert_contains "$user_env_file" '^S2T_DATASET_PENDING_DIR='
  assert_contains "$user_env_file" '^S2T_DATASET_ENQUEUE_CORRECTION=1$'
  assert_contains "$user_env_file" '^S2T_DATASET_AUTO_SUBMIT_RAW=0$'
  assert_contains "$user_env_file" '^S2T_QUEUE_BACKEND=rabbitmq$'
  assert_contains "$system_env_file" '^S2T_DATASET_ENQUEUE_CORRECTION=1$'
  assert_contains "$system_env_file" '^S2T_DATASET_PENDING_DIR=$'
  assert_contains "$system_env_file" '^S2T_DATASET_AUTO_SUBMIT_RAW=0$'
  assert_contains "$system_env_file" '^S2T_QUEUE_BACKEND=rabbitmq$'
}

test_model_path_fallback_guards_present() {
  assert_contains "$controller" 'resolve_model_path_for_current_user\(\)'
  assert_contains "$controller" "model path '\\\$requested' is not writable/readable; falling back to"
  assert_contains "$whisper_server_script" 'resolve_model_path_for_current_user\(\)'
  assert_contains "$whisper_server_script" "model path '\\\$requested' is not writable/readable; falling back to"
}

test_user_env_long_dictation_profile() {
  assert_contains "$user_env_file" '^S2T_MODEL_PATH=$'
  assert_contains "$user_env_file" '^S2T_MODEL_URL=$'
  assert_contains "$user_env_file" '^S2T_GOOGLE_MODEL=latest_long$'
  assert_contains "$user_env_file" '^S2T_GOOGLE_SHORT_MODEL=latest_long$'
  assert_contains "$user_env_file" '^S2T_GOOGLE_CONNECT_TIMEOUT_SEC=3$'
  assert_contains "$user_env_file" '^S2T_GOOGLE_TIMEOUT_SEC=5$'
  assert_contains "$user_env_file" '^S2T_GOOGLE_SHORT_AUDIO_SEC=4$'
  assert_contains "$user_env_file" '^S2T_GOOGLE_RETRY_ON_EMPTY=1$'
  assert_contains "$user_env_file" '^S2T_GOOGLE_RETRY_ON_SHORT=1$'
  assert_contains "$user_env_file" '^S2T_GOOGLE_SHORT_RESULT_AUDIO_SEC=4$'
  assert_contains "$user_env_file" '^S2T_GOOGLE_MIN_CHARS_PER_AUDIO_SEC=3.5$'
  assert_contains "$user_env_file" '^S2T_GOOGLE_V2_TIMEOUT_SEC=5$'
  assert_contains "$user_env_file" '^S2T_GOOGLE_V2_ON_EMPTY=1$'
  assert_contains "$user_env_file" '^S2T_SERVER_TIMEOUT_SEC=4$'
  assert_contains "$user_env_file" '^S2T_SKIP_LOCAL_FALLBACK_ON_TIMEOUT=1$'
  assert_contains "$user_env_file" '^S2T_MAX_RESPONSE_SECONDS=5$'
  assert_contains "$user_env_file" '^S2T_TRANSCRIBE_STALE_SEC=8$'
  assert_contains "$user_env_file" '^S2T_TRANSCRIBE_ACQUIRE_RETRY_MS=1500$'
  assert_contains "$user_env_file" '^S2T_AUDIO_TARGET_EXCLUDE_RE="snd_aloop\|loopback\|monitor"$'
  assert_contains "$user_env_file" '^S2T_ENABLE_ALSA_CAPTURE_FALLBACK=1$'
  assert_contains "$user_env_file" '^S2T_DATASET_ROOT=\{\{ s2t_target_home \}\}/.local/share/s2t/dataset$'
  assert_contains "$user_env_file" '^S2T_DATASET_ETL_AUTORUN=1$'
  assert_contains "$user_env_file" '^S2T_DATASET_JOBS=4$'
  assert_contains "$user_env_file" '^S2T_DATASET_VALIDATE_PAIRS=1$'
  assert_contains "$user_env_file" '^S2T_DATASET_VALIDATE_WITH_LLM=0$'
  assert_contains "$user_env_file" '^S2T_DATASET_LLM_REQUIRED=0$'
  assert_contains "$user_env_file" '^S2T_DATASET_ASR_PROBE_ENABLED=1$'
  assert_contains "$user_env_file" '^S2T_DATASET_CLUSTER_ON_SUBMIT=1$'
  assert_contains "$user_env_file" '^S2T_DATASET_MULTI_SEGMENT_GAP_SEC=20$'
  assert_contains "$user_env_file" '^S2T_QUEUE_BACKEND=rabbitmq$'
  assert_contains "$user_env_file" '^S2T_RABBITMQ_QUEUE=s2t.dataset.jobs$'
  assert_contains "$user_env_file" '^S2T_WHISPER_SERVER_PORT=.*whisper_port.*$'
  assert_not_contains "$user_env_file" '^S2T_WHISPER_SERVER_PORT=9788$'
}

test_is_positive_int_declared_before_use() {
  local def_line clamp_line
  def_line="$(rg -n '^is_positive_int\(\)' "$controller" | head -n1 | cut -d: -f1)"
  clamp_line="$(rg -n 'if is_positive_int "\$S2T_MAX_RESPONSE_SECONDS"' "$controller" | head -n1 | cut -d: -f1)"
  [ -n "$def_line" ] || fail "is_positive_int() definition not found"
  [ -n "$clamp_line" ] || fail "S2T_MAX_RESPONSE_SECONDS clamp block not found"
  assert_number_less_than "$def_line" "$clamp_line" "is_positive_int declaration order"
}

test_uninstall_target_user_resolution() {
  assert_contains "$uninstall_playbook" "Resolve S2T target user"
  assert_contains "$uninstall_playbook" "s2t_target_user \\| default\\(''\\)"
  assert_contains "$uninstall_playbook" "s2t_target_home"
  assert_contains "$uninstall_playbook" "s2t_target_uid"
}

test_stop_race_lock() {
  local tmp fakebin runbase logfile
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-race-$$-$RANDOM"
  mkdir -p "$runbase"

  write_fake_pw_record "$fakebin"
  write_fake_curl "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_USE_SERVER=1
    export FAKE_CURL_TEXT="race-ok"
    export FAKE_CURL_DELAY_SEC="0.2"
    "$controller" start
    "$controller" stop &
    p1=$!
    sleep 0.03
    "$controller" stop &
    p2=$!
    wait "$p1"
    wait "$p2"
  )

  logfile="$runbase/s2t/s2t.log"
  [ -f "$logfile" ] || fail "log file missing in race test"
  if rg -n "input file not found" "$runbase/s2t" >/dev/null 2>&1; then
    fail "race test hit missing input file"
  fi

  rm -rf "$tmp" "$runbase"
}

test_stop_lock_released_before_clipboard_owner() {
  local tmp fakebin runbase logfile
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-lock-release-$$-$RANDOM"
  mkdir -p "$runbase"

  write_fake_pw_record "$fakebin"
  write_fake_curl "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_xclip "$fakebin"
  write_fake_xdotool "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export XDG_SESSION_TYPE=x11
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=paste
    export S2T_PASTE_KEYS=ctrl+v
    export S2T_USE_SERVER=1
    export FAKE_CURL_TEXT="lock-release-ok"
    "$controller" start
    "$controller" stop
    "$controller" start
    "$controller" stop
  )

  logfile="$runbase/s2t/s2t.log"
  [ -f "$logfile" ] || fail "log file missing in lock-release test"
  if rg -q "another transcribe is in progress" "$logfile"; then
    fail "stop lock persisted due to clipboard owner process"
  fi

  rm -rf "$tmp" "$runbase"
}

test_network_only_skips_local_fallback_runtime() {
  local tmp fakebin runbase logfile transcript_file
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-network-only-$$-$RANDOM"
  mkdir -p "$runbase"

  write_fake_pw_record "$fakebin"
  write_fake_curl "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_ASR_PROVIDER=openai
    export S2T_NETWORK_ONLY=1
    export S2T_USE_SERVER=1
    export S2T_OPENAI_API_KEY=test-key
    export FAKE_CURL_TEXT="   "
    "$controller" start
    sleep 0.25
    "$controller" stop
  )

  logfile="$runbase/s2t/s2t.log"
  transcript_file="$runbase/s2t/last_transcript.txt"
  [ -f "$logfile" ] || fail "log file missing in network-only runtime test"
  rg -q "network-only enabled, skipping local fallback" "$logfile" || fail "network-only skip log missing"
  [ ! -f "$transcript_file" ] || fail "network-only mode unexpectedly produced local transcript"

  rm -rf "$tmp" "$runbase"
}

test_zero_duration_skips_asr_runtime() {
  local tmp fakebin runbase logfile curl_args transcript_file
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-zero-audio-$$-$RANDOM"
  mkdir -p "$runbase"
  curl_args="$tmp/curl_args.txt"

  write_fake_pw_record "$fakebin"
  write_fake_curl_capture_args "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_USE_SERVER=1
    export FAKE_SOX_DURATION=0.000000
    export FAKE_CURL_ARGS_FILE="$curl_args"
    "$controller" start
    sleep 0.25
    "$controller" stop
  )

  logfile="$runbase/s2t/s2t.log"
  transcript_file="$runbase/s2t/last_transcript.txt"
  [ -f "$logfile" ] || fail "log file missing in zero-duration test"
  rg -q "skipping invalid audio capture" "$logfile" || fail "zero-duration skip log missing"
  [ ! -f "$curl_args" ] || fail "ASR request executed despite zero-duration guard"
  [ ! -f "$transcript_file" ] || fail "zero-duration audio unexpectedly produced transcript"

  rm -rf "$tmp" "$runbase"
}

test_wait_for_delayed_wav_payload() {
  local tmp fakebin runbase logfile curl_args transcript_file
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-delayed-wav-$$-$RANDOM"
  mkdir -p "$runbase"
  curl_args="$tmp/curl_args.txt"

  write_fake_pw_record_delayed_payload_on_term "$fakebin"
  write_fake_curl_capture_args "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_USE_SERVER=1
    export FAKE_CURL_ARGS_FILE="$curl_args"
    export FAKE_SOX_DURATION=1.000000
    "$controller" start
    sleep 0.15
    "$controller" stop
  )

  logfile="$runbase/s2t/s2t.log"
  transcript_file="$runbase/s2t/last_transcript.txt"
  [ -f "$logfile" ] || fail "log file missing in delayed wav test"
  [ -f "$curl_args" ] || fail "ASR request was not executed after delayed wav payload"
  [ -f "$transcript_file" ] || fail "missing transcript in delayed wav test"
  rg -q "ok" "$transcript_file" || fail "unexpected transcript content in delayed wav test"

  rm -rf "$tmp" "$runbase"
}

test_drop_when_busy_prevents_transcribe_queue() {
  local tmp fakebin runbase logfile req_count
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-busy-drop-$$-$RANDOM"
  mkdir -p "$runbase"

  write_fake_pw_record "$fakebin"
  write_fake_curl "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_ASR_PROVIDER=openai
    export S2T_OPENAI_API_KEY=test-key
    export S2T_DROP_WHEN_BUSY=1
    export FAKE_CURL_TEXT="busy-test"
    export FAKE_CURL_DELAY_SEC="1.1"
    "$controller" start
    sleep 0.2
    "$controller" stop &
    p1=$!
    sleep 0.1
    "$controller" start
    sleep 0.2
    "$controller" stop &
    p2=$!
    wait "$p1"
    wait "$p2"
  )

  logfile="$runbase/s2t/s2t.log"
  [ -f "$logfile" ] || fail "log file missing in busy-drop test"
  req_count="$(rg -n "asr: openai request" "$logfile" | wc -l)"
  if [ "$req_count" -gt 2 ]; then
    fail "expected bounded openai requests under busy protection, got $req_count"
  fi

  rm -rf "$tmp" "$runbase"
}

test_stale_transcribe_lock_recovery_runtime() {
  local tmp fakebin runbase logfile first_stop_pid
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-stale-lock-$$-$RANDOM"
  mkdir -p "$runbase"

  write_fake_pw_record "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"
  cat >"$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
counter_file="${XDG_RUNTIME_DIR}/curl_call_count"
count="$(cat "$counter_file" 2>/dev/null || echo 0)"
count=$((count + 1))
printf '%s\n' "$count" >"$counter_file"
if [ "$count" -eq 1 ]; then
  sleep 5
fi
printf '{"text":"stale-lock-ok"}\n'
EOF
  chmod +x "$fakebin/curl"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_ASR_PROVIDER=openai
    export S2T_OPENAI_API_KEY=test-key
    export S2T_TRANSCRIBE_STALE_SEC=1
    export S2T_DROP_WHEN_BUSY=1

    "$controller" start
    sleep 0.2
    "$controller" stop &
    first_stop_pid=$!
    sleep 1.3

    "$controller" start
    sleep 0.2
    "$controller" stop

    wait "$first_stop_pid" || true
  )

  logfile="$runbase/s2t/s2t.log"
  [ -f "$logfile" ] || fail "log file missing in stale-lock recovery test"
  rg -q "stale lock owner" "$logfile" || fail "stale lock recovery log missing"
  rg -q "asr: openai ok" "$logfile" || fail "transcribe did not recover after stale lock"

  rm -rf "$tmp" "$runbase"
}

test_preserve_clipboard_no_overwrite_on_snapshot_failure() {
  local tmp fakebin runbase logfile xclip_write_marker xdotool_type_marker
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-clipboard-preserve-$$-$RANDOM"
  mkdir -p "$runbase"
  xclip_write_marker="$tmp/xclip_write.log"
  xdotool_type_marker="$tmp/xdotool_type.log"

  write_fake_pw_record "$fakebin"
  write_fake_curl "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"
  write_fake_xclip_read_fail "$fakebin"
  write_fake_xdotool_capture_type "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export XDG_SESSION_TYPE=x11
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=paste
    export S2T_PRESERVE_CLIPBOARD=1
    export S2T_PRESERVE_CLIPBOARD_STRICT=1
    export S2T_USE_SERVER=1
    export FAKE_CURL_TEXT="clipboard-safe"
    export FAKE_XCLIP_WRITE_MARKER="$xclip_write_marker"
    export FAKE_XDOTOOL_TYPE_MARKER="$xdotool_type_marker"
    "$controller" start
    sleep 0.25
    "$controller" stop
  )

  logfile="$runbase/s2t/s2t.log"
  [ -f "$logfile" ] || fail "log file missing in clipboard preserve test"
  rg -q "preserve_clipboard=1 but cannot snapshot clipboard" "$logfile" || fail "expected clipboard snapshot failure log"
  rg -q "insert: typed fallback to preserve clipboard" "$logfile" || fail "typed preserve fallback log missing"
  [ -f "$xdotool_type_marker" ] || fail "typing fallback was not used"
  [ ! -f "$xclip_write_marker" ] || fail "clipboard was overwritten despite preserve fallback"
  if rg -q "insert: pasted" "$logfile"; then
    fail "paste path used unexpectedly during clipboard-preserve fallback"
  fi

  rm -rf "$tmp" "$runbase"
}

test_preserve_clipboard_non_strict_falls_back_to_paste() {
  local tmp fakebin runbase logfile xclip_write_marker xdotool_type_marker
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-clipboard-nonstrict-$$-$RANDOM"
  mkdir -p "$runbase"
  xclip_write_marker="$tmp/xclip_write.log"
  xdotool_type_marker="$tmp/xdotool_type.log"

  write_fake_pw_record "$fakebin"
  write_fake_curl "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"
  write_fake_xclip_read_fail "$fakebin"
  write_fake_xdotool_capture_type "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export XDG_SESSION_TYPE=x11
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=paste
    export S2T_PRESERVE_CLIPBOARD=1
    export S2T_PRESERVE_CLIPBOARD_STRICT=0
    export S2T_USE_SERVER=1
    export FAKE_CURL_TEXT="clipboard-nonstrict"
    export FAKE_XCLIP_WRITE_MARKER="$xclip_write_marker"
    export FAKE_XDOTOOL_TYPE_MARKER="$xdotool_type_marker"
    "$controller" start
    sleep 0.25
    "$controller" stop
  )

  logfile="$runbase/s2t/s2t.log"
  [ -f "$logfile" ] || fail "log file missing in non-strict clipboard test"
  rg -q "proceeding with paste without clipboard restore" "$logfile" || fail "non-strict clipboard fallback log missing"
  [ -f "$xclip_write_marker" ] || fail "paste path did not write clipboard in non-strict mode"
  [ ! -f "$xdotool_type_marker" ] || fail "typing fallback used unexpectedly in non-strict mode"

  rm -rf "$tmp" "$runbase"
}

test_google_response_timeout_after_send_logic() {
  assert_contains "$controller" 'S2T_GOOGLE_CONNECT_TIMEOUT_SEC="\$\{S2T_GOOGLE_CONNECT_TIMEOUT_SEC:-3\}"'
  assert_contains "$controller" 'S2T_GOOGLE_TIMEOUT_SEC="\$\{S2T_GOOGLE_TIMEOUT_SEC:-0\}"'
  assert_contains "$controller" 'google_timeout_sec="\$\{S2T_GOOGLE_REQUEST_TIMEOUT_SEC:-\$S2T_GOOGLE_TIMEOUT_SEC\}"'
  assert_contains "$controller" 'google_guard_sec="\$\{S2T_GOOGLE_REQUEST_GUARD_SEC:-\$S2T_MAX_RESPONSE_SECONDS\}"'
  assert_contains "$controller" 'google_guard_cmd=\(timeout --signal=TERM "\$\{google_guard_sec\}s"\)'
  assert_contains "$controller" "Timeout semantics:"
  assert_contains "$controller" 'conn.request\("POST", path, body=body, headers=headers\)'
  assert_contains "$controller" 'conn.sock.settimeout\(response_timeout\)'
  assert_contains "$controller" 'except BrokenPipeError:'
  assert_not_contains "$controller" '--max-time "\$S2T_GOOGLE_TIMEOUT_SEC"'
}

test_dataset_builder_pipeline_runtime() {
  local tmp fakebin input_dir output_dir summary train_jsonl test_jsonl all_jsonl errors_jsonl total
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  input_dir="$tmp/input"
  output_dir="$tmp/output"
  mkdir -p "$input_dir/topic-a" "$input_dir/topic-b" "$output_dir"

  write_fake_ffmpeg "$fakebin"

  printf 'RIFFfakewav' >"$input_dir/topic-a/sample1.wav"
  printf '  NixOS   deployment via   ArgoCD   ' >"$input_dir/topic-a/sample1.txt"
  printf 'RIFFfakewav' >"$input_dir/topic-b/sample2.wav"
  printf 'BORE tunnel rollback' >"$input_dir/topic-b/sample2.txt"
  printf 'orphan text without audio pair' >"$input_dir/topic-b/orphan.txt"

  (
    export PATH="$fakebin:$PATH"
    python3 "$dataset_builder" \
      --input-dir "$input_dir" \
      --output-dir "$output_dir" \
      --jobs 2 \
      --test-ratio 0.5 \
      --seed 7
  )

  summary="$output_dir/summary.json"
  train_jsonl="$output_dir/train.jsonl"
  test_jsonl="$output_dir/test.jsonl"
  all_jsonl="$output_dir/all.jsonl"
  errors_jsonl="$output_dir/errors.jsonl"

  [ -f "$summary" ] || fail "dataset summary.json is missing"
  [ -f "$train_jsonl" ] || fail "dataset train.jsonl is missing"
  [ -f "$test_jsonl" ] || fail "dataset test.jsonl is missing"
  [ -f "$all_jsonl" ] || fail "dataset all.jsonl is missing"
  [ -f "$errors_jsonl" ] || fail "dataset errors.jsonl is missing"

  total="$(( $(wc -l <"$train_jsonl") + $(wc -l <"$test_jsonl") ))"
  [ "$total" -eq 2 ] || fail "expected 2 processed samples across train/test, got $total"

  python3 - "$summary" "$all_jsonl" "$output_dir" <<'PY'
import json
import pathlib
import sys

summary_path = pathlib.Path(sys.argv[1])
all_jsonl_path = pathlib.Path(sys.argv[2])
output_dir = pathlib.Path(sys.argv[3])

summary = json.loads(summary_path.read_text(encoding="utf-8"))
if summary.get("processed_samples") != 2:
    raise SystemExit("processed_samples mismatch")
if summary.get("errors", 0) < 1:
    raise SystemExit("expected at least one pairing error in summary")

for line in all_jsonl_path.read_text(encoding="utf-8").splitlines():
    row = json.loads(line)
    if sorted(row.keys()) != ["audio", "sentence"]:
        raise SystemExit("invalid dataset row schema")
    if not str(row["sentence"]).strip():
        raise SystemExit("empty sentence in dataset row")
    audio_path = output_dir / row["audio"]
    if not audio_path.is_file():
        raise SystemExit(f"missing re-encoded audio: {audio_path}")
PY

  rm -rf "$tmp"
}

test_dataset_etl_llm_accept_runtime() {
  local tmp fakebin root raw queue output audio text job builder marker
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  root="$tmp/dataset"
  raw="$root/raw/2026-02-21"
  queue="$root/queue"
  output="$root/hf"
  builder="$tmp/fake_builder.py"
  marker="$tmp/builder_called.txt"
  mkdir -p "$fakebin" "$raw" "$queue" "$output"

  write_fake_curl "$fakebin"
  write_fake_codex_validator "$fakebin"

  audio="$raw/sample_accept.wav"
  text="$raw/sample_accept.txt"
  job="$queue/1_sample_accept.job"
  dd if=/dev/zero of="$audio" bs=160 count=1 status=none
  printf 'consistent corrected text for acceptance' >"$text"
  cat >"$job" <<EOF
sample_id=sample_accept
audio=$audio
text=$text
queued_ms=1
EOF

  cat >"$builder" <<'PY'
#!/usr/bin/env python3
import os
from pathlib import Path

marker = os.environ.get("FAKE_DATASET_BUILDER_MARKER", "")
if marker:
    Path(marker).write_text("called\n", encoding="utf-8")
PY
  chmod +x "$builder"

  (
    export PATH="$fakebin:$PATH"
    export FAKE_CURL_TEXT="consistent corrected text for acceptance"
    export FAKE_CODEX_REPLY='{"verdict":"accept","confidence":0.93,"reason":"same meaning"}'
    export FAKE_DATASET_BUILDER_MARKER="$marker"
    export S2T_DATASET_ROOT="$root"
    export S2T_DATASET_RAW_DIR="$root/raw"
    export S2T_DATASET_QUEUE_DIR="$queue"
    export S2T_DATASET_OUTPUT_DIR="$output"
    export S2T_DATASET_BUILDER="$builder"
    export S2T_DATASET_ETL_AUTORUN=1
    export S2T_DATASET_ETL_ONCE=1
    export S2T_DATASET_VALIDATE_PAIRS=1
    export S2T_DATASET_VALIDATE_WITH_LLM=1
    export S2T_DATASET_LLM_REQUIRED=1
    export S2T_DATASET_LLM_VALIDATOR_CMD=codex
    export S2T_DATASET_ASR_PROBE_ENABLED=1
    export S2T_DATASET_ASR_PROBE_REQUIRED=0
    export S2T_DATASET_ASR_PROBE_URL="http://127.0.0.1:9787/inference"
    python3 "$dataset_etl_script"
  )

  [ -f "$marker" ] || fail "dataset builder was not called after llm accept"
  [ ! -f "$job" ] || fail "accepted job file still exists"
  if find "$queue" -type f -name '*.failed.*' | grep -q .; then
    fail "accepted job unexpectedly moved to failed"
  fi

  rm -rf "$tmp"
}

test_dataset_etl_llm_reject_runtime() {
  local tmp fakebin root raw queue output audio text job builder marker failed_count
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  root="$tmp/dataset"
  raw="$root/raw/2026-02-21"
  queue="$root/queue"
  output="$root/hf"
  builder="$tmp/fake_builder.py"
  marker="$tmp/builder_called.txt"
  mkdir -p "$fakebin" "$raw" "$queue" "$output"

  write_fake_curl "$fakebin"
  write_fake_codex_validator "$fakebin"

  audio="$raw/sample_reject.wav"
  text="$raw/sample_reject.txt"
  job="$queue/1_sample_reject.job"
  dd if=/dev/zero of="$audio" bs=160 count=1 status=none
  printf 'totally unrelated corrected text content' >"$text"
  cat >"$job" <<EOF
sample_id=sample_reject
audio=$audio
text=$text
queued_ms=1
EOF

  cat >"$builder" <<'PY'
#!/usr/bin/env python3
import os
from pathlib import Path

marker = os.environ.get("FAKE_DATASET_BUILDER_MARKER", "")
if marker:
    Path(marker).write_text("called\n", encoding="utf-8")
PY
  chmod +x "$builder"

  (
    export PATH="$fakebin:$PATH"
    export FAKE_CURL_TEXT="audio says one thing"
    export FAKE_CODEX_REPLY='{"verdict":"reject","confidence":0.97,"reason":"mismatch"}'
    export FAKE_DATASET_BUILDER_MARKER="$marker"
    export S2T_DATASET_ROOT="$root"
    export S2T_DATASET_RAW_DIR="$root/raw"
    export S2T_DATASET_QUEUE_DIR="$queue"
    export S2T_DATASET_OUTPUT_DIR="$output"
    export S2T_DATASET_BUILDER="$builder"
    export S2T_DATASET_ETL_AUTORUN=1
    export S2T_DATASET_ETL_ONCE=1
    export S2T_DATASET_VALIDATE_PAIRS=1
    export S2T_DATASET_VALIDATE_WITH_LLM=1
    export S2T_DATASET_LLM_REQUIRED=1
    export S2T_DATASET_LLM_VALIDATOR_CMD=codex
    export S2T_DATASET_ASR_PROBE_ENABLED=1
    export S2T_DATASET_ASR_PROBE_REQUIRED=0
    export S2T_DATASET_ASR_PROBE_URL="http://127.0.0.1:9787/inference"
    python3 "$dataset_etl_script"
  )

  [ ! -f "$marker" ] || fail "dataset builder unexpectedly called after llm reject"
  failed_count="$(find "$queue" -type f -name '*.failed.*' | wc -l)"
  [ "$failed_count" -eq 1 ] || fail "expected one failed queue file after llm reject, got $failed_count"
  if ! find "$root/quarantine" -type f -name '*sample_reject*' | grep -q .; then
    fail "rejected sample files were not copied to quarantine"
  fi
  [ -f "$audio" ] || fail "raw rejected audio must remain in raw dataset"
  [ -f "$text" ] || fail "raw rejected text must remain in raw dataset"

  rm -rf "$tmp"
}

test_submit_correction_pairs_audio_with_manual_text_runtime() {
  local tmp fakebin runbase datahome raw_dir queue_dir corrected txt_file wav_file queue_jobs
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-submit-correction-$$-$RANDOM"
  datahome="$runbase/data"
  raw_dir="$datahome/s2t/dataset/raw"
  queue_dir="$datahome/s2t/dataset/queue"
  mkdir -p "$runbase"

  corrected="NixOS rollout via ArgoCD and BORE tunnel rollback"

  write_fake_pw_record "$fakebin"
  write_fake_curl "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export XDG_DATA_HOME="$datahome"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_USE_SERVER=1
    export S2T_DATASET_ENQUEUE_CORRECTION=1
    export FAKE_CURL_TEXT="model output should not be used"
    "$controller" start
    sleep 0.25
    "$controller" stop
    printf '%s\n' "$corrected" | "$controller" submit-correction >/dev/null
  )

  txt_file="$(find "$raw_dir" -type f -name '*.txt' ! -name '*.raw.txt' | head -n1 || true)"
  wav_file="$(find "$raw_dir" -type f -name '*.wav' | head -n1 || true)"
  [ -n "${txt_file:-}" ] || fail "corrected transcript file is missing after submit-correction"
  [ -n "${wav_file:-}" ] || fail "paired wav file is missing after submit-correction"
  [ -f "$txt_file" ] || fail "corrected transcript path is invalid"
  [ -f "$wav_file" ] || fail "paired wav path is invalid"
  [ "$(cat "$txt_file")" = "$corrected" ] || fail "dataset text is not the manually corrected transcript"

  if [ -d "$queue_dir" ]; then
    queue_jobs="$(find "$queue_dir" -type f -name '*.job' | wc -l)"
  else
    queue_jobs=0
  fi
  [ "$queue_jobs" -eq 1 ] || fail "expected exactly one queued ETL job, got $queue_jobs"

  rm -rf "$tmp" "$runbase"
}

test_submit_correction_maps_latest_contiguous_cluster_runtime() {
  local tmp fakebin runbase datahome raw_dir queue_dir corrected txt_count wav_count queue_jobs
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-submit-cluster-$$-$RANDOM"
  datahome="$runbase/data"
  raw_dir="$datahome/s2t/dataset/raw"
  queue_dir="$datahome/s2t/dataset/queue"
  mkdir -p "$runbase"

  corrected="cluster corrected phrase for two segments"

  write_fake_pw_record "$fakebin"
  write_fake_curl "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export XDG_DATA_HOME="$datahome"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_USE_SERVER=1
    export S2T_DATASET_ENQUEUE_CORRECTION=1
    export S2T_DATASET_CLUSTER_ON_SUBMIT=1
    export S2T_DATASET_MULTI_SEGMENT_GAP_SEC=30
    export FAKE_CURL_TEXT="model output should not be used"

    "$controller" start
    sleep 0.2
    "$controller" stop
    sleep 0.3
    "$controller" start
    sleep 0.2
    "$controller" stop

    printf '%s\n' "$corrected" | "$controller" submit-correction >/dev/null
  )

  txt_count="$(find "$raw_dir" -type f -name '*.txt' ! -name '*.raw.txt' | wc -l)"
  wav_count="$(find "$raw_dir" -type f -name '*.wav' | wc -l)"
  [ "$txt_count" -eq 2 ] || fail "expected 2 corrected transcript files for clustered submit, got $txt_count"
  [ "$wav_count" -eq 2 ] || fail "expected 2 wav files for clustered submit, got $wav_count"

  if find "$raw_dir" -type f -name '*.txt' ! -name '*.raw.txt' -exec cat {} \; | rg -qv "^${corrected}$"; then
    fail "clustered submit wrote text different from corrected phrase"
  fi

  if [ -d "$queue_dir" ]; then
    queue_jobs="$(find "$queue_dir" -type f -name '*.job' | wc -l)"
  else
    queue_jobs=0
  fi
  [ "$queue_jobs" -eq 2 ] || fail "expected 2 queued ETL jobs for clustered submit, got $queue_jobs"

  rm -rf "$tmp" "$runbase"
}

test_submit_correction_with_id_keeps_cluster_runtime() {
  local tmp fakebin runbase datahome raw_dir pending_dir queue_dir corrected latest_sid txt_count wav_count queue_jobs
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-submit-cluster-id-$$-$RANDOM"
  datahome="$runbase/data"
  raw_dir="$datahome/s2t/dataset/raw"
  pending_dir="$datahome/s2t/dataset/pending"
  queue_dir="$datahome/s2t/dataset/queue"
  mkdir -p "$runbase"

  corrected="cluster corrected phrase with explicit id"

  write_fake_pw_record "$fakebin"
  write_fake_curl "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export XDG_DATA_HOME="$datahome"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_USE_SERVER=1
    export S2T_DATASET_ENQUEUE_CORRECTION=1
    export S2T_DATASET_CLUSTER_ON_SUBMIT=1
    export S2T_DATASET_MULTI_SEGMENT_GAP_SEC=30
    export FAKE_CURL_TEXT="model output should not be used"

    "$controller" start
    sleep 0.2
    "$controller" stop
    sleep 0.3
    "$controller" start
    sleep 0.2
    "$controller" stop

    latest_sid="$(ls -1t "$pending_dir"/*.meta | head -n1 | xargs -r basename | sed 's/\.meta$//')"
    [ -n "$latest_sid" ] || exit 11
    printf '%s\n' "$corrected" | "$controller" submit-correction --id "$latest_sid" >/dev/null
  )

  txt_count="$(find "$raw_dir" -type f -name '*.txt' ! -name '*.raw.txt' | wc -l)"
  wav_count="$(find "$raw_dir" -type f -name '*.wav' | wc -l)"
  [ "$txt_count" -eq 2 ] || fail "expected 2 corrected transcript files for clustered submit by id, got $txt_count"
  [ "$wav_count" -eq 2 ] || fail "expected 2 wav files for clustered submit by id, got $wav_count"

  if find "$raw_dir" -type f -name '*.txt' ! -name '*.raw.txt' -exec cat {} \; | rg -qv "^${corrected}$"; then
    fail "clustered submit by id wrote text different from corrected phrase"
  fi

  if [ -d "$queue_dir" ]; then
    queue_jobs="$(find "$queue_dir" -type f -name '*.job' | wc -l)"
  else
    queue_jobs=0
  fi
  [ "$queue_jobs" -eq 2 ] || fail "expected 2 queued ETL jobs for clustered submit by id, got $queue_jobs"

  rm -rf "$tmp" "$runbase"
}

test_pending_only_until_submit_runtime() {
  local tmp fakebin runbase datahome raw_dir pending_dir corrected raw_txt_count pending_meta_count
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-pending-only-$$-$RANDOM"
  datahome="$runbase/data"
  raw_dir="$datahome/s2t/dataset/raw"
  pending_dir="$datahome/s2t/dataset/pending"
  mkdir -p "$runbase"

  corrected="manual correction goes to raw only on submit"

  write_fake_pw_record "$fakebin"
  write_fake_curl "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export XDG_DATA_HOME="$datahome"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_USE_SERVER=1
    export S2T_DATASET_ENQUEUE_CORRECTION=1
    export S2T_DATASET_AUTO_SUBMIT_RAW=0
    export FAKE_CURL_TEXT="asr draft should stay pending"

    "$controller" start
    sleep 0.2
    "$controller" stop

    mkdir -p "$raw_dir" "$pending_dir"
    raw_txt_count="$(find "$raw_dir" -type f -name '*.txt' ! -name '*.raw.txt' 2>/dev/null | wc -l)"
    pending_meta_count="$(find "$pending_dir" -type f -name '*.meta' | wc -l)"
    [ "$raw_txt_count" -eq 0 ] || fail "raw dataset must stay empty before submit-correction when auto-submit is disabled"
    [ "$pending_meta_count" -eq 1 ] || fail "expected exactly one pending sample before submit-correction, got $pending_meta_count"

    printf '%s\n' "$corrected" | "$controller" submit-correction >/dev/null
  )

  raw_txt_count="$(find "$raw_dir" -type f -name '*.txt' ! -name '*.raw.txt' | wc -l)"
  pending_meta_count="$(find "$pending_dir" -type f -name '*.meta' | wc -l)"
  [ "$raw_txt_count" -eq 1 ] || fail "expected one corrected raw transcript after submit-correction, got $raw_txt_count"
  [ "$pending_meta_count" -eq 0 ] || fail "pending sample should be consumed after submit-correction"

  rm -rf "$tmp" "$runbase"
}

test_rabbitmq_backend_enqueue_runtime() {
  local tmp runbase datahome raw_dir queue_dir pending_dir marker publisher corrected queue_jobs txt_count sid now_ms
  tmp="$(mktemp -d)"
  runbase="/dev/shm/s2t-test-rabbit-enqueue-$$-$RANDOM"
  datahome="$runbase/data"
  raw_dir="$datahome/s2t/dataset/raw"
  queue_dir="$datahome/s2t/dataset/queue"
  pending_dir="$datahome/s2t/dataset/pending"
  marker="$tmp/rabbit_publish.txt"
  publisher="$tmp/fake-rabbit-publish.py"
  corrected="rabbit backend corrected phrase"

  mkdir -p "$pending_dir"
  now_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
  sid="${now_ms}_rabbit_enqueue"
  printf 'asr draft\n' >"$pending_dir/$sid.raw.txt"
  : >"$pending_dir/$sid.wav"
  cat >"$pending_dir/$sid.meta" <<EOF
sample_id=$sid
audio=$pending_dir/$sid.wav
raw_text=$pending_dir/$sid.raw.txt
created_ms=$now_ms
EOF

  cat >"$publisher" <<'EOF'
#!/usr/bin/env python3
import os
import pathlib
import sys
marker = os.environ.get("FAKE_RABBIT_PUBLISH_MARKER", "")
if marker:
    pathlib.Path(marker).write_text(" ".join(sys.argv[1:]), encoding="utf-8")
EOF
  chmod +x "$publisher"

  (
    export XDG_RUNTIME_DIR="$runbase"
    export XDG_DATA_HOME="$datahome"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_QUEUE_BACKEND=rabbitmq
    export S2T_RABBITMQ_PUBLISHER="$publisher"
    export FAKE_RABBIT_PUBLISH_MARKER="$marker"
    printf '%s\n' "$corrected" | "$controller" submit-correction >/dev/null
  )

  [ -f "$marker" ] || fail "rabbitmq backend did not invoke publisher"
  assert_contains "$marker" '--sample-id'
  assert_contains "$marker" '--audio'
  assert_contains "$marker" '--text'

  if [ -d "$queue_dir" ]; then
    queue_jobs="$(find "$queue_dir" -type f -name '*.job' | wc -l)"
  else
    queue_jobs=0
  fi
  [ "$queue_jobs" -eq 0 ] || fail "rabbitmq enqueue should not create local .job when publish succeeds"
  txt_count="$(find "$raw_dir" -type f -name '*.txt' ! -name '*.raw.txt' | wc -l)"
  [ "$txt_count" -eq 1 ] || fail "expected one corrected transcript in raw after rabbitmq enqueue"

  rm -rf "$tmp" "$runbase"
}

test_rabbitmq_backend_fallback_to_file_queue_runtime() {
  local tmp runbase datahome queue_dir pending_dir marker publisher corrected queue_jobs logfile sid now_ms
  tmp="$(mktemp -d)"
  runbase="/dev/shm/s2t-test-rabbit-fallback-$$-$RANDOM"
  datahome="$runbase/data"
  queue_dir="$datahome/s2t/dataset/queue"
  pending_dir="$datahome/s2t/dataset/pending"
  marker="$tmp/rabbit_publish_fail.txt"
  publisher="$tmp/fake-rabbit-publish-fail.py"
  corrected="rabbit backend fallback corrected phrase"

  mkdir -p "$pending_dir"
  now_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
  sid="${now_ms}_rabbit_fallback"
  printf 'asr draft\n' >"$pending_dir/$sid.raw.txt"
  : >"$pending_dir/$sid.wav"
  cat >"$pending_dir/$sid.meta" <<EOF
sample_id=$sid
audio=$pending_dir/$sid.wav
raw_text=$pending_dir/$sid.raw.txt
created_ms=$now_ms
EOF

  cat >"$publisher" <<'EOF'
#!/usr/bin/env python3
import os
import pathlib
import sys
marker = os.environ.get("FAKE_RABBIT_PUBLISH_MARKER", "")
if marker:
    pathlib.Path(marker).write_text(" ".join(sys.argv[1:]), encoding="utf-8")
raise SystemExit(1)
EOF
  chmod +x "$publisher"

  (
    export XDG_RUNTIME_DIR="$runbase"
    export XDG_DATA_HOME="$datahome"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_QUEUE_BACKEND=rabbitmq
    export S2T_RABBITMQ_PUBLISHER="$publisher"
    export FAKE_RABBIT_PUBLISH_MARKER="$marker"
    printf '%s\n' "$corrected" | "$controller" submit-correction >/dev/null
  )

  [ -f "$marker" ] || fail "rabbitmq fallback test did not call publisher"
  queue_jobs="$(find "$queue_dir" -type f -name '*.job' | wc -l)"
  [ "$queue_jobs" -eq 1 ] || fail "rabbitmq fallback should create one local .job file"
  logfile="$runbase/s2t/s2t.log"
  assert_contains "$logfile" 'dataset: rabbitmq enqueue failed sample_id='

  rm -rf "$tmp" "$runbase"
}

test_controller_autoloads_user_env_runtime() {
  local tmp fakebin runbase datahome home_dir args_file logfile
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-env-autoload-$$-$RANDOM"
  datahome="$runbase/data"
  home_dir="$tmp/home"
  args_file="$tmp/curl.args"
  mkdir -p "$runbase" "$home_dir/.config/s2t"

  cat >"$home_dir/.config/s2t/s2t.env" <<'EOF'
S2T_USE_SERVER=1
S2T_WHISPER_SERVER_URL=http://127.0.0.1:9911/inference
S2T_INSERT_METHOD=none
S2T_DATASET_AUTO_SUBMIT_RAW=0
EOF

  write_fake_pw_record "$fakebin"
  write_fake_curl_capture_args "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export XDG_DATA_HOME="$datahome"
    export HOME="$home_dir"
    export S2T_AUTOLOAD_ENV_FILES=1
    export S2T_PREPEND_RESULT_BIN=0
    export FAKE_CURL_ARGS_FILE="$args_file"
    "$controller" start
    sleep 0.2
    "$controller" stop
  )

  logfile="$runbase/s2t/s2t.log"
  [ -f "$args_file" ] || fail "curl args file missing in env autoload test"
  rg -q "http://127.0.0.1:9911/inference" "$args_file" || fail "controller did not autoload S2T_WHISPER_SERVER_URL from ~/.config/s2t/s2t.env"
  rg -q "server request -> http://127.0.0.1:9911/inference" "$logfile" || fail "env autoload server URL log missing"

  rm -rf "$tmp" "$runbase"
}

test_codex_bridge_submits_recent_user_message_runtime() {
  local tmp home_dir sessions_dir runbase datahome pending_dir sid created_ms now_ms event_ts
  local fake_controller marker script_log state_file raw_text corrected_text
  tmp="$(mktemp -d)"
  home_dir="$tmp/home"
  sessions_dir="$home_dir/.codex/sessions/2026/02/21"
  runbase="/dev/shm/s2t-test-codex-bridge-$$-$RANDOM"
  datahome="$runbase/data"
  pending_dir="$datahome/s2t/dataset/pending"
  marker="$tmp/submitted.txt"
  fake_controller="$tmp/fake-controller.sh"
  script_log="$runbase/runtime/codex-bridge.log"
  state_file="$tmp/state.json"
  raw_text="eto testovaya fraza dlya dataseta"
  corrected_text="eto ispravlennaya testovaya fraza dlya dataseta"

  mkdir -p "$sessions_dir" "$pending_dir" "$runbase/runtime"
  now_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
  created_ms="$((now_ms - 1000))"
  sid="${created_ms}_999"
  printf '%s\n' "$raw_text" >"$pending_dir/$sid.raw.txt"
  : >"$pending_dir/$sid.wav"
  cat >"$pending_dir/$sid.meta" <<EOF
sample_id=$sid
audio=$pending_dir/$sid.wav
raw_text=$pending_dir/$sid.raw.txt
created_ms=$created_ms
EOF

  event_ts="$(date -u +'%Y-%m-%dT%H:%M:%S.000Z')"
  cat >"$sessions_dir/rollout-test.jsonl" <<EOF
{"timestamp":"$event_ts","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"$corrected_text"}]}}
EOF

  cat >"$fake_controller" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "submit-correction" ] || exit 2
: "${FAKE_SUBMIT_MARKER:?}"
: "${S2T_DATASET_PENDING_DIR:?}"
text="$(cat)"
printf '%s' "$text" >"$FAKE_SUBMIT_MARKER"
rm -f "$S2T_DATASET_PENDING_DIR"/*.meta "$S2T_DATASET_PENDING_DIR"/*.raw.txt "$S2T_DATASET_PENDING_DIR"/*.wav
echo "/tmp/fake-dataset.txt"
EOF
  chmod +x "$fake_controller"

  (
    export HOME="$home_dir"
    export XDG_RUNTIME_DIR="$runbase/runtime"
    export XDG_DATA_HOME="$datahome"
    export S2T_CODEX_BRIDGE_ENABLED=1
    export S2T_CODEX_BRIDGE_RUN_ONCE=1
    export S2T_CODEX_BRIDGE_BACKFILL_EXISTING=1
    export S2T_CODEX_SESSIONS_DIR="$home_dir/.codex/sessions"
    export S2T_CODEX_BRIDGE_STATE_FILE="$state_file"
    export S2T_CODEX_BRIDGE_CONTROLLER="$fake_controller"
    export S2T_DATASET_PENDING_DIR="$pending_dir"
    export S2T_CODEX_BRIDGE_WINDOW_SEC=30
    export S2T_CODEX_BRIDGE_POLL_SEC=0.2
    export S2T_CODEX_BRIDGE_LOG_FILE="$script_log"
    export FAKE_SUBMIT_MARKER="$marker"
    python3 "$codex_bridge_script"
  )

  [ -f "$marker" ] || fail "codex bridge did not call submit-correction"
  [ "$(cat "$marker")" = "$corrected_text" ] || fail "codex bridge submitted unexpected corrected text"
  [ ! -f "$pending_dir/$sid.meta" ] || fail "pending sample was not consumed by submit-correction bridge call"

  rm -rf "$tmp" "$runbase"
}

test_codex_bridge_skips_log_like_messages_runtime() {
  local tmp home_dir sessions_dir runbase datahome pending_dir sid created_ms now_ms event_ts
  local fake_controller marker state_file text_payload script_log raw_text
  tmp="$(mktemp -d)"
  home_dir="$tmp/home"
  sessions_dir="$home_dir/.codex/sessions/2026/02/21"
  runbase="/dev/shm/s2t-test-codex-bridge-skip-$$-$RANDOM"
  datahome="$runbase/data"
  pending_dir="$datahome/s2t/dataset/pending"
  marker="$tmp/submitted.txt"
  fake_controller="$tmp/fake-controller.sh"
  state_file="$tmp/state.json"
  script_log="$runbase/runtime/codex-bridge.log"
  raw_text="Посмотри s2t.log Почему там на Google модель все равно запросы уходят"
  text_payload="Посмотри s2t.log. Почему там на Google модель все равно запросы уходят?"

  mkdir -p "$sessions_dir" "$pending_dir" "$runbase/runtime"
  now_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
  created_ms="$((now_ms - 1000))"
  sid="${created_ms}_998"
  printf '%s\n' "$raw_text" >"$pending_dir/$sid.raw.txt"
  : >"$pending_dir/$sid.wav"
  cat >"$pending_dir/$sid.meta" <<EOF
sample_id=$sid
audio=$pending_dir/$sid.wav
raw_text=$pending_dir/$sid.raw.txt
created_ms=$created_ms
EOF

  event_ts="$(date -u +'%Y-%m-%dT%H:%M:%S.000Z')"
  cat >"$sessions_dir/rollout-test-skip.jsonl" <<EOF
{"timestamp":"$event_ts","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"$text_payload"}]}}
EOF

  cat >"$fake_controller" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_SUBMIT_MARKER:?}"
printf 'called' >"$FAKE_SUBMIT_MARKER"
exit 0
EOF
  chmod +x "$fake_controller"

  (
    export HOME="$home_dir"
    export XDG_RUNTIME_DIR="$runbase/runtime"
    export XDG_DATA_HOME="$datahome"
    export S2T_CODEX_BRIDGE_ENABLED=1
    export S2T_CODEX_BRIDGE_RUN_ONCE=1
    export S2T_CODEX_BRIDGE_BACKFILL_EXISTING=1
    export S2T_CODEX_SESSIONS_DIR="$home_dir/.codex/sessions"
    export S2T_CODEX_BRIDGE_STATE_FILE="$state_file"
    export S2T_CODEX_BRIDGE_CONTROLLER="$fake_controller"
    export S2T_DATASET_PENDING_DIR="$pending_dir"
    export S2T_CODEX_BRIDGE_WINDOW_SEC=30
    export S2T_CODEX_BRIDGE_LOG_FILE="$script_log"
    export FAKE_SUBMIT_MARKER="$marker"
    python3 "$codex_bridge_script"
  )

  [ ! -f "$marker" ] || fail "codex bridge must skip log-like message"
  [ -f "$pending_dir/$sid.meta" ] || fail "pending sample must remain when log-like message is skipped"
  rg -q "diagnostic/log-like message" "$script_log" || fail "bridge skip reason log is missing for log-like message"

  rm -rf "$tmp" "$runbase"
}

test_codex_bridge_matches_delayed_best_pending_runtime() {
  local tmp home_dir sessions_dir runbase datahome pending_dir state_file script_log
  local fake_controller marker_text marker_args event_ts now_ms
  local target_created latest_created target_sid latest_sid raw_target raw_latest corrected_text
  tmp="$(mktemp -d)"
  home_dir="$tmp/home"
  sessions_dir="$home_dir/.codex/sessions/2026/02/21"
  runbase="/dev/shm/s2t-test-codex-bridge-delayed-$$-$RANDOM"
  datahome="$runbase/data"
  pending_dir="$datahome/s2t/dataset/pending"
  state_file="$tmp/state.json"
  script_log="$runbase/runtime/codex-bridge.log"
  fake_controller="$tmp/fake-controller.sh"
  marker_text="$tmp/submitted-text.txt"
  marker_args="$tmp/submitted-args.txt"
  raw_target="slushai kakie csi draivery dlya kubera interesnye sushchestvuyut longhorn ebs efs"
  raw_latest="eto sovsem drugaya fraza pro debug logi i servis"
  corrected_text="слушай а какие CSI драйверы для кубера вообще интересные существуют longhorn ebs efs"

  mkdir -p "$sessions_dir" "$pending_dir" "$runbase/runtime"
  now_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
  target_created="$((now_ms - 65000))"
  latest_created="$((now_ms - 2000))"
  target_sid="${target_created}_777"
  latest_sid="${latest_created}_888"

  printf '%s\n' "$raw_target" >"$pending_dir/$target_sid.raw.txt"
  : >"$pending_dir/$target_sid.wav"
  cat >"$pending_dir/$target_sid.meta" <<EOF
sample_id=$target_sid
audio=$pending_dir/$target_sid.wav
raw_text=$pending_dir/$target_sid.raw.txt
created_ms=$target_created
EOF

  printf '%s\n' "$raw_latest" >"$pending_dir/$latest_sid.raw.txt"
  : >"$pending_dir/$latest_sid.wav"
  cat >"$pending_dir/$latest_sid.meta" <<EOF
sample_id=$latest_sid
audio=$pending_dir/$latest_sid.wav
raw_text=$pending_dir/$latest_sid.raw.txt
created_ms=$latest_created
EOF

  event_ts="$(date -u +'%Y-%m-%dT%H:%M:%S.000Z')"
  cat >"$sessions_dir/rollout-test-delayed.jsonl" <<EOF
{"timestamp":"$event_ts","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"$corrected_text"}]}}
EOF

  cat >"$fake_controller" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "submit-correction" ] || exit 2
: "${FAKE_SUBMIT_TEXT_MARKER:?}"
: "${FAKE_SUBMIT_ARGS_MARKER:?}"
: "${S2T_DATASET_PENDING_DIR:?}"
printf '%s\n' "$@" >"$FAKE_SUBMIT_ARGS_MARKER"
text="$(cat)"
printf '%s' "$text" >"$FAKE_SUBMIT_TEXT_MARKER"
sid=""
if [ "${2:-}" = "--id" ]; then
  sid="${3:-}"
fi
if [ -n "$sid" ]; then
  rm -f "$S2T_DATASET_PENDING_DIR/$sid.meta" \
    "$S2T_DATASET_PENDING_DIR/$sid.raw.txt" \
    "$S2T_DATASET_PENDING_DIR/$sid.wav"
fi
echo "/tmp/fake-dataset.txt"
EOF
  chmod +x "$fake_controller"

  (
    export HOME="$home_dir"
    export XDG_RUNTIME_DIR="$runbase/runtime"
    export XDG_DATA_HOME="$datahome"
    export S2T_CODEX_BRIDGE_ENABLED=1
    export S2T_CODEX_BRIDGE_RUN_ONCE=1
    export S2T_CODEX_BRIDGE_BACKFILL_EXISTING=1
    export S2T_CODEX_SESSIONS_DIR="$home_dir/.codex/sessions"
    export S2T_CODEX_BRIDGE_STATE_FILE="$state_file"
    export S2T_CODEX_BRIDGE_CONTROLLER="$fake_controller"
    export S2T_DATASET_PENDING_DIR="$pending_dir"
    export S2T_CODEX_BRIDGE_WINDOW_SEC=30
    export S2T_CODEX_BRIDGE_MAX_PENDING_AGE_SEC=600
    export S2T_CODEX_BRIDGE_LOG_FILE="$script_log"
    export FAKE_SUBMIT_TEXT_MARKER="$marker_text"
    export FAKE_SUBMIT_ARGS_MARKER="$marker_args"
    python3 "$codex_bridge_script"
  )

  [ -f "$marker_text" ] || fail "codex bridge did not submit delayed overlap correction"
  [ "$(cat "$marker_text")" = "$corrected_text" ] || fail "codex bridge submitted unexpected delayed corrected text"
  rg -q -- '^--id$' "$marker_args" || fail "codex bridge must pass --id to submit-correction"
  rg -q -- "^${target_sid}$" "$marker_args" || fail "codex bridge must target best overlap pending sample id"
  [ ! -f "$pending_dir/$target_sid.meta" ] || fail "target pending sample must be consumed for delayed overlap correction"
  [ -f "$pending_dir/$latest_sid.meta" ] || fail "non-matching latest pending sample must stay untouched"

  rm -rf "$tmp" "$runbase"
}

test_local_provider_server_request_has_no_timeout_runtime() {
  local tmp fakebin runbase logfile curl_args transcript_file
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-local-no-timeout-$$-$RANDOM"
  mkdir -p "$runbase"
  curl_args="$tmp/curl_args.txt"

  write_fake_pw_record "$fakebin"
  write_fake_curl_capture_args "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_ASR_PROVIDER=local
    export S2T_USE_SERVER=1
    export S2T_SERVER_TIMEOUT_SEC=4
    export FAKE_SOX_DURATION=20.000000
    export FAKE_CURL_ARGS_FILE="$curl_args"
    "$controller" start
    sleep 0.25
    "$controller" stop
  )

  logfile="$runbase/s2t/s2t.log"
  transcript_file="$runbase/s2t/last_transcript.txt"
  [ -f "$logfile" ] || fail "log file missing in local no-timeout test"
  [ -f "$curl_args" ] || fail "server request args missing in local no-timeout test"
  [ -f "$transcript_file" ] || fail "missing transcript in local no-timeout test"
  if rg -q -- "--max-time" "$curl_args"; then
    fail "local provider unexpectedly used curl --max-time for whisper-server request"
  fi

  rm -rf "$tmp" "$runbase"
}

test_google_long_audio_dynamic_timeout_runtime() {
  local tmp fakebin runbase real_python transcript_file logfile
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-google-dynamic-timeout-$$-$RANDOM"
  mkdir -p "$runbase"
  real_python="$(command -v python3)"

  write_fake_pw_record "$fakebin"
  write_fake_sox "$fakebin"
  write_fake_python_google_v1_delayed_success "$fakebin" "$real_python"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_ASR_PROVIDER=google
    export S2T_GOOGLE_API_KEY=test-key
    export S2T_GOOGLE_MODEL=latest_long
    export S2T_GOOGLE_TIMEOUT_SEC=5
    export S2T_MAX_RESPONSE_SECONDS=5
    export S2T_GOOGLE_DYNAMIC_TIMEOUT=1
    export S2T_GOOGLE_TIMEOUT_PER_AUDIO_SEC=0.25
    export S2T_GOOGLE_TIMEOUT_MAX_SEC=20
    export S2T_USE_SERVER=0
    export S2T_DEBUG_TIMING=1
    export FAKE_SOX_DURATION=20.000000
    export FAKE_GOOGLE_V1_DELAY_SEC=6
    export FAKE_GOOGLE_V1_TEXT="long phrase transcript with enough characters to pass minimum length guard for dynamic timeout verification run"
    "$controller" start
    "$controller" stop
  )

  transcript_file="$runbase/s2t/last_transcript.txt"
  logfile="$runbase/s2t/s2t.log"
  [ -f "$transcript_file" ] || fail "missing transcript in google dynamic-timeout test"
  rg -q "long phrase transcript with enough characters" "$transcript_file" || fail "google dynamic-timeout did not return transcript"
  rg -q "timing: google_timeout_sec=10 guard_sec=10" "$logfile" || fail "dynamic timeout log missing expected effective timeout"
  if rg -q "google timeout; skipping local fallback" "$logfile"; then
    fail "unexpected timeout under dynamic long-audio profile"
  fi

  rm -rf "$tmp" "$runbase"
}

test_google_mid_audio_prefers_long_model_runtime() {
  local tmp fakebin runbase real_python logfile
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-google-mid-audio-model-$$-$RANDOM"
  mkdir -p "$runbase"
  real_python="$(command -v python3)"

  write_fake_pw_record "$fakebin"
  write_fake_sox "$fakebin"
  write_fake_python_google_v1_delayed_success "$fakebin" "$real_python"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_ASR_PROVIDER=google
    export S2T_GOOGLE_API_KEY=test-key
    export S2T_GOOGLE_MODEL=latest_long
    export S2T_GOOGLE_SHORT_MODEL=latest_short
    unset S2T_GOOGLE_SHORT_AUDIO_SEC
    export S2T_USE_SERVER=0
    export FAKE_SOX_DURATION=5.600000
    export FAKE_GOOGLE_V1_DELAY_SEC=0
    export FAKE_GOOGLE_V1_TEXT="mid audio transcript with enough characters"
    "$controller" start
    "$controller" stop
  )

  logfile="$runbase/s2t/s2t.log"
  [ -f "$logfile" ] || fail "log file missing in google mid-audio model selection test"
  rg -q "asr: google request -> latest_long" "$logfile" || fail "expected latest_long model for ~5.6s audio"
  if rg -q "asr: google request -> latest_short" "$logfile"; then
    fail "unexpected latest_short model for ~5.6s audio"
  fi

  rm -rf "$tmp" "$runbase"
}

test_google_v2_fallback() {
  local tmp fakebin runbase creds real_python transcript_file
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-gv2-$$-$RANDOM"
  mkdir -p "$runbase"
  creds="$tmp/creds.json"
  echo '{}' >"$creds"
  real_python="$(command -v python3)"

  write_fake_pw_record "$fakebin"
  write_fake_python_google_v2 "$fakebin" "$real_python"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_ASR_PROVIDER=google-v2
    export S2T_USE_SERVER=0
    export S2T_GCP_PROJECT=test-project
    export S2T_GOOGLE_APPLICATION_CREDENTIALS="$creds"
    export S2T_GOOGLE_V2_LANGUAGE_CODES=ru-RU
    export S2T_GOOGLE_V2_FALLBACK_LANGUAGE_CODES=en-US
    "$controller" start
    "$controller" stop
  )

  transcript_file="$runbase/s2t/last_transcript.txt"
  [ -f "$transcript_file" ] || fail "missing transcript after google-v2 fallback test"
  rg -q "fallback transcript" "$transcript_file" || fail "google-v2 fallback did not produce transcript"
  rg -q "retry with fallback languages" "$runbase/s2t/s2t.log" || fail "fallback retry log missing"

  rm -rf "$tmp" "$runbase"
}

test_audio_target_prefers_real_source_over_loopback_runtime() {
  local tmp fakebin runbase args_file inspect_file status_file sources_file pid
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-audio-source-$$-$RANDOM"
  mkdir -p "$runbase"
  args_file="$tmp/pw-record.args"
  inspect_file="$tmp/wpctl.inspect"
  status_file="$tmp/wpctl.status"
  sources_file="$tmp/pactl.sources"

  write_fake_pw_record_capture_args "$fakebin"
  write_fake_wpctl "$fakebin"
  write_fake_pactl_sources "$fakebin"

  cat >"$inspect_file" <<'EOF'
id 57, type PipeWire:Interface:Node
  * node.name = "alsa_input.platform-snd_aloop.0.analog-stereo"
  * node.description = "Loopback Analog Stereo"
  alsa.driver_name = "snd_aloop"
EOF

  cat >"$status_file" <<'EOF'
Settings
 └─ Default Configured Node Names:
         1. Audio/Source  alsa_input.pci-0000_00_1f.3.analog-stereo
EOF

  cat >"$sources_file" <<'EOF'
61	alsa_input.platform-snd_aloop.0.analog-stereo	PipeWire	s32le 2ch 48000Hz	SUSPENDED
62	alsa_input.usb-Logitech_USB_Mic-00.mono-fallback	PipeWire	s32le 1ch 48000Hz	SUSPENDED
EOF

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_AVOID_LOOPBACK_SOURCE=1
    export S2T_ENABLE_ALSA_CAPTURE_FALLBACK=0
    export FAKE_PW_RECORD_ARGS_FILE="$args_file"
    export FAKE_WPCTL_INSPECT_FILE="$inspect_file"
    export FAKE_WPCTL_STATUS_FILE="$status_file"
    export FAKE_PACTL_SOURCES_FILE="$sources_file"
    "$controller" start
    pid="$(cat "$runbase/s2t/recording.pid")"
    kill -TERM "$pid"
    sleep 0.05
  )

  [ -f "$args_file" ] || fail "pw-record args missing in audio source selection test"
  rg -q -- "--target" "$args_file" || fail "expected explicit --target in audio source selection test"
  rg -q "alsa_input.usb-Logitech_USB_Mic-00.mono-fallback" "$args_file" || fail "did not choose non-loopback pactl source"

  rm -rf "$tmp" "$runbase"
}

test_audio_target_ignores_missing_configured_source_runtime() {
  local tmp fakebin runbase args_file inspect_file status_file sources_file pid
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-audio-missing-source-$$-$RANDOM"
  mkdir -p "$runbase"
  args_file="$tmp/pw-record.args"
  inspect_file="$tmp/wpctl.inspect"
  status_file="$tmp/wpctl.status"
  sources_file="$tmp/pactl.sources"

  write_fake_pw_record_capture_args "$fakebin"
  write_fake_wpctl "$fakebin"
  write_fake_pactl_sources "$fakebin"

  cat >"$inspect_file" <<'EOF'
id 57, type PipeWire:Interface:Node
  * node.name = "alsa_input.platform-snd_aloop.0.analog-stereo"
  * node.description = "Loopback Analog Stereo"
  alsa.driver_name = "snd_aloop"
EOF

  cat >"$status_file" <<'EOF'
Settings
 └─ Default Configured Node Names:
         1. Audio/Source  alsa_input.pci-0000_00_1f.3.analog-stereo
EOF

  cat >"$sources_file" <<'EOF'
61	alsa_output.pci-0000_00_1f.3.analog-stereo.monitor	PipeWire	s32le 2ch 48000Hz	SUSPENDED
62	alsa_input.platform-snd_aloop.0.analog-stereo	PipeWire	s32le 2ch 48000Hz	SUSPENDED
EOF

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_AVOID_LOOPBACK_SOURCE=1
    export S2T_ENABLE_ALSA_CAPTURE_FALLBACK=0
    export FAKE_PW_RECORD_ARGS_FILE="$args_file"
    export FAKE_WPCTL_INSPECT_FILE="$inspect_file"
    export FAKE_WPCTL_STATUS_FILE="$status_file"
    export FAKE_PACTL_SOURCES_FILE="$sources_file"
    "$controller" start
    pid="$(cat "$runbase/s2t/recording.pid")"
    kill -TERM "$pid"
    sleep 0.05
  )

  [ -f "$args_file" ] || fail "pw-record args missing in missing-source test"
  if rg -q -- "--target" "$args_file"; then
    fail "unexpected explicit --target when only loopback/monitor sources are available"
  fi

  rm -rf "$tmp" "$runbase"
}

test_alsa_capture_fallback_runtime() {
  local tmp fakebin runbase pw_args_file arecord_args_file inspect_file status_file sources_file arecord_list_file pid
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-alsa-fallback-$$-$RANDOM"
  mkdir -p "$runbase"
  pw_args_file="$tmp/pw-record.args"
  arecord_args_file="$tmp/arecord.args"
  inspect_file="$tmp/wpctl.inspect"
  status_file="$tmp/wpctl.status"
  sources_file="$tmp/pactl.sources"
  arecord_list_file="$tmp/arecord.list"

  write_fake_pw_record_capture_args "$fakebin"
  write_fake_arecord_capture_args "$fakebin"
  write_fake_wpctl "$fakebin"
  write_fake_pactl_sources "$fakebin"

  cat >"$inspect_file" <<'EOF'
id 57, type PipeWire:Interface:Node
  * node.name = "alsa_input.platform-snd_aloop.0.analog-stereo"
  * node.description = "Loopback Analog Stereo"
  alsa.driver_name = "snd_aloop"
EOF

  cat >"$status_file" <<'EOF'
Settings
 └─ Default Configured Node Names:
         1. Audio/Source  alsa_input.pci-0000_00_1f.3.analog-stereo
EOF

  cat >"$sources_file" <<'EOF'
61	alsa_output.pci-0000_00_1f.3.analog-stereo.monitor	PipeWire	s32le 2ch 48000Hz	SUSPENDED
62	alsa_input.platform-snd_aloop.0.analog-stereo	PipeWire	s32le 2ch 48000Hz	SUSPENDED
EOF

  cat >"$arecord_list_file" <<'EOF'
**** List of CAPTURE Hardware Devices ****
card 0: PCH [HDA Intel PCH], device 0: ALC269VC Analog [ALC269VC Analog]
card 2: Loopback [Loopback], device 0: Loopback PCM [Loopback PCM]
EOF

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_AVOID_LOOPBACK_SOURCE=1
    export S2T_ENABLE_ALSA_CAPTURE_FALLBACK=1
    export FAKE_PW_RECORD_ARGS_FILE="$pw_args_file"
    export FAKE_ARECORD_ARGS_FILE="$arecord_args_file"
    export FAKE_ARECORD_LIST_FILE="$arecord_list_file"
    export FAKE_WPCTL_INSPECT_FILE="$inspect_file"
    export FAKE_WPCTL_STATUS_FILE="$status_file"
    export FAKE_PACTL_SOURCES_FILE="$sources_file"
    "$controller" start
    pid="$(cat "$runbase/s2t/recording.pid")"
    kill -TERM "$pid"
    sleep 0.05
  )

  [ -f "$arecord_args_file" ] || fail "arecord args missing in ALSA fallback test"
  rg -q -- "-D" "$arecord_args_file" || fail "arecord device flag missing in ALSA fallback test"
  rg -q "plughw:0,0" "$arecord_args_file" || fail "expected ALSA fallback to plughw:0,0"
  [ ! -f "$pw_args_file" ] || fail "pw-record should not be used when ALSA fallback is selected"

  rm -rf "$tmp" "$runbase"
}

test_google_v1_empty_retries_google_v2_runtime() {
  local tmp fakebin runbase creds real_python transcript_file logfile
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-google-v1-v2-retry-$$-$RANDOM"
  mkdir -p "$runbase"
  creds="$tmp/creds.json"
  real_python="$(command -v python3)"

  cat >"$creds" <<'EOF'
{"project_id":"test-project"}
EOF

  write_fake_pw_record "$fakebin"
  write_fake_sox "$fakebin"
  write_fake_python_google_v1_empty_v2_retry "$fakebin" "$real_python"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_ASR_PROVIDER=google
    export S2T_GOOGLE_API_KEY=test-key
    export S2T_GOOGLE_MODEL=latest_long
    export S2T_GOOGLE_SHORT_MODEL=latest_short
    export S2T_GOOGLE_RETRY_ON_EMPTY=0
    export S2T_GOOGLE_V2_ON_EMPTY=1
    export S2T_GOOGLE_V2_MODEL=chirp_2
    export S2T_GOOGLE_APPLICATION_CREDENTIALS="$creds"
    export S2T_USE_SERVER=0
    export FAKE_GOOGLE_V2_TEXT="google-v2-retry-ok"
    "$controller" start
    "$controller" stop
  )

  transcript_file="$runbase/s2t/last_transcript.txt"
  logfile="$runbase/s2t/s2t.log"
  [ -f "$transcript_file" ] || fail "missing transcript after google(v1)->google(v2) retry test"
  rg -q "google-v2-retry-ok" "$transcript_file" || fail "google-v2 retry transcript missing"
  rg -q "google empty/fail; retry -> google-v2" "$logfile" || fail "missing google-v2 retry log from google(v1) path"

  rm -rf "$tmp" "$runbase"
}

test_google_empty_retries_without_alt_languages_runtime() {
  local tmp fakebin runbase real_python transcript_file logfile
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-google-no-alt-retry-$$-$RANDOM"
  mkdir -p "$runbase"
  real_python="$(command -v python3)"

  write_fake_pw_record "$fakebin"
  write_fake_sox "$fakebin"
  write_fake_python_google_v1_empty_until_no_alt "$fakebin" "$real_python"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_ASR_PROVIDER=google
    export S2T_GOOGLE_API_KEY=test-key
    export S2T_GOOGLE_MODEL=latest_long
    export S2T_GOOGLE_SHORT_MODEL=latest_long
    export S2T_GOOGLE_RETRY_ON_EMPTY=1
    export S2T_GOOGLE_ALT_LANGUAGE_CODES=en-US
    export S2T_USE_SERVER=0
    export FAKE_SOX_DURATION=4.500000
    export FAKE_GOOGLE_V1_TEXT="google-no-alt-retry-ok"
    "$controller" start
    "$controller" stop
  )

  transcript_file="$runbase/s2t/last_transcript.txt"
  logfile="$runbase/s2t/s2t.log"
  [ -f "$transcript_file" ] || fail "missing transcript after google no-alt retry test"
  rg -q "google-no-alt-retry-ok" "$transcript_file" || fail "google no-alt retry did not produce transcript"
  rg -q "retry same model without alt languages" "$logfile" || fail "missing no-alt retry log"
  if rg -q "falling back to local" "$logfile"; then
    fail "unexpected local fallback despite successful no-alt retry"
  fi

  rm -rf "$tmp" "$runbase"
}

test_google_empty_alt_config_is_respected_runtime() {
  local tmp fakebin runbase real_python transcript_file logfile
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-google-empty-alt-config-$$-$RANDOM"
  mkdir -p "$runbase"
  real_python="$(command -v python3)"

  write_fake_pw_record "$fakebin"
  write_fake_sox "$fakebin"
  write_fake_python_google_v1_empty_until_no_alt "$fakebin" "$real_python"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_ASR_PROVIDER=google
    export S2T_GOOGLE_API_KEY=test-key
    export S2T_GOOGLE_MODEL=latest_long
    export S2T_GOOGLE_SHORT_MODEL=latest_long
    export S2T_GOOGLE_RETRY_ON_EMPTY=1
    export S2T_GOOGLE_ALT_LANGUAGE_CODES=
    export S2T_USE_SERVER=0
    export FAKE_SOX_DURATION=4.500000
    export FAKE_GOOGLE_V1_TEXT="google-empty-alt-config-ok"
    "$controller" start
    "$controller" stop
  )

  transcript_file="$runbase/s2t/last_transcript.txt"
  logfile="$runbase/s2t/s2t.log"
  [ -f "$transcript_file" ] || fail "missing transcript when alt language config is empty"
  rg -q "google-empty-alt-config-ok" "$transcript_file" || fail "empty alt language config was not respected"
  if rg -q "retry same model without alt languages" "$logfile"; then
    fail "unexpected no-alt retry when alt languages are already empty"
  fi

  rm -rf "$tmp" "$runbase"
}

test_google_short_result_guard_retries_without_alt_languages_runtime() {
  local tmp fakebin runbase real_python transcript_file logfile
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-google-short-guard-$$-$RANDOM"
  mkdir -p "$runbase"
  real_python="$(command -v python3)"

  write_fake_pw_record "$fakebin"
  write_fake_sox "$fakebin"
  write_fake_python_google_v1_short_until_no_alt "$fakebin" "$real_python"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_ASR_PROVIDER=google
    export S2T_GOOGLE_API_KEY=test-key
    export S2T_GOOGLE_MODEL=latest_long
    export S2T_GOOGLE_SHORT_MODEL=latest_long
    export S2T_GOOGLE_RETRY_ON_EMPTY=1
    export S2T_GOOGLE_RETRY_ON_SHORT=1
    export S2T_GOOGLE_SHORT_RESULT_AUDIO_SEC=4
    export S2T_GOOGLE_MIN_CHARS_PER_AUDIO_SEC=3.5
    export S2T_GOOGLE_ALT_LANGUAGE_CODES=en-US
    export S2T_USE_SERVER=0
    export FAKE_SOX_DURATION=6.000000
    export FAKE_GOOGLE_V1_SHORT_TEXT="ok"
    export FAKE_GOOGLE_V1_TEXT="google-short-guard-retry-ok"
    "$controller" start
    "$controller" stop
  )

  transcript_file="$runbase/s2t/last_transcript.txt"
  logfile="$runbase/s2t/s2t.log"
  [ -f "$transcript_file" ] || fail "missing transcript after google short-result guard test"
  rg -q "google-short-guard-retry-ok" "$transcript_file" || fail "short-result guard did not recover transcript"
  rg -q "transcript too short for audio" "$logfile" || fail "missing short-result guard log"
  rg -q "retry same model without alt languages" "$logfile" || fail "missing no-alt retry log for short-result guard"

  rm -rf "$tmp" "$runbase"
}

test_unset_xdg_session_type_type_mode() {
  local tmp fakebin runbase transcript_file
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-xdg-$$-$RANDOM"
  mkdir -p "$runbase"

  write_fake_pw_record "$fakebin"
  write_fake_curl "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_xdotool "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    unset XDG_SESSION_TYPE
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=type
    export S2T_USE_SERVER=1
    export FAKE_CURL_TEXT="typed-result"
    "$controller" start
    "$controller" stop
  )

  transcript_file="$runbase/s2t/last_transcript.txt"
  [ -f "$transcript_file" ] || fail "missing transcript for unset XDG_SESSION_TYPE test"
  rg -q "typed-result" "$transcript_file" || fail "type mode did not complete with unset XDG_SESSION_TYPE"

  rm -rf "$tmp" "$runbase"
}

test_log_rotation() {
  local tmp fakebin runbase logfile size i
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-log-$$-$RANDOM"
  mkdir -p "$runbase"

  write_fake_pw_record "$fakebin"
  write_fake_curl "$fakebin"
  write_fake_jq "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_USE_SERVER=1
    export FAKE_CURL_TEXT="log-rotate"
    export S2T_LOG_MAX_BYTES=400
    export S2T_LOG_KEEP=2
    for i in $(seq 1 20); do
      "$controller" start
      "$controller" stop
    done
  )

  logfile="$runbase/s2t/s2t.log"
  [ -f "$logfile" ] || fail "s2t.log missing in log rotation test"
  size="$(stat -c '%s' "$logfile")"
  if [ "$size" -gt 800 ]; then
    fail "s2t.log too large after rotation: $size"
  fi
  [ -f "$logfile.1" ] || fail "s2t.log.1 missing after rotation"
  [ ! -f "$logfile.3" ] || fail "rotation keep count exceeded (found s2t.log.3)"

  rm -rf "$tmp" "$runbase"
}

test_whisper_artifact_pruning() {
  local tmp fakebin runbase model i log_count
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-whisper-$$-$RANDOM"
  mkdir -p "$runbase"
  model="$tmp/model.bin"
  echo "dummy" >"$model"

  write_fake_pw_record "$fakebin"
  write_fake_whisper_cli "$fakebin"
  write_fake_sox "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_USE_SERVER=0
    export S2T_MODEL_PATH="$model"
    export FAKE_WHISPER_RC=2
    export S2T_WHISPER_ARTIFACT_KEEP=2
    for i in $(seq 1 6); do
      "$controller" start
      "$controller" stop
    done
  )

  log_count="$(find "$runbase/s2t" -maxdepth 1 -name 'whisper_*.log' | wc -l)"
  if [ "$log_count" -gt 2 ]; then
    fail "whisper failure logs were not pruned (count=$log_count)"
  fi

  rm -rf "$tmp" "$runbase"
}

run_test() {
  local name="$1"
  shift
  if [ -n "${S2T_TEST_FILTER:-}" ] && ! printf '%s\n' "$name" | rg -q -- "${S2T_TEST_FILTER}"; then
    return 0
  fi
  echo "==> $name"
  "$@"
}

run_test "ansible sudo precheck" test_ansible_sudo_precheck
run_test "target user resolution" test_target_user_resolution
run_test "linger autostart setup" test_linger_autostart_setup
run_test "keyd menu hotkey mapping" test_keyd_menu_hotkey_mapping
run_test "user env authoritative" test_user_env_is_authoritative
run_test "user env restart monitor notify" test_user_env_change_restarts_monitor
run_test "model download best effort" test_model_download_best_effort
run_test "paste fallback default" test_paste_fallback_default
run_test "max record limit support" test_max_record_limit_support
run_test "capture fail fallback controls present" test_capture_fail_fallback_controls_present
run_test "network-only controls present" test_network_only_controls_present
run_test "google dynamic short model controls" test_google_dynamic_short_model_controls_present
run_test "local provider disables server timeout" test_local_provider_disables_server_timeout
run_test "monitor controller override support" test_monitor_controller_override_support
run_test "monitor global lock support" test_monitor_global_lock_support
run_test "monitor hotkey resilience controls" test_monitor_hotkey_resilience_controls_present
run_test "systemd cgroup limits present" test_systemd_cgroup_limits_present
run_test "dataset etl service setup" test_dataset_etl_service_setup_present
run_test "codex bridge service setup" test_codex_bridge_service_setup_present
run_test "rabbitmq queue setup" test_rabbitmq_queue_setup_present
run_test "dataset etl llm validation controls" test_dataset_etl_llm_validation_controls_present
run_test "dataset collection controls present" test_dataset_collection_controls_present
run_test "model path fallback guards present" test_model_path_fallback_guards_present
run_test "user env long dictation profile" test_user_env_long_dictation_profile
run_test "is_positive_int declaration order" test_is_positive_int_declared_before_use
run_test "uninstall target user" test_uninstall_target_user_resolution
run_test "stop race lock" test_stop_race_lock
run_test "stop lock release" test_stop_lock_released_before_clipboard_owner
run_test "network-only runtime skip" test_network_only_skips_local_fallback_runtime
run_test "zero-duration audio skips ASR" test_zero_duration_skips_asr_runtime
run_test "delayed wav payload wait" test_wait_for_delayed_wav_payload
run_test "drop when busy prevents queue" test_drop_when_busy_prevents_transcribe_queue
run_test "stale transcribe lock recovery" test_stale_transcribe_lock_recovery_runtime
run_test "preserve clipboard fallback" test_preserve_clipboard_no_overwrite_on_snapshot_failure
run_test "preserve clipboard non-strict fallback" test_preserve_clipboard_non_strict_falls_back_to_paste
run_test "google response-timeout after send logic" test_google_response_timeout_after_send_logic
run_test "dataset builder pipeline" test_dataset_builder_pipeline_runtime
run_test "dataset etl llm accept" test_dataset_etl_llm_accept_runtime
run_test "dataset etl llm reject" test_dataset_etl_llm_reject_runtime
run_test "submit correction pairs audio/manual text" test_submit_correction_pairs_audio_with_manual_text_runtime
run_test "submit correction maps clustered pending audio" test_submit_correction_maps_latest_contiguous_cluster_runtime
run_test "submit correction with id keeps clustering" test_submit_correction_with_id_keeps_cluster_runtime
run_test "pending only until submit-correction" test_pending_only_until_submit_runtime
run_test "rabbitmq backend enqueue" test_rabbitmq_backend_enqueue_runtime
run_test "rabbitmq backend fallback to file queue" test_rabbitmq_backend_fallback_to_file_queue_runtime
run_test "controller autoloads user env" test_controller_autoloads_user_env_runtime
run_test "codex bridge submits recent user message" test_codex_bridge_submits_recent_user_message_runtime
run_test "codex bridge skips log-like messages" test_codex_bridge_skips_log_like_messages_runtime
run_test "codex bridge matches delayed best pending" test_codex_bridge_matches_delayed_best_pending_runtime
run_test "local server request has no timeout" test_local_provider_server_request_has_no_timeout_runtime
run_test "google long audio dynamic timeout" test_google_long_audio_dynamic_timeout_runtime
run_test "google mid audio prefers long model" test_google_mid_audio_prefers_long_model_runtime
run_test "google v2 fallback" test_google_v2_fallback
run_test "audio target prefers real source" test_audio_target_prefers_real_source_over_loopback_runtime
run_test "audio target ignores missing configured source" test_audio_target_ignores_missing_configured_source_runtime
run_test "alsa capture fallback" test_alsa_capture_fallback_runtime
run_test "google v1 empty retries google v2" test_google_v1_empty_retries_google_v2_runtime
run_test "google empty retries without alt languages" test_google_empty_retries_without_alt_languages_runtime
run_test "google empty alt config respected" test_google_empty_alt_config_is_respected_runtime
run_test "google short-result guard retries without alt" test_google_short_result_guard_retries_without_alt_languages_runtime
run_test "unset XDG session type" test_unset_xdg_session_type_type_mode
run_test "log rotation" test_log_rotation
run_test "whisper artifact pruning" test_whisper_artifact_pruning

echo "OK: regression tests passed"
