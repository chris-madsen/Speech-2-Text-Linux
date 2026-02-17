#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
controller="$repo_root/s2t-role/files/scripts/controller.sh"
monitor_script="$repo_root/s2t-role/files/scripts/monitor.py"
monitor_unit="$repo_root/s2t-role/files/s2t-monitor.service"
whisper_unit="$repo_root/s2t-role/files/s2t-whisper.service"
tasks_main="$repo_root/s2t-role/tasks/main.yml"
uninstall_playbook="$repo_root/uninstall.yml"

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
trap 'exit 0' TERM INT
while true; do
  printf '1234' >>"$out"
  sleep 0.02
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

test_ansible_sudo_precheck() {
  assert_contains "$tasks_main" "Check passwordless sudo availability"
  assert_contains "$tasks_main" "sudo -n true"
}

test_target_user_resolution() {
  assert_contains "$tasks_main" "Resolve S2T target user"
  assert_contains "$tasks_main" "ansible_env.SUDO_USER"
  assert_contains "$tasks_main" "s2t_target_home"
  assert_contains "$tasks_main" "s2t_target_uid"
}

test_linger_autostart_setup() {
  assert_contains "$tasks_main" "Enable lingering for target user"
  assert_contains "$tasks_main" "loginctl enable-linger"
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

test_network_only_controls_present() {
  assert_contains "$controller" 'S2T_NETWORK_ONLY="\$\{S2T_NETWORK_ONLY:-0\}"'
  assert_contains "$controller" 'S2T_MAX_RESPONSE_SECONDS="\$\{S2T_MAX_RESPONSE_SECONDS:-5\}"'
  assert_contains "$controller" 'network-only enabled, skipping local fallback'
}

test_monitor_controller_override_support() {
  assert_contains "$monitor_script" 'CONTROLLER_ENV_VAR = "S2T_CONTROLLER"'
  assert_contains "$monitor_script" 'controller_override = os.environ.get\(CONTROLLER_ENV_VAR, ""\)\.strip\(\)'
}

test_systemd_cgroup_limits_present() {
  assert_contains "$whisper_unit" '^CPUQuota=350%'
  assert_contains "$whisper_unit" '^MemoryMax=3G'
  assert_contains "$whisper_unit" '^TasksMax=64'
  assert_contains "$monitor_unit" '^CPUQuota=50%'
  assert_contains "$monitor_unit" '^MemoryMax=256M'
  assert_contains "$monitor_unit" '^TasksMax=32'
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

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_ASR_PROVIDER=google
    export S2T_NETWORK_ONLY=1
    export S2T_USE_SERVER=1
    export S2T_GOOGLE_API_KEY=test-key
    export FAKE_CURL_TEXT="   "
    "$controller" start
    "$controller" stop
  )

  logfile="$runbase/s2t/s2t.log"
  transcript_file="$runbase/s2t/last_transcript.txt"
  [ -f "$logfile" ] || fail "log file missing in network-only runtime test"
  rg -q "network-only enabled, skipping local fallback" "$logfile" || fail "network-only skip log missing"
  [ ! -f "$transcript_file" ] || fail "network-only mode unexpectedly produced local transcript"

  rm -rf "$tmp" "$runbase"
}

test_max_response_clamps_google_timeout_runtime() {
  local tmp fakebin runbase args_file max_time_value
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  runbase="/dev/shm/s2t-test-timeout-clamp-$$-$RANDOM"
  mkdir -p "$runbase"
  args_file="$tmp/curl.args"

  write_fake_pw_record "$fakebin"
  write_fake_curl_capture_args "$fakebin"
  write_fake_jq "$fakebin"

  (
    export PATH="$fakebin:$PATH"
    export XDG_RUNTIME_DIR="$runbase"
    export S2T_PREPEND_RESULT_BIN=0
    export S2T_INSERT_METHOD=none
    export S2T_ASR_PROVIDER=google
    export S2T_NETWORK_ONLY=1
    export S2T_USE_SERVER=0
    export S2T_GOOGLE_API_KEY=test-key
    export S2T_GOOGLE_TIMEOUT_SEC=30
    export S2T_MAX_RESPONSE_SECONDS=5
    export FAKE_CURL_ARGS_FILE="$args_file"
    "$controller" start
    "$controller" stop
  )

  [ -f "$args_file" ] || fail "curl args capture file missing"
  max_time_value="$(awk 'prev=="--max-time"{print; exit} {prev=$0}' "$args_file")"
  [ "$max_time_value" = "5" ] || fail "expected --max-time 5, got '${max_time_value:-missing}'"

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
  echo "==> $name"
  "$@"
}

run_test "ansible sudo precheck" test_ansible_sudo_precheck
run_test "target user resolution" test_target_user_resolution
run_test "linger autostart setup" test_linger_autostart_setup
run_test "model download best effort" test_model_download_best_effort
run_test "paste fallback default" test_paste_fallback_default
run_test "max record limit support" test_max_record_limit_support
run_test "network-only controls present" test_network_only_controls_present
run_test "monitor controller override support" test_monitor_controller_override_support
run_test "systemd cgroup limits present" test_systemd_cgroup_limits_present
run_test "is_positive_int declaration order" test_is_positive_int_declared_before_use
run_test "uninstall target user" test_uninstall_target_user_resolution
run_test "stop race lock" test_stop_race_lock
run_test "stop lock release" test_stop_lock_released_before_clipboard_owner
run_test "network-only runtime skip" test_network_only_skips_local_fallback_runtime
run_test "max response timeout clamp" test_max_response_clamps_google_timeout_runtime
run_test "google v2 fallback" test_google_v2_fallback
run_test "unset XDG session type" test_unset_xdg_session_type_type_mode
run_test "log rotation" test_log_rotation
run_test "whisper artifact pruning" test_whisper_artifact_pruning

echo "OK: regression tests passed"
