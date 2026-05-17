#!/usr/bin/env bash
# S2T Controller
# Handles state, notification, calls record/transcribe scripts.

set -euo pipefail

S2T_AUTOLOAD_ENV_FILES="${S2T_AUTOLOAD_ENV_FILES:-1}"

load_env_file_if_exists() {
    local file="$1"
    [ -f "$file" ] || return 0
    # shellcheck disable=SC1090
    set -a
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

# Config
is_tmpfs_dir() {
    local dir="$1"
    [ -n "${dir:-}" ] || return 1
    [ -d "$dir" ] || return 1
    [ "$(stat -f -c %T "$dir" 2>/dev/null || true)" = "tmpfs" ]
}

select_runtime_base_dir() {
    local uid base
    uid="$(id -u 2>/dev/null || echo 0)"

    # Respect explicit runtime dir from the session/environment first.
    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; then
        printf '%s' "$XDG_RUNTIME_DIR"
        return 0
    fi

    for base in "/run/user/$uid" "/dev/shm"; do
        if is_tmpfs_dir "$base"; then
            printf '%s' "$base"
            return 0
        fi
    done

    # Last resort: keep working even on systems without tmpfs runtime dirs.
    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
        printf '%s' "$XDG_RUNTIME_DIR"
        return 0
    fi
    printf '%s' "/tmp"
    return 0
}

RUNTIME_DIR="$(select_runtime_base_dir)/s2t"
PID_FILE="$RUNTIME_DIR/recording.pid"
AUDIO_FILE="$RUNTIME_DIR/current_recording.wav"
LOG_FILE="$RUNTIME_DIR/s2t.log"
STOP_LOCK_FILE="$RUNTIME_DIR/stop.lock"
RECORDER_LOG_FILE="$RUNTIME_DIR/pw-record.log"
RECORDER_KIND_FILE="$RUNTIME_DIR/recorder.kind"
START_TS_FILE="$RUNTIME_DIR/recording.start_ms"
TARGET_WINDOW_FILE="$RUNTIME_DIR/target_window.id"
TRANSCRIBE_LOCK_DIR="$RUNTIME_DIR/transcribe.lock"
CAPTURE_FAIL_FILE="$RUNTIME_DIR/capture_fail.count"
CAPTURE_DEFAULT_UNTIL_FILE="$RUNTIME_DIR/capture_default_until_ms"
LAST_SAMPLE_META_FILE="$RUNTIME_DIR/last_sample.meta"
SECONDARY_TEXT_FILE="$RUNTIME_DIR/secondary_buffer.txt"
SECONDARY_META_FILE="$RUNTIME_DIR/secondary_buffer.meta"

# Model selection (for CLI fallback only). Prefer accurate model if already present.
MODEL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/s2t"
MODEL_LARGE_PATH="${MODEL_DIR}/ggml-large-v3-turbo.bin"
MODEL_MEDIUM_PATH="${MODEL_DIR}/ggml-medium.bin"
MODEL_SMALL_PATH="${MODEL_DIR}/ggml-small.bin"
MODEL_TINY_PATH="${MODEL_DIR}/ggml-tiny.bin"
MODEL_PRESET="${S2T_MODEL_PRESET:-balanced}" # fast|balanced|medium|accurate

model_url_for() {
    case "$1" in
        ggml-large-v3-turbo.bin) printf '%s' "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" ;;
        ggml-medium.bin)         printf '%s' "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin" ;;
        ggml-small.bin)          printf '%s' "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin" ;;
        ggml-tiny.bin)           printf '%s' "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin" ;;
        *)                       printf '%s' "" ;;
    esac
}

if [ -n "${S2T_MODEL_PATH:-}" ]; then
    MODEL_PATH="$S2T_MODEL_PATH"
    MODEL_URL="${S2T_MODEL_URL:-}"
else
    CANDIDATES=()
    case "$MODEL_PRESET" in
        accurate) CANDIDATES=( "$MODEL_LARGE_PATH" "$MODEL_MEDIUM_PATH" "$MODEL_SMALL_PATH" "$MODEL_TINY_PATH" ) ;;
        medium)   CANDIDATES=( "$MODEL_MEDIUM_PATH" "$MODEL_SMALL_PATH" "$MODEL_LARGE_PATH" "$MODEL_TINY_PATH" ) ;;
        fast)     CANDIDATES=( "$MODEL_TINY_PATH" "$MODEL_SMALL_PATH" "$MODEL_MEDIUM_PATH" "$MODEL_LARGE_PATH" ) ;;
        *)        CANDIDATES=( "$MODEL_SMALL_PATH" "$MODEL_MEDIUM_PATH" "$MODEL_LARGE_PATH" "$MODEL_TINY_PATH" ) ;;
    esac

    MODEL_PATH=""
    for candidate in "${CANDIDATES[@]}"; do
        if [ -f "$candidate" ]; then
            MODEL_PATH="$candidate"
            break
        fi
    done

    if [ -z "$MODEL_PATH" ]; then
        MODEL_PATH="${CANDIDATES[0]}"
    fi

    MODEL_URL="${S2T_MODEL_URL:-$(model_url_for "$(basename "$MODEL_PATH")")}"
fi

resolve_model_path_for_current_user() {
    local requested="$1"
    local requested_dir requested_base fallback_path

    [ -n "$requested" ] || return 0

    if [ -f "$requested" ] && [ -r "$requested" ]; then
        return 0
    fi

    requested_dir="$(dirname "$requested")"
    if [ -d "$requested_dir" ] && [ -w "$requested_dir" ]; then
        return 0
    fi
    if mkdir -p "$requested_dir" >/dev/null 2>&1 && [ -w "$requested_dir" ]; then
        return 0
    fi

    requested_base="$(basename "$requested")"
    fallback_path="${MODEL_DIR}/${requested_base}"
    printf '%s\n' "S2T: model path '$requested' is not writable/readable; falling back to '$fallback_path'" >&2
    MODEL_PATH="$fallback_path"
    if [ -z "${MODEL_URL}" ]; then
        MODEL_URL="$(model_url_for "$requested_base")"
    fi
}

resolve_model_path_for_current_user "$MODEL_PATH"

# UX defaults: no popups; paste instantly.
S2T_NOTIFY="${S2T_NOTIFY:-0}"
S2T_INSERT_METHOD="${S2T_INSERT_METHOD:-paste}" # paste|type|none
# Paste shortcut:
# - Use S2T_PASTE_KEYS=auto to pick based on focused app (X11 only; via xdotool classname):
#   - terminals: ctrl+shift+v (safe for tmux)
#   - everything else: ctrl+v (works in editors/text fields)
S2T_PASTE_KEYS="${S2T_PASTE_KEYS:-auto}" # auto|shift+insert|ctrl+v|ctrl+shift+v
S2T_PASTE_KEYS_TERMINAL="${S2T_PASTE_KEYS_TERMINAL:-ctrl+shift+v}"
S2T_PASTE_KEYS_GUI="${S2T_PASTE_KEYS_GUI:-ctrl+v}"
S2T_PASTE_KEYS_FALLBACK="${S2T_PASTE_KEYS_FALLBACK:-shift+insert}"
S2T_XDOTOOL_DELAY_MS="${S2T_XDOTOOL_DELAY_MS:-0}"
S2T_MAX_RECORD_SECONDS="${S2T_MAX_RECORD_SECONDS:-0}" # 0 disables forced max duration

S2T_USE_SERVER="${S2T_USE_SERVER:-1}"
S2T_LOCAL_DISABLE_CLI_FALLBACK="${S2T_LOCAL_DISABLE_CLI_FALLBACK:-1}" # 1: when provider=local, do not fallback from whisper-server to whisper-cli
S2T_WHISPER_SERVER_PORT="${S2T_WHISPER_SERVER_PORT:-9787}"
S2T_WHISPER_SERVER_URL="${S2T_WHISPER_SERVER_URL:-http://127.0.0.1:${S2T_WHISPER_SERVER_PORT}/inference}"
S2T_SERVER_TIMEOUT_SEC="${S2T_SERVER_TIMEOUT_SEC:-4}" # whisper-server request timeout (used for local fallback from cloud providers)
S2T_SERVER_DYNAMIC_TIMEOUT="${S2T_SERVER_DYNAMIC_TIMEOUT:-1}" # 1: extend local fallback timeout for long utterances when cloud-first provider falls back
S2T_SERVER_TIMEOUT_PER_AUDIO_SEC="${S2T_SERVER_TIMEOUT_PER_AUDIO_SEC:-0.5}" # added seconds per 1s audio when dynamic timeout is enabled
S2T_SERVER_TIMEOUT_MAX_SEC="${S2T_SERVER_TIMEOUT_MAX_SEC:-90}" # hard cap for dynamic local fallback timeout (0 disables cap)
S2T_DEBUG_TIMING="${S2T_DEBUG_TIMING:-0}"
S2T_LOG_VERBOSE="${S2T_LOG_VERBOSE:-0}" # 1: detailed diagnostics in s2t.log
S2T_PRESERVE_CLIPBOARD="${S2T_PRESERVE_CLIPBOARD:-1}" # 1: preserve and restore X11 CLIPBOARD around temporary paste transport
S2T_PRESERVE_CLIPBOARD_STRICT="${S2T_PRESERVE_CLIPBOARD_STRICT:-0}" # 1: if snapshot fails, refuse X11 clipboard transport
S2T_CLIPBOARD_RESTORE_DELAY_MS="${S2T_CLIPBOARD_RESTORE_DELAY_MS:-350}" # base delay before restoring clipboard after X11 paste transport
S2T_CLIPBOARD_RESTORE_PER_CHAR_MS="${S2T_CLIPBOARD_RESTORE_PER_CHAR_MS:-2}" # extra delay per transcript char before restoring clipboard
S2T_CLIPBOARD_RESTORE_EXTRA_MAX_MS="${S2T_CLIPBOARD_RESTORE_EXTRA_MAX_MS:-2500}" # cap adaptive restore delay for long transcripts
S2T_REFOCUS_TARGET_WINDOW="${S2T_REFOCUS_TARGET_WINDOW:-1}" # 1: on X11, refocus captured target window before paste
S2T_SECONDARY_BUFFER_ENABLE="${S2T_SECONDARY_BUFFER_ENABLE:-1}" # 1: persist latest transcript in secondary recovery buffer
S2T_X11_SECONDARY_AUTO_INSERT="${S2T_X11_SECONDARY_AUTO_INSERT:-1}" # 1: allow automatic X11 insert from secondary buffer
S2T_X11_SECONDARY_MANUAL_PASTE="${S2T_X11_SECONDARY_MANUAL_PASTE:-1}" # 1: allow Alt+V manual typing from secondary buffer on X11
S2T_X11_TYPE_TIMEOUT_SEC="${S2T_X11_TYPE_TIMEOUT_SEC:-2}" # kill stuck X11 typing helpers before they wedge the session for too long
S2T_SECONDARY_WAIT_FOR_FRESH_MS="${S2T_SECONDARY_WAIT_FOR_FRESH_MS:-12000}" # wait this long for active transcribe to refresh secondary before manual paste
S2T_KEEP_AUDIO="${S2T_KEEP_AUDIO:-0}" # 1: keep last wav on disk (tmpfs); 0: delete after transcription
S2T_LOG_MAX_BYTES="${S2T_LOG_MAX_BYTES:-1048576}" # 1 MiB per active log file
S2T_LOG_KEEP="${S2T_LOG_KEEP:-3}" # rotated s2t.log.N files to keep
S2T_WHISPER_ARTIFACT_KEEP="${S2T_WHISPER_ARTIFACT_KEEP:-6}" # keep newest whisper_{id}.log/out files
S2T_WHISPER_LOG_MAX_BYTES="${S2T_WHISPER_LOG_MAX_BYTES:-524288}" # cap failed whisper logs to 512 KiB
S2T_RECORDER_LOG_MAX_BYTES="${S2T_RECORDER_LOG_MAX_BYTES:-131072}" # cap pw-record stderr/stdout log
S2T_RECORDER_LOG_KEEP="${S2T_RECORDER_LOG_KEEP:-2}" # rotated pw-record.log.N files to keep
S2T_MIN_AUDIO_SECONDS="${S2T_MIN_AUDIO_SECONDS:-0.001}" # treat <= this as empty/broken capture
S2T_DROP_WHEN_BUSY="${S2T_DROP_WHEN_BUSY:-1}" # 1: drop new stop/transcribe while previous transcribe still running
S2T_TRANSCRIBE_STALE_SEC="${S2T_TRANSCRIBE_STALE_SEC:-20}" # force-recover if a transcribe process hangs too long
S2T_TRANSCRIBE_ACQUIRE_RETRY_MS="${S2T_TRANSCRIBE_ACQUIRE_RETRY_MS:-1200}" # wait for lock release before dropping capture
S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD="${S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD:-2}" # consecutive capture failures before forcing default source
S2T_CAPTURE_DEFAULT_COOLDOWN_SEC="${S2T_CAPTURE_DEFAULT_COOLDOWN_SEC:-300}" # keep default source after repeated capture failures
S2T_AVOID_LOOPBACK_SOURCE="${S2T_AVOID_LOOPBACK_SOURCE:-1}" # 1: avoid snd_aloop/monitor sources when auto-detecting
S2T_AUDIO_TARGET_EXCLUDE_RE="${S2T_AUDIO_TARGET_EXCLUDE_RE:-snd_aloop|loopback|monitor}"
S2T_ENABLE_ALSA_CAPTURE_FALLBACK="${S2T_ENABLE_ALSA_CAPTURE_FALLBACK:-1}" # 1: if PipeWire has only loopback sources, record directly via arecord hw:X,Y
S2T_GOOGLE_SHORT_MODEL="${S2T_GOOGLE_SHORT_MODEL:-latest_short}"
S2T_GOOGLE_SHORT_AUDIO_SEC="${S2T_GOOGLE_SHORT_AUDIO_SEC:-4}"

# ASR provider selection:
# - local: use whisper-server (recommended) and fall back to whisper-cli
# - openai: use OpenAI Audio Transcriptions API and fall back to local
S2T_ASR_PROVIDER="${S2T_ASR_PROVIDER:-local}" # local|google|google-v2|openai|gcp-l4
S2T_NETWORK_ONLY="${S2T_NETWORK_ONLY:-0}" # 1: never fall back to local ASR
S2T_MAX_RESPONSE_SECONDS="${S2T_MAX_RESPONSE_SECONDS:-0}" # 0 disables cap; >0 clamps network ASR timeouts
S2T_OPENAI_BASE_URL="${S2T_OPENAI_BASE_URL:-https://api.openai.com/v1}"
S2T_OPENAI_MODEL="${S2T_OPENAI_MODEL:-gpt-4o-mini-transcribe}"
S2T_OPENAI_TIMEOUT_SEC="${S2T_OPENAI_TIMEOUT_SEC:-0}" # 0 disables timeout
S2T_GCP_WHISPER_URL="${S2T_GCP_WHISPER_URL:-}" # e.g. https://whisper-l4-xxxxx-uc.a.run.app
S2T_GCP_WHISPER_INFER_PATH="${S2T_GCP_WHISPER_INFER_PATH:-/inference}"
S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC="${S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC:-3}"
S2T_GCP_WHISPER_TIMEOUT_SEC="${S2T_GCP_WHISPER_TIMEOUT_SEC:-0}" # 0 disables timeout
S2T_GCP_WHISPER_DYNAMIC_TIMEOUT="${S2T_GCP_WHISPER_DYNAMIC_TIMEOUT:-1}" # 1: extend timeout for long utterances
S2T_GCP_WHISPER_TIMEOUT_PER_AUDIO_SEC="${S2T_GCP_WHISPER_TIMEOUT_PER_AUDIO_SEC:-0.5}" # added seconds per 1s audio when dynamic timeout is enabled
S2T_GCP_WHISPER_TIMEOUT_MAX_SEC="${S2T_GCP_WHISPER_TIMEOUT_MAX_SEC:-90}" # hard cap for dynamic cloud timeout (0 disables cap)
S2T_GCP_WHISPER_THREADS="${S2T_GCP_WHISPER_THREADS:-8}"
S2T_GCP_WHISPER_TRANSLATE="${S2T_GCP_WHISPER_TRANSLATE:-0}"
S2T_GCP_WHISPER_BEARER_TOKEN="${S2T_GCP_WHISPER_BEARER_TOKEN:-}"

# Google Cloud Speech-to-Text (v1 REST).
# Best for short utterances: latest_short
S2T_GOOGLE_API_ENDPOINT="${S2T_GOOGLE_API_ENDPOINT:-https://speech.googleapis.com/v1/speech:recognize}"
S2T_GOOGLE_MODEL="${S2T_GOOGLE_MODEL:-latest_short}"
S2T_GOOGLE_LANGUAGE_CODE="${S2T_GOOGLE_LANGUAGE_CODE:-ru-RU}"
S2T_GOOGLE_ALT_LANGUAGE_CODES="${S2T_GOOGLE_ALT_LANGUAGE_CODES-en-US}"
S2T_GOOGLE_ENABLE_PUNCTUATION="${S2T_GOOGLE_ENABLE_PUNCTUATION:-1}"
S2T_GOOGLE_CONNECT_TIMEOUT_SEC="${S2T_GOOGLE_CONNECT_TIMEOUT_SEC:-3}"
S2T_GOOGLE_TIMEOUT_SEC="${S2T_GOOGLE_TIMEOUT_SEC:-0}" # 0 disables timeout
S2T_GOOGLE_DYNAMIC_TIMEOUT="${S2T_GOOGLE_DYNAMIC_TIMEOUT:-1}" # 1: extend timeout for long utterances
S2T_GOOGLE_TIMEOUT_PER_AUDIO_SEC="${S2T_GOOGLE_TIMEOUT_PER_AUDIO_SEC:-0.25}" # added seconds per 1s of audio
S2T_GOOGLE_TIMEOUT_MAX_SEC="${S2T_GOOGLE_TIMEOUT_MAX_SEC:-20}" # hard cap for dynamic timeout (0 disables cap)
S2T_GOOGLE_RETRY_ON_EMPTY="${S2T_GOOGLE_RETRY_ON_EMPTY:-0}" # 1: retry latest_short -> latest_long on empty success
S2T_GOOGLE_RETRY_ON_SHORT="${S2T_GOOGLE_RETRY_ON_SHORT:-1}" # 1: if transcript is suspiciously short for audio, continue retry/fallback chain
S2T_GOOGLE_SHORT_RESULT_AUDIO_SEC="${S2T_GOOGLE_SHORT_RESULT_AUDIO_SEC:-4}" # guard activates above this audio duration
S2T_GOOGLE_MIN_CHARS_PER_AUDIO_SEC="${S2T_GOOGLE_MIN_CHARS_PER_AUDIO_SEC:-3.5}" # minimum non-space chars per second before marking result suspicious
S2T_SKIP_LOCAL_FALLBACK_ON_TIMEOUT="${S2T_SKIP_LOCAL_FALLBACK_ON_TIMEOUT:-1}" # 1: keep UI responsive on network timeout

# Dataset collection pipeline.
S2T_DATASET_ROOT="${S2T_DATASET_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/s2t/dataset}"
S2T_DATASET_RAW_DIR="${S2T_DATASET_RAW_DIR:-${S2T_DATASET_ROOT}/raw}"
S2T_DATASET_QUEUE_DIR="${S2T_DATASET_QUEUE_DIR:-${S2T_DATASET_ROOT}/queue}"
S2T_DATASET_PENDING_DIR="${S2T_DATASET_PENDING_DIR:-${S2T_DATASET_ROOT}/pending}"
S2T_DATASET_ENQUEUE_CORRECTION="${S2T_DATASET_ENQUEUE_CORRECTION:-1}" # 1: submit-correction enqueues ETL job files
S2T_DATASET_AUTO_SUBMIT_RAW="${S2T_DATASET_AUTO_SUBMIT_RAW:-0}" # 1: write ASR draft to raw/queue immediately; 0: keep only pending until submit-correction
S2T_DATASET_CLUSTER_ON_SUBMIT="${S2T_DATASET_CLUSTER_ON_SUBMIT:-1}" # 1: map one corrected text to the latest contiguous pending audio cluster
S2T_DATASET_MULTI_SEGMENT_GAP_SEC="${S2T_DATASET_MULTI_SEGMENT_GAP_SEC:-20}" # max pause gap between pending samples in one submit cluster
S2T_DATASET_MULTI_SEGMENT_MAX_COUNT="${S2T_DATASET_MULTI_SEGMENT_MAX_COUNT:-6}" # max pending samples to map in one submit
S2T_QUEUE_BACKEND="${S2T_QUEUE_BACKEND:-file}" # file|rabbitmq
S2T_RABBITMQ_PUBLISHER="${S2T_RABBITMQ_PUBLISHER:-/etc/s2t/scripts/rabbitmq_publish.py}"

ensure_writable_dir_or_fallback() {
    local requested="$1"
    local fallback="$2"
    local label="$3"

    if mkdir -p "$requested" >/dev/null 2>&1 && [ -w "$requested" ] && [ -x "$requested" ]; then
        printf '%s' "$requested"
        return 0
    fi

    if mkdir -p "$fallback" >/dev/null 2>&1 && [ -w "$fallback" ] && [ -x "$fallback" ]; then
        printf 'S2T: %s path "%s" is not writable; using "%s"\n' "$label" "$requested" "$fallback" >&2
        printf '%s' "$fallback"
        return 0
    fi

    printf '%s' "$requested"
}

DEFAULT_DATASET_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/s2t/dataset"
S2T_DATASET_ROOT="$(ensure_writable_dir_or_fallback "$S2T_DATASET_ROOT" "$DEFAULT_DATASET_ROOT" "dataset root")"
S2T_DATASET_RAW_DIR="$(ensure_writable_dir_or_fallback "$S2T_DATASET_RAW_DIR" "${S2T_DATASET_ROOT}/raw" "dataset raw dir")"
S2T_DATASET_QUEUE_DIR="$(ensure_writable_dir_or_fallback "$S2T_DATASET_QUEUE_DIR" "${S2T_DATASET_ROOT}/queue" "dataset queue dir")"
S2T_DATASET_PENDING_DIR="$(ensure_writable_dir_or_fallback "$S2T_DATASET_PENDING_DIR" "${S2T_DATASET_ROOT}/pending" "dataset pending dir")"

# Google Cloud Speech-to-Text (v2 REST) for Chirp models (requires OAuth/ADC; API keys won't work).
S2T_GCP_PROJECT="${S2T_GCP_PROJECT:-}"
S2T_GOOGLE_V2_LOCATION="${S2T_GOOGLE_V2_LOCATION:-global}"
S2T_GOOGLE_V2_RECOGNIZER="${S2T_GOOGLE_V2_RECOGNIZER:-_}" # "_" (implicit, global-only) or custom id
S2T_GOOGLE_V2_MODEL="${S2T_GOOGLE_V2_MODEL:-chirp_2}"
S2T_GOOGLE_V2_LANGUAGE_CODES="${S2T_GOOGLE_V2_LANGUAGE_CODES:-ru-RU}"
S2T_GOOGLE_V2_FALLBACK_LANGUAGE_CODES="${S2T_GOOGLE_V2_FALLBACK_LANGUAGE_CODES:-}" # e.g. en-US
S2T_GOOGLE_V2_ENABLE_PUNCTUATION="${S2T_GOOGLE_V2_ENABLE_PUNCTUATION:-1}"
S2T_GOOGLE_V2_TIMEOUT_SEC="${S2T_GOOGLE_V2_TIMEOUT_SEC:-0}" # 0 disables timeout
S2T_GOOGLE_V2_ON_EMPTY="${S2T_GOOGLE_V2_ON_EMPTY:-1}" # 1: when google(v1) returns empty, retry via google-v2 before local fallback
S2T_GOOGLE_APPLICATION_CREDENTIALS="${S2T_GOOGLE_APPLICATION_CREDENTIALS:-${GOOGLE_APPLICATION_CREDENTIALS:-}}"

is_positive_int() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

duration_gt() {
    local value="${1:-}"
    local threshold="${2:-0}"
    [ -n "$value" ] || return 1
    awk -v value="$value" -v threshold="$threshold" 'BEGIN { exit !(value + 0 > threshold + 0) }' </dev/null
}

compute_dynamic_timeout_sec() {
    local base="${1:-0}"
    local dynamic="${2:-1}"
    local audio_sec="${3:-}"
    local short_audio_sec="${4:-0}"
    local per_audio_sec="${5:-0}"
    local max_sec="${6:-0}"
    local timeout

    if ! is_positive_int "$base" || [ "$base" -le 0 ]; then
        printf '%s' "${base:-0}"
        return 0
    fi
    if [ "$dynamic" != "1" ] || ! duration_gt "$audio_sec" "$short_audio_sec"; then
        printf '%s' "$base"
        return 0
    fi

    timeout="$(awk -v base="$base" -v audio="$audio_sec" -v per="$per_audio_sec" '
        BEGIN {
            b = base + 0
            a = audio + 0
            p = per + 0
            if (p < 0) p = 0
            t = b + (a * p)
            if (t != int(t)) t = int(t) + 1
            else t = int(t)
            if (t < b) t = b
            printf "%d", t
        }' </dev/null)"

    if is_positive_int "$max_sec" && [ "$max_sec" -gt 0 ] && [ "$timeout" -gt "$max_sec" ]; then
        timeout="$max_sec"
    fi

    printf '%s' "$timeout"
}

compute_gcp_effective_timeout_sec() {
    local audio_sec="${1:-}"
    compute_dynamic_timeout_sec \
        "${S2T_GCP_WHISPER_TIMEOUT_SEC:-0}" \
        "${S2T_GCP_WHISPER_DYNAMIC_TIMEOUT:-1}" \
        "$audio_sec" \
        "${S2T_GOOGLE_SHORT_AUDIO_SEC:-4}" \
        "${S2T_GCP_WHISPER_TIMEOUT_PER_AUDIO_SEC:-0.5}" \
        "${S2T_GCP_WHISPER_TIMEOUT_MAX_SEC:-90}"
}

compute_server_effective_timeout_sec() {
    local audio_sec="${1:-}"
    compute_dynamic_timeout_sec \
        "${S2T_SERVER_TIMEOUT_SEC:-0}" \
        "${S2T_SERVER_DYNAMIC_TIMEOUT:-1}" \
        "$audio_sec" \
        "${S2T_GOOGLE_SHORT_AUDIO_SEC:-4}" \
        "${S2T_SERVER_TIMEOUT_PER_AUDIO_SEC:-0.5}" \
        "${S2T_SERVER_TIMEOUT_MAX_SEC:-90}"
}

compute_google_effective_timeout_sec() {
    local audio_sec="${1:-}"
    compute_dynamic_timeout_sec \
        "${S2T_GOOGLE_TIMEOUT_SEC:-0}" \
        "${S2T_GOOGLE_DYNAMIC_TIMEOUT:-1}" \
        "$audio_sec" \
        "${S2T_GOOGLE_SHORT_AUDIO_SEC:-4}" \
        "${S2T_GOOGLE_TIMEOUT_PER_AUDIO_SEC:-0.25}" \
        "${S2T_GOOGLE_TIMEOUT_MAX_SEC:-20}"
}

compute_google_effective_guard_sec() {
    local effective_timeout="${1:-0}"
    local guard="${S2T_MAX_RESPONSE_SECONDS:-0}"

    if ! is_positive_int "$guard" || [ "$guard" -le 0 ]; then
        printf '%s' "$guard"
        return 0
    fi
    if is_positive_int "$effective_timeout" && [ "$effective_timeout" -gt "$guard" ]; then
        guard="$effective_timeout"
    fi
    printf '%s' "$guard"
}

text_non_space_len() {
    local text="${1:-}"
    printf '%s' "$text" | tr -d '[:space:]' | wc -m | awk '{print $1}'
}

google_result_too_short_for_audio() {
    local text="${1:-}"
    local audio_sec="${2:-}"
    local compact_len min_chars

    if [ "$S2T_GOOGLE_RETRY_ON_SHORT" != "1" ]; then
        return 1
    fi
    if [ -z "${text//[[:space:]]/}" ] || [ -z "${audio_sec:-}" ]; then
        return 1
    fi
    if ! duration_gt "$audio_sec" "$S2T_GOOGLE_SHORT_RESULT_AUDIO_SEC"; then
        return 1
    fi

    compact_len="$(text_non_space_len "$text")"
    min_chars="$(awk -v sec="$audio_sec" -v rate="$S2T_GOOGLE_MIN_CHARS_PER_AUDIO_SEC" '
        BEGIN {
            r = rate + 0
            if (r <= 0) r = 3.5
            m = int((sec + 0) * r)
            if (m < 1) m = 1
            print m
        }' </dev/null)"
    [ "${compact_len:-0}" -lt "${min_chars:-1}" ]
}

if is_positive_int "$S2T_MAX_RESPONSE_SECONDS" && [ "$S2T_MAX_RESPONSE_SECONDS" -gt 0 ]; then
    if is_positive_int "$S2T_OPENAI_TIMEOUT_SEC" && [ "$S2T_OPENAI_TIMEOUT_SEC" -gt "$S2T_MAX_RESPONSE_SECONDS" ]; then
        S2T_OPENAI_TIMEOUT_SEC="$S2T_MAX_RESPONSE_SECONDS"
    fi
    if is_positive_int "$S2T_GCP_WHISPER_TIMEOUT_SEC" && [ "$S2T_GCP_WHISPER_TIMEOUT_SEC" -gt "$S2T_MAX_RESPONSE_SECONDS" ]; then
        S2T_GCP_WHISPER_TIMEOUT_SEC="$S2T_MAX_RESPONSE_SECONDS"
    fi
    if is_positive_int "$S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC" && [ "$S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC" -gt "$S2T_MAX_RESPONSE_SECONDS" ]; then
        S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC="$S2T_MAX_RESPONSE_SECONDS"
    fi
    if is_positive_int "$S2T_GOOGLE_TIMEOUT_SEC" && [ "$S2T_GOOGLE_TIMEOUT_SEC" -gt "$S2T_MAX_RESPONSE_SECONDS" ]; then
        S2T_GOOGLE_TIMEOUT_SEC="$S2T_MAX_RESPONSE_SECONDS"
    fi
    if is_positive_int "$S2T_GOOGLE_CONNECT_TIMEOUT_SEC" && [ "$S2T_GOOGLE_CONNECT_TIMEOUT_SEC" -gt "$S2T_MAX_RESPONSE_SECONDS" ]; then
        S2T_GOOGLE_CONNECT_TIMEOUT_SEC="$S2T_MAX_RESPONSE_SECONDS"
    fi
    if is_positive_int "$S2T_GOOGLE_V2_TIMEOUT_SEC" && [ "$S2T_GOOGLE_V2_TIMEOUT_SEC" -gt "$S2T_MAX_RESPONSE_SECONDS" ]; then
        S2T_GOOGLE_V2_TIMEOUT_SEC="$S2T_MAX_RESPONSE_SECONDS"
    fi
fi

file_size_bytes() {
    local file="$1"
    stat -c '%s' "$file" 2>/dev/null || echo 0
}

rotate_file_if_needed() {
    local file="$1"
    local max_bytes="$2"
    local keep_count="$3"
    local size i src dst

    [ -f "$file" ] || return 0
    is_positive_int "$max_bytes" || return 0
    is_positive_int "$keep_count" || keep_count=0

    size="$(file_size_bytes "$file")"
    if [ "$size" -lt "$max_bytes" ]; then
        return 0
    fi

    if [ "$keep_count" -gt 0 ]; then
        for i in $(seq "$keep_count" -1 1); do
            src="$file.$((i - 1))"
            dst="$file.$i"
            if [ "$i" -eq 1 ]; then
                src="$file"
            fi
            [ -f "$src" ] && mv -f "$src" "$dst"
        done
        : > "$file"
    else
        : > "$file"
    fi
}

cap_file_size() {
    local file="$1"
    local max_bytes="$2"
    local size

    [ -f "$file" ] || return 0
    is_positive_int "$max_bytes" || return 0

    size="$(file_size_bytes "$file")"
    if [ "$size" -le "$max_bytes" ]; then
        return 0
    fi

    tail -c "$max_bytes" "$file" > "${file}.tmp" 2>/dev/null || return 0
    mv -f "${file}.tmp" "$file"
}

prune_old_files() {
    local pattern="$1"
    local keep_count="$2"
    local idx=0
    local file

    is_positive_int "$keep_count" || keep_count=0

    while IFS= read -r file; do
        idx=$((idx + 1))
        if [ "$idx" -gt "$keep_count" ]; then
            rm -f -- "$file"
        fi
    done < <(ls -1t $pattern 2>/dev/null || true)
}

cleanup_transcribe_artifacts() {
    prune_old_files "$RUNTIME_DIR/whisper_*.log" "$S2T_WHISPER_ARTIFACT_KEEP"
    prune_old_files "$RUNTIME_DIR/whisper_out_*.txt" "$S2T_WHISPER_ARTIFACT_KEEP"
}

capture_fail_count() {
    local count
    count="$(cat "$CAPTURE_FAIL_FILE" 2>/dev/null || echo 0)"
    if is_positive_int "$count"; then
        printf '%s' "$count"
    else
        printf '0'
    fi
}

set_capture_fail_count() {
    local count="$1"
    is_positive_int "$count" || count=0
    printf '%s\n' "$count" >"$CAPTURE_FAIL_FILE" 2>/dev/null || true
}

increment_capture_fail_count() {
    local current
    current="$(capture_fail_count)"
    current=$((current + 1))
    set_capture_fail_count "$current"
    printf '%s' "$current"
}

reset_capture_fail_count() {
    rm -f "$CAPTURE_FAIL_FILE" 2>/dev/null || true
}

set_capture_default_until_now_plus() {
    local seconds="$1"
    local now until
    if ! is_positive_int "$seconds" || [ "$seconds" -le 0 ]; then
        return 0
    fi
    now="$(now_ms)"
    until=$((now + seconds * 1000))
    printf '%s\n' "$until" >"$CAPTURE_DEFAULT_UNTIL_FILE" 2>/dev/null || true
}

capture_default_mode_active() {
    local until now
    until="$(cat "$CAPTURE_DEFAULT_UNTIL_FILE" 2>/dev/null || true)"
    if ! [[ "${until:-}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    now="$(now_ms)"
    if [ "$now" -lt "$until" ]; then
        return 0
    fi
    rm -f "$CAPTURE_DEFAULT_UNTIL_FILE" 2>/dev/null || true
    return 1
}

terminate_pid_gracefully() {
    local pid="$1"

    if ! [[ "${pid:-}" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done

    kill -KILL "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
}

mark_transcribe_lock_owner() {
    local owner_file started_file
    owner_file="$TRANSCRIBE_LOCK_DIR/pid"
    started_file="$TRANSCRIBE_LOCK_DIR/started_ms"
    printf '%s\n' "$$" >"$owner_file" 2>/dev/null || true
    printf '%s\n' "$(now_ms)" >"$started_file" 2>/dev/null || true
}

acquire_transcribe_slot() {
    local owner_file owner_pid started_file owner_started now lock_age_ms stale_after_ms

    mkdir -p "$RUNTIME_DIR" >/dev/null 2>&1 || true
    owner_file="$TRANSCRIBE_LOCK_DIR/pid"
    started_file="$TRANSCRIBE_LOCK_DIR/started_ms"

    if mkdir "$TRANSCRIBE_LOCK_DIR" 2>/dev/null; then
        mark_transcribe_lock_owner
        return 0
    fi

    owner_pid="$(cat "$owner_file" 2>/dev/null || true)"
    if [[ "${owner_pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
        if is_positive_int "$S2T_TRANSCRIBE_STALE_SEC" && [ "$S2T_TRANSCRIBE_STALE_SEC" -gt 0 ]; then
            owner_started="$(cat "$started_file" 2>/dev/null || true)"
            if [[ "${owner_started:-}" =~ ^[0-9]+$ ]]; then
                now="$(now_ms)"
                lock_age_ms=0
                if [ "$now" -ge "$owner_started" ]; then
                    lock_age_ms=$((now - owner_started))
                fi
                stale_after_ms=$((S2T_TRANSCRIBE_STALE_SEC * 1000))
                if [ "$lock_age_ms" -ge "$stale_after_ms" ]; then
                    log "transcribe: stale lock owner pid=$owner_pid age_ms=$lock_age_ms, forcing recovery"
                    terminate_pid_gracefully "$owner_pid"
                fi
            fi
        fi
        if kill -0 "$owner_pid" 2>/dev/null; then
            return 1
        fi
    fi

    rm -rf "$TRANSCRIBE_LOCK_DIR" 2>/dev/null || true
    if mkdir "$TRANSCRIBE_LOCK_DIR" 2>/dev/null; then
        mark_transcribe_lock_owner
        return 0
    fi

    return 1
}

release_transcribe_slot() {
    local owner_file owner_pid
    owner_file="$TRANSCRIBE_LOCK_DIR/pid"
    owner_pid="$(cat "$owner_file" 2>/dev/null || true)"
    if [ -n "${owner_pid:-}" ] && [ "$owner_pid" != "$$" ]; then
        return 0
    fi
    rm -rf "$TRANSCRIBE_LOCK_DIR" 2>/dev/null || true
}

is_recording_or_transcribing() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ "${pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    if transcribe_slot_busy; then
        return 0
    fi
    return 1
}

transcribe_slot_busy() {
    local owner_file owner_pid
    owner_file="$TRANSCRIBE_LOCK_DIR/pid"
    if [ ! -d "$TRANSCRIBE_LOCK_DIR" ]; then
        return 1
    fi
    owner_pid="$(cat "$owner_file" 2>/dev/null || true)"
    if [[ "${owner_pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
        return 0
    fi
    rm -rf "$TRANSCRIBE_LOCK_DIR" 2>/dev/null || true
    return 1
}

wait_for_transcribe_idle() {
    local timeout_ms="${1:-0}"
    local started_ms now elapsed_ms

    if ! is_positive_int "$timeout_ms" || [ "$timeout_ms" -le 0 ]; then
        transcribe_slot_busy
        return $?
    fi

    started_ms="$(now_ms)"
    while transcribe_slot_busy; do
        sleep 0.05
        now="$(now_ms)"
        if [ "$now" -lt "$started_ms" ]; then
            continue
        fi
        elapsed_ms=$((now - started_ms))
        if [ "$elapsed_ms" -ge "$timeout_ms" ]; then
            return 1
        fi
    done
    return 0
}

log() {
    mkdir -p "$RUNTIME_DIR" >/dev/null 2>&1 || true
    rotate_file_if_needed "$LOG_FILE" "$S2T_LOG_MAX_BYTES" "$S2T_LOG_KEEP"
    printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

logv() {
    if [ "$S2T_LOG_VERBOSE" = "1" ]; then
        log "$@"
    fi
}

sanitize_one_line_text() {
    local value="${1:-}"
    printf '%s\n' "$value" \
        | tr '\r\n' ' ' \
        | sed 's/[[:space:]][[:space:]]*/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

is_valid_wav_file() {
    local path="${1:-}"
    local hex
    [ -n "${path:-}" ] || return 1
    [ -f "$path" ] || return 1
    hex="$(dd if="$path" bs=12 count=1 2>/dev/null | od -An -t x1 | tr -d ' \n')"
    [ "${#hex}" -ge 24 ] || return 1
    [ "${hex:0:8}" = "52494646" ] || return 1
    [ "${hex:16:8}" = "57415645" ] || return 1
    return 0
}

record_training_sample() {
    local sample_id="$1"
    local audio_path="$2"
    local raw_text="$3"
    local pending_audio pending_raw pending_meta

    [ -n "${sample_id:-}" ] || return 0
    [ -f "$audio_path" ] || return 0
    if ! is_valid_wav_file "$audio_path"; then
        log "dataset: skip invalid wav sample_id=$sample_id audio=$audio_path"
        return 0
    fi

    mkdir -p "$S2T_DATASET_PENDING_DIR" >/dev/null 2>&1 || return 0

    pending_audio="$S2T_DATASET_PENDING_DIR/${sample_id}.wav"
    pending_raw="$S2T_DATASET_PENDING_DIR/${sample_id}.raw.txt"
    pending_meta="$S2T_DATASET_PENDING_DIR/${sample_id}.meta"

    if ! cp -f "$audio_path" "$pending_audio" 2>/dev/null; then
        log "dataset: failed to stage pending audio for sample_id=$sample_id"
        return 0
    fi

    printf '%s\n' "$raw_text" >"$pending_raw" 2>/dev/null || true
    {
        printf 'sample_id=%s\n' "$sample_id"
        printf 'audio=%s\n' "$pending_audio"
        printf 'raw_text=%s\n' "$pending_raw"
        printf 'created_ms=%s\n' "$(now_ms)"
    } >"$pending_meta" 2>/dev/null || true
    cp -f "$pending_meta" "$LAST_SAMPLE_META_FILE" 2>/dev/null || true
    logv "dataset: staged pending sample id=$sample_id (awaiting submit-correction)"

    # Optional debug mode: persist ASR draft immediately.
    # Normal training flow should keep data in pending until corrected text arrives.
    auto_submit_pending_raw "$sample_id" "$raw_text"
}

auto_submit_pending_raw() {
    local sample_id="$1"
    local raw_text="$2"
    local day partition_dir normalized_text audio_src audio_dst text_dst

    [ "${S2T_DATASET_AUTO_SUBMIT_RAW:-0}" = "1" ] || return 0
    [ -n "${sample_id:-}" ] || return 0

    normalized_text="$(sanitize_one_line_text "$raw_text")"
    [ -n "${normalized_text:-}" ] || return 0

    audio_src="$S2T_DATASET_PENDING_DIR/${sample_id}.wav"
    [ -f "$audio_src" ] || return 0

    day="$(date +%Y-%m-%d 2>/dev/null || echo unknown-date)"
    partition_dir="$S2T_DATASET_RAW_DIR/$day"
    mkdir -p "$partition_dir" >/dev/null 2>&1 || return 0

    audio_dst="$partition_dir/${sample_id}.wav"
    text_dst="$partition_dir/${sample_id}.txt"
    cp -f "$audio_src" "$audio_dst" 2>/dev/null || return 0
    printf '%s\n' "$normalized_text" >"$text_dst" 2>/dev/null || true

    if [ "$S2T_DATASET_ENQUEUE_CORRECTION" = "1" ]; then
        if enqueue_dataset_job "$sample_id" "$audio_dst" "$text_dst"; then
            log "dataset: auto-submitted sample_id=$sample_id audio=$audio_dst text=$text_dst (queued)"
        else
            log "dataset: auto-submit queue write failed sample_id=$sample_id"
        fi
    else
        log "dataset: auto-submitted sample_id=$sample_id audio=$audio_dst text=$text_dst (queue disabled)"
    fi
}

extract_meta_value() {
    local file="$1"
    local key="$2"
    if [ ! -f "$file" ]; then
        return 1
    fi
    sed -n "s/^${key}=//p" "$file" | head -n1
}

latest_pending_sample_id() {
    local meta sample_id latest_meta

    meta="$LAST_SAMPLE_META_FILE"
    if [ ! -f "$meta" ]; then
        latest_meta="$(ls -1t "$S2T_DATASET_PENDING_DIR"/*.meta 2>/dev/null | head -n1 || true)"
        if [ -n "${latest_meta:-}" ]; then
            meta="$latest_meta"
        fi
    fi

    sample_id="$(extract_meta_value "$meta" "sample_id" || true)"
    if [ -n "${sample_id:-}" ]; then
        printf '%s' "$sample_id"
        return 0
    fi
    return 1
}

pending_sample_ids_for_submit() {
    local requested_id="${1:-}"

    if [ "${S2T_DATASET_CLUSTER_ON_SUBMIT:-1}" != "1" ]; then
        if [ -n "$requested_id" ]; then
            printf '%s\n' "$requested_id"
            return 0
        fi
        latest_pending_sample_id || return 1
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        if [ -n "$requested_id" ]; then
            printf '%s\n' "$requested_id"
            return 0
        fi
        latest_pending_sample_id || return 1
        return 0
    fi

    python3 - "$S2T_DATASET_PENDING_DIR" "$LAST_SAMPLE_META_FILE" "${S2T_DATASET_MULTI_SEGMENT_GAP_SEC:-20}" "${S2T_DATASET_MULTI_SEGMENT_MAX_COUNT:-6}" "$requested_id" <<'PY'
import glob
import pathlib
import sys

pending_dir = pathlib.Path(sys.argv[1])
last_meta = pathlib.Path(sys.argv[2])
requested_id = sys.argv[5].strip()

try:
    gap_sec = float(sys.argv[3])
except Exception:
    gap_sec = 20.0

try:
    max_count = int(sys.argv[4])
except Exception:
    max_count = 6

if max_count < 0:
    max_count = 0

gap_ms = int(gap_sec * 1000.0)


def parse_meta(path: pathlib.Path):
    sample_id = ""
    created_ms = -1
    try:
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if line.startswith("sample_id="):
                sample_id = line.split("=", 1)[1].strip()
            elif line.startswith("created_ms="):
                value = line.split("=", 1)[1].strip()
                if value.isdigit():
                    created_ms = int(value)
    except Exception:
        return None
    if not sample_id or created_ms < 0:
        return None
    return (created_ms, sample_id)


items = []
for meta in glob.glob(str(pending_dir / "*.meta")):
    parsed = parse_meta(pathlib.Path(meta))
    if parsed is not None:
        items.append(parsed)

if not items:
    raise SystemExit(1)

items.sort()
ids = [sid for _, sid in items]

anchor_id = ""
if requested_id:
    if requested_id in ids:
        anchor_id = requested_id
    else:
        raise SystemExit(1)
elif last_meta.is_file():
    parsed_last = parse_meta(last_meta)
    if parsed_last is not None and parsed_last[1] in ids:
        anchor_id = parsed_last[1]

if not anchor_id:
    anchor_id = items[-1][1]

anchor_idx = next((i for i in range(len(items) - 1, -1, -1) if items[i][1] == anchor_id), len(items) - 1)
anchor_created = items[anchor_idx][0]

if gap_ms <= 0:
    print(anchor_id)
    raise SystemExit(0)

selected = [(anchor_created, anchor_id)]
cursor_created = anchor_created

for idx in range(anchor_idx - 1, -1, -1):
    created_ms, sample_id = items[idx]
    if cursor_created - created_ms > gap_ms:
        break
    selected.append((created_ms, sample_id))
    cursor_created = created_ms
    if max_count > 0 and len(selected) >= max_count:
        break

selected.sort()
for _, sample_id in selected:
    print(sample_id)
PY
}

enqueue_dataset_job_file() {
    local sample_id="$1"
    local audio_path="$2"
    local text_path="$3"
    local job_file

    mkdir -p "$S2T_DATASET_QUEUE_DIR" >/dev/null 2>&1 || return 1
    job_file="$S2T_DATASET_QUEUE_DIR/$(now_ms)_${sample_id}.job"

    {
        printf 'sample_id=%s\n' "$sample_id"
        printf 'audio=%s\n' "$audio_path"
        printf 'text=%s\n' "$text_path"
        printf 'queued_ms=%s\n' "$(now_ms)"
    } >"$job_file"
}

enqueue_dataset_job_rabbit() {
    local sample_id="$1"
    local audio_path="$2"
    local text_path="$3"
    local queued_ms

    queued_ms="$(now_ms)"
    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi
    if [ ! -f "$S2T_RABBITMQ_PUBLISHER" ]; then
        return 1
    fi

    python3 "$S2T_RABBITMQ_PUBLISHER" \
        --sample-id "$sample_id" \
        --audio "$audio_path" \
        --text "$text_path" \
        --queued-ms "$queued_ms" >/dev/null 2>&1
}

enqueue_dataset_job() {
    local sample_id="$1"
    local audio_path="$2"
    local text_path="$3"

    if [ "${S2T_QUEUE_BACKEND:-file}" = "rabbitmq" ]; then
        if enqueue_dataset_job_rabbit "$sample_id" "$audio_path" "$text_path"; then
            return 0
        fi
        log "dataset: rabbitmq enqueue failed sample_id=$sample_id backend_fallback=file"
    fi

    enqueue_dataset_job_file "$sample_id" "$audio_path" "$text_path"
}

submit_correction() {
    local sample_id=""
    local corrected_text=""
    local audio_src audio_dst text_dst sid
    local day partition_dir normalized_text current_last_id
    local -a sample_ids=()
    local -a processed_ids=()
    local processed_count=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --id)
                sample_id="${2:-}"
                shift 2
                ;;
            --text)
                corrected_text="${2:-}"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
    done

    if [ -z "${corrected_text:-}" ] && [ "$#" -gt 0 ]; then
        corrected_text="$*"
    fi
    if [ -z "${corrected_text:-}" ] && [ ! -t 0 ]; then
        corrected_text="$(cat || true)"
    fi
    normalized_text="$(sanitize_one_line_text "$corrected_text")"
    if [ -z "${normalized_text:-}" ]; then
        log "dataset: submit-correction rejected: empty corrected text"
        echo "submit-correction: empty corrected text" >&2
        return 1
    fi

    if ! mapfile -t sample_ids < <(pending_sample_ids_for_submit "$sample_id"); then
        sample_ids=()
    fi
    if [ "${#sample_ids[@]}" -eq 0 ]; then
        log "dataset: submit-correction rejected: no pending sample id"
        echo "submit-correction: no pending sample id" >&2
        return 1
    fi

    day="$(date +%Y-%m-%d 2>/dev/null || echo unknown-date)"
    partition_dir="$S2T_DATASET_RAW_DIR/$day"
    mkdir -p "$partition_dir" >/dev/null 2>&1 || {
        log "dataset: submit-correction rejected: cannot create dataset dir: $partition_dir"
        echo "submit-correction: cannot create dataset dir: $partition_dir" >&2
        return 1
    }

    for sid in "${sample_ids[@]}"; do
        audio_src="$S2T_DATASET_PENDING_DIR/${sid}.wav"
        if [ ! -f "$audio_src" ]; then
            log "dataset: submit-correction skipped: pending audio not found sample_id=$sid"
            continue
        fi

        audio_dst="$partition_dir/${sid}.wav"
        text_dst="$partition_dir/${sid}.txt"
        cp -f "$audio_src" "$audio_dst"
        printf '%s\n' "$normalized_text" >"$text_dst"

        if [ "$S2T_DATASET_ENQUEUE_CORRECTION" = "1" ]; then
            if enqueue_dataset_job "$sid" "$audio_dst" "$text_dst"; then
                log "dataset: correction submitted sample_id=$sid audio=$audio_dst text=$text_dst (queued)"
            else
                log "dataset: correction submitted sample_id=$sid but queue write failed"
            fi
        else
            log "dataset: correction submitted sample_id=$sid audio=$audio_dst text=$text_dst (queue disabled)"
        fi

        rm -f "$S2T_DATASET_PENDING_DIR/${sid}.wav" \
            "$S2T_DATASET_PENDING_DIR/${sid}.raw.txt" \
            "$S2T_DATASET_PENDING_DIR/${sid}.meta" 2>/dev/null || true

        processed_ids+=("$sid")
        processed_count=$((processed_count + 1))
        printf '%s\n' "$text_dst"
    done

    if [ "$processed_count" -eq 0 ]; then
        log "dataset: submit-correction rejected: no pending audio files found for selected sample ids"
        echo "submit-correction: no pending audio found for selected sample ids" >&2
        return 1
    fi

    current_last_id="$(extract_meta_value "$LAST_SAMPLE_META_FILE" "sample_id" || true)"
    for sid in "${processed_ids[@]}"; do
        if [ "$current_last_id" = "$sid" ]; then
            rm -f "$LAST_SAMPLE_META_FILE" 2>/dev/null || true
            break
        fi
    done

    if [ "$processed_count" -gt 1 ]; then
        log "dataset: correction mapped to multi-segment cluster count=$processed_count ids=${processed_ids[*]}"
    fi

    return 0
}

sleep_ms() {
    local ms="${1:-0}"
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<PY
import time
time.sleep(${ms} / 1000.0)
PY
        return 0
    fi
    # crude fallback
    sleep "0.$(printf '%03d' "$ms")" 2>/dev/null || sleep 0.1
}

focused_wm_class_x11() {
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        return 1
    fi
    if ! command -v xdotool >/dev/null 2>&1; then
        return 1
    fi
    xdotool getwindowfocus getwindowclassname 2>/dev/null || true
}

focused_window_id_x11() {
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        return 1
    fi
    if ! command -v xdotool >/dev/null 2>&1; then
        return 1
    fi
    xdotool getwindowfocus 2>/dev/null || true
}

focused_wm_title_x11() {
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        return 1
    fi
    if ! command -v xdotool >/dev/null 2>&1; then
        return 1
    fi
    xdotool getwindowfocus getwindowname 2>/dev/null || true
}

is_terminal_class() {
    local cls="${1:-}"
    cls="${cls,,}"
    case "$cls" in
        *gnome-terminal*|*terminal*|*kitty*|*alacritty*|*wezterm*|*tilix*|*konsole*|*xterm*|*rxvt*|*st-*|*foot*)
            return 0
            ;;
    esac
    return 1
}

is_vscodium_terminal_focus() {
    local cls="${1:-}"
    local title="${2:-}"
    local cls_lc title_lc

    cls_lc="${cls,,}"
    title_lc="${title,,}"

    case "$cls_lc" in
        *vscodium*|*code*|*codium*)
            ;;
        *)
            return 1
            ;;
    esac

    case "$title_lc" in
        *terminal*|*терминал*|*tmux*|*bash*|*zsh*|*fish*)
            return 0
            ;;
    esac
    return 1
}

select_paste_keys() {
    if [ "$S2T_PASTE_KEYS" != "auto" ]; then
        printf '%s' "$S2T_PASTE_KEYS"
        return 0
    fi

    local cls title
    cls="$(focused_wm_class_x11 || true)"
    title="$(focused_wm_title_x11 || true)"
    if [ -n "${cls:-}" ]; then
        if is_terminal_class "$cls"; then
            printf '%s' "$S2T_PASTE_KEYS_TERMINAL"
        elif is_vscodium_terminal_focus "$cls" "$title"; then
            printf '%s' "$S2T_PASTE_KEYS_TERMINAL"
        else
            printf '%s' "$S2T_PASTE_KEYS_GUI"
        fi
        return 0
    fi

    printf '%s' "$S2T_PASTE_KEYS_FALLBACK"
}

now_ms() {
    # GNU date supports %N. If not available, fall back to python.
    local ms
    ms="$(date +%s%3N 2>/dev/null || true)"
    if [[ "$ms" =~ ^[0-9]+$ ]]; then
        printf '%s' "$ms"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
        return 0
    fi
    date +%s 2>/dev/null | awk '{print $1 "000"}'
}

# We assume binaries are in PATH due to nix profile wrapper or direct call
# Prefer the Nix build output from this project if present.
S2T_PREPEND_RESULT_BIN="${S2T_PREPEND_RESULT_BIN:-1}"
if [ "$S2T_PREPEND_RESULT_BIN" = "1" ] && [ -d /etc/s2t/result/bin ]; then
    PATH="/etc/s2t/result/bin:$PATH"
fi

notify() {
    if [ "$S2T_NOTIFY" != "1" ]; then
        return 0
    fi
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "$@" || true
    else
        printf '%s\n' "$*" >&2
    fi
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        notify "S2T" "Missing dependency: $cmd"
        exit 1
    fi
}

ensure_model() {
    if [ ! -f "$MODEL_PATH" ]; then
        log "model: downloading to $MODEL_PATH"
        mkdir -p "$(dirname "$MODEL_PATH")"
        require_cmd curl
        curl -L --fail "$MODEL_URL" -o "$MODEL_PATH"
    fi
}

list_pactl_sources() {
    if ! command -v pactl >/dev/null 2>&1; then
        return 1
    fi
    pactl list short sources 2>/dev/null | awk '{print $2}'
}

pactl_source_exists() {
    local wanted="$1"
    [ -n "${wanted:-}" ] || return 1
    list_pactl_sources | grep -Fxq -- "$wanted"
}

first_non_excluded_pactl_source() {
    local source
    while IFS= read -r source; do
        [ -n "${source:-}" ] || continue
        if [ -n "${S2T_AUDIO_TARGET_EXCLUDE_RE:-}" ] && printf '%s\n' "$source" | grep -Eiq -- "$S2T_AUDIO_TARGET_EXCLUDE_RE"; then
            continue
        fi
        printf '%s' "$source"
        return 0
    done < <(list_pactl_sources)
    return 1
}

detect_audio_target() {
    local node_name node_id node_desc alsa_driver configured_name fallback_source

    # Prefer explicit config.
    if [ -n "${S2T_AUDIO_TARGET:-}" ]; then
        logv "audio: explicit target from env S2T_AUDIO_TARGET='$S2T_AUDIO_TARGET'"
        printf '%s' "$S2T_AUDIO_TARGET"
        return 0
    fi

    is_excluded_source() {
        local value="$1"
        [ -n "${S2T_AUDIO_TARGET_EXCLUDE_RE:-}" ] || return 1
        printf '%s\n' "$value" | grep -Eiq -- "$S2T_AUDIO_TARGET_EXCLUDE_RE"
    }

    # Best-effort: ask WirePlumber for the default audio source node name.
    if command -v wpctl >/dev/null 2>&1; then
        node_name="$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | sed -n 's/^[[:space:]]*\* node\.name = \"\(.*\)\"$/\1/p' | head -n1)"
        node_desc="$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | sed -n 's/^[[:space:]]*\* node\.description = \"\(.*\)\"$/\1/p' | head -n1)"
        alsa_driver="$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | sed -n 's/^[[:space:]]*alsa\.driver_name = \"\(.*\)\"$/\1/p' | head -n1)"
        if [ -n "${node_name:-}" ]; then
            logv "audio: default source node='${node_name}' desc='${node_desc:-?}' driver='${alsa_driver:-?}'"
        fi

        if [ "$S2T_AVOID_LOOPBACK_SOURCE" = "1" ] && [ -n "${node_name:-}" ] && is_excluded_source "$node_name"; then
            log "audio: default source '$node_name' looks loopback/monitor; trying non-loopback source"
            fallback_source="$(first_non_excluded_pactl_source || true)"
            if [ -n "${fallback_source:-}" ]; then
                log "audio: fallback source from pactl -> $fallback_source"
                printf '%s' "$fallback_source"
                return 0
            fi
            configured_name="$(wpctl status 2>/dev/null | sed -n 's/^[[:space:]]*[0-9]\+\.[[:space:]]*Audio\/Source[[:space:]]\+\(.*\)$/\1/p' | head -n1)"
            if [ -n "${configured_name:-}" ] && ! is_excluded_source "$configured_name" && pactl_source_exists "$configured_name"; then
                log "audio: fallback source from wpctl status -> $configured_name"
                printf '%s' "$configured_name"
                return 0
            fi
            if [ -n "${configured_name:-}" ] && ! pactl_source_exists "$configured_name"; then
                logv "audio: wpctl configured source '$configured_name' is not present in current sources"
            fi
            log "audio: no non-loopback source found; leaving pw-record target=default"
            return 2
        fi

        if [ -n "${node_name:-}" ]; then
            printf '%s' "$node_name"
            return 0
        fi
        node_id="$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | sed -n 's/^id \([0-9][0-9]*\),.*/\1/p' | head -n1)"
        if [ -n "${node_id:-}" ]; then
            logv "audio: using default source node id=$node_id"
            printf '%s' "$node_id"
            return 0
        fi
    fi

    log "audio: default source detection failed; using PipeWire default input"
    return 1
}

detect_alsa_capture_device() {
    if ! command -v arecord >/dev/null 2>&1; then
        return 1
    fi
    arecord -l 2>/dev/null \
        | awk '
            /^card [0-9]+:/ {
                lower = tolower($0)
                if (lower ~ /loopback/) next
                card = ""
                device = ""
                if (match($0, /card [0-9]+/)) {
                    card = substr($0, RSTART + 5, RLENGTH - 5)
                }
                if (match($0, /device [0-9]+/)) {
                    device = substr($0, RSTART + 7, RLENGTH - 7)
                }
                if (card != "" && device != "") {
                    printf "plughw:%s,%s\n", card, device
                    exit
                }
            }
        ' | head -n1
}

attempt_start_recorder() {
    local recorder_label="$1"
    shift
    local recorder_pid
    local -a record_cmd=( "$@" )

    rotate_file_if_needed "$RECORDER_LOG_FILE" "$S2T_RECORDER_LOG_MAX_BYTES" "$S2T_RECORDER_LOG_KEEP"
    if is_positive_int "$S2T_MAX_RECORD_SECONDS" && [ "$S2T_MAX_RECORD_SECONDS" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        log "start: spawning ${recorder_label} (max ${S2T_MAX_RECORD_SECONDS}s)"
        timeout --signal=TERM "${S2T_MAX_RECORD_SECONDS}s" "${record_cmd[@]}" >>"$RECORDER_LOG_FILE" 2>&1 &
    else
        log "start: spawning ${recorder_label}"
        "${record_cmd[@]}" >>"$RECORDER_LOG_FILE" 2>&1 &
    fi
    recorder_pid=$!

    # If recorder dies immediately we otherwise get random header-only files later.
    sleep 0.08
    if ! kill -0 "$recorder_pid" 2>/dev/null; then
        log "start: ${recorder_label} exited immediately pid=$recorder_pid (see $RECORDER_LOG_FILE)"
        return 1
    fi

    PID="$recorder_pid"
    echo "$PID" > "$PID_FILE"
    echo "$(now_ms)" > "$START_TS_FILE"
    echo "$recorder_label" > "$RECORDER_KIND_FILE"
    return 0
}

start_recording() {
    if [ -f "$PID_FILE" ]; then
        existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "${existing_pid:-}" ] && kill -0 "$existing_pid" 2>/dev/null; then
            # Already recording
            exit 0
        fi
        # Stale PID file from crashed recorder.
        rm -f "$PID_FILE" "$START_TS_FILE" "$RECORDER_KIND_FILE"
    fi
    
    mkdir -p "$RUNTIME_DIR"
    logv "start: ctx uid=$(id -u 2>/dev/null || echo ?) user=$(id -un 2>/dev/null || echo ?) session=${XDG_SESSION_TYPE:-?} display=${DISPLAY:-?} wayland=${WAYLAND_DISPLAY:-?} insert=${S2T_INSERT_METHOD}"

    rm -f "$AUDIO_FILE"

    # Use pipewire record
    # Format s16le 16kHz mono
    local capture_fail_streak force_default_target recorder_backend alsa_device target_rc recorder_label
    capture_fail_streak="$(capture_fail_count)"
    force_default_target=0
    recorder_backend="pipewire"
    recorder_label="pw-record"
    alsa_device=""
    if capture_default_mode_active; then
        force_default_target=1
        log "start: capture fallback cooldown active, forcing pw-record target=default"
    elif is_positive_int "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" \
        && [ "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" -gt 0 ] \
        && [ "$capture_fail_streak" -ge "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" ]; then
        force_default_target=1
    fi

    TARGET_ARGS=()
    if [ "$force_default_target" = "1" ]; then
        log "start: capture fail streak=$capture_fail_streak, forcing pw-record target=default"
    elif target="$(detect_audio_target)"; then
        TARGET_ARGS+=(--target "$target")
        log "start: pw-record target=$target"
    else
        target_rc=$?
        if [ "$S2T_ENABLE_ALSA_CAPTURE_FALLBACK" = "1" ] && [ "$target_rc" -eq 2 ]; then
            alsa_device="$(detect_alsa_capture_device || true)"
            if [ -n "${alsa_device:-}" ]; then
                recorder_backend="alsa"
                log "start: no valid PipeWire source; using arecord fallback device=$alsa_device"
            else
                log "start: pw-record target=default"
            fi
        else
            log "start: pw-record target=default"
        fi
    fi

    local recorder_started=0
    if [ "$recorder_backend" = "alsa" ]; then
        require_cmd arecord
        recorder_label="arecord"
        RECORD_CMD=(arecord -q -D "$alsa_device" -f S16_LE -r 16000 -c 1 -t wav "$AUDIO_FILE")
    else
        require_cmd pw-record
        RECORD_CMD=(pw-record --format=s16 --rate=16000 --channels=1 "${TARGET_ARGS[@]}" "$AUDIO_FILE")
    fi

    if attempt_start_recorder "$recorder_label" "${RECORD_CMD[@]}"; then
        recorder_started=1
    elif [ "$recorder_backend" = "pipewire" ] && [ "${#TARGET_ARGS[@]}" -gt 0 ]; then
        # PipeWire node names can disappear between detection and start; retry on default source.
        log "start: retrying pw-record without explicit target"
        RECORD_CMD=(pw-record --format=s16 --rate=16000 --channels=1 "$AUDIO_FILE")
        if attempt_start_recorder "pw-record" "${RECORD_CMD[@]}"; then
            recorder_started=1
        fi
    fi

    if [ "$recorder_started" != "1" ] && [ "$recorder_backend" = "pipewire" ] && [ "$S2T_ENABLE_ALSA_CAPTURE_FALLBACK" = "1" ]; then
        alsa_device="$(detect_alsa_capture_device || true)"
        if [ -n "${alsa_device:-}" ]; then
            log "start: retrying with arecord fallback device=$alsa_device"
            RECORD_CMD=(arecord -q -D "$alsa_device" -f S16_LE -r 16000 -c 1 -t wav "$AUDIO_FILE")
            if command -v arecord >/dev/null 2>&1 && attempt_start_recorder "arecord" "${RECORD_CMD[@]}"; then
                recorder_started=1
            fi
        fi
    fi

    if [ "$recorder_started" != "1" ]; then
        rm -f "$PID_FILE" "$START_TS_FILE" "$RECORDER_KIND_FILE"
        rm -f "$AUDIO_FILE" 2>/dev/null || true
        notify "S2T" "Recorder failed to start"
        exit 1
    fi
    
    # Visual feedback
    block_input_feedback
    notify -t 800 -h string:x-canonical-private-synchronous:s2t "Listening..."
}

save_secondary_buffer_text() {
    local text="$1"
    local source_id="${2:-}"
    [ "${S2T_SECONDARY_BUFFER_ENABLE:-1}" = "1" ] || return 0

    mkdir -p "$RUNTIME_DIR" >/dev/null 2>&1 || true
    printf '%s' "$text" >"$SECONDARY_TEXT_FILE" 2>/dev/null || return 1
    printf 'updated_ms=%s\nsource_id=%s\n' "$(now_ms)" "$source_id" >"$SECONDARY_META_FILE" 2>/dev/null || true

    # Mirror to X11 SECONDARY selection for power users/tools.
    if [ "${XDG_SESSION_TYPE:-}" != "wayland" ] && command -v xclip >/dev/null 2>&1; then
        printf '%s' "$text" | timeout 1s xclip -selection secondary >/dev/null 2>&1 || true
    fi
    return 0
}

load_secondary_buffer_text() {
    local text=""
    [ "${S2T_SECONDARY_BUFFER_ENABLE:-1}" = "1" ] || return 1

    if [ -f "$SECONDARY_TEXT_FILE" ]; then
        text="$(cat "$SECONDARY_TEXT_FILE" 2>/dev/null || true)"
        if [ -n "${text:-}" ]; then
            printf '%s' "$text"
            return 0
        fi
    fi

    # Fallback: try X11 SECONDARY selection.
    if [ "${XDG_SESSION_TYPE:-}" != "wayland" ] && command -v xclip >/dev/null 2>&1; then
        text="$(timeout 1s xclip -selection secondary -o 2>/dev/null || true)"
        if [ -n "${text:-}" ]; then
            printf '%s' "$text"
            return 0
        fi
    fi

    return 1
}

secondary_clear() {
    rm -f "$SECONDARY_TEXT_FILE" 2>/dev/null || true
    rm -f "$SECONDARY_META_FILE" 2>/dev/null || true
    if [ "${XDG_SESSION_TYPE:-}" != "wayland" ] && command -v xclip >/dev/null 2>&1; then
        printf '' | timeout 1s xclip -selection secondary >/dev/null 2>&1 || true
    fi
    log "manual-secondary: clear"
    notify -t 600 "S2T secondary cleared"
}

secondary_copy_buffer() {
    local text
    text="$(load_secondary_buffer_text || true)"
    if [ -z "${text//[[:space:]]/}" ]; then
        log "manual-secondary: copy requested but buffer is empty"
        notify -t 800 "S2T secondary is empty"
        return 1
    fi

    if save_secondary_buffer_text "$text"; then
        log "manual-secondary: copied len=${#text}"
        notify -t 700 "S2T secondary copied"
        return 0
    fi
    log "manual-secondary: failed to copy (secondary unavailable)"
    notify -t 900 "S2T secondary unavailable"
    return 1
}

clipboard_read_to_file() {
    local out_file="$1"
    mkdir -p "$(dirname "$out_file")" >/dev/null 2>&1 || true

    if [ "${XDG_SESSION_TYPE:-}" = "x11" ] && command -v xclip >/dev/null 2>&1; then
        if timeout 1s xclip -selection clipboard -o >"$out_file" 2>/dev/null; then
            return 0
        fi
        : >"$out_file"
        return 0
    fi

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && command -v wl-paste >/dev/null 2>&1; then
        if timeout 1s wl-paste >"$out_file" 2>/dev/null; then
            return 0
        fi
        : >"$out_file"
        return 0
    fi

    return 1
}

clipboard_write_from_file() {
    local in_file="$1"
    if [ ! -f "$in_file" ]; then
        return 1
    fi

    if [ "${XDG_SESSION_TYPE:-}" = "x11" ] && command -v xclip >/dev/null 2>&1; then
        timeout 1s xclip -selection clipboard -i <"$in_file" >/dev/null 2>&1
        return $?
    fi

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && command -v wl-copy >/dev/null 2>&1; then
        timeout 1s wl-copy <"$in_file" >/dev/null 2>&1
        return $?
    fi

    return 1
}

clipboard_write_text() {
    local text="$1"
    local tmp_file
    tmp_file="$(mktemp "$RUNTIME_DIR/clipboard_text.XXXXXX")"
    printf '%s' "$text" >"$tmp_file"
    clipboard_write_from_file "$tmp_file"
    local rc=$?
    rm -f "$tmp_file" 2>/dev/null || true
    return $rc
}

restore_clipboard_with_retry() {
    local in_file="$1"
    local attempts="${2:-5}"
    local retry_delay_ms="${3:-80}"
    local i

    if [ ! -f "$in_file" ]; then
        return 1
    fi

    for i in $(seq 1 "$attempts"); do
        if clipboard_write_from_file "$in_file"; then
            return 0
        fi
        sleep_ms "$retry_delay_ms"
    done
    return 1
}

compute_clipboard_restore_delay_ms() {
    local text="$1"
    local base extra delay text_len per_char extra_max
    base="$S2T_CLIPBOARD_RESTORE_DELAY_MS"
    per_char="$S2T_CLIPBOARD_RESTORE_PER_CHAR_MS"
    extra_max="$S2T_CLIPBOARD_RESTORE_EXTRA_MAX_MS"
    text_len=${#text}

    if ! is_positive_int "$base"; then
        base=350
    fi
    if ! is_positive_int "$per_char"; then
        per_char=0
    fi
    if ! is_positive_int "$extra_max"; then
        extra_max=2500
    fi

    extra=0
    if [ "$per_char" -gt 0 ] && [ "$text_len" -gt 0 ]; then
        extra=$((text_len * per_char))
        if [ "$extra_max" -gt 0 ] && [ "$extra" -gt "$extra_max" ]; then
            extra="$extra_max"
        fi
    fi
    delay=$((base + extra))
    printf '%s' "$delay"
}

paste_clipboard_shortcut() {
    local keys cls title
    local type_timeout_sec timeout_cmd=()
    keys="$(select_paste_keys)"
    if [ "$S2T_DEBUG_TIMING" = "1" ] && [ "$S2T_PASTE_KEYS" = "auto" ]; then
        cls="$(focused_wm_class_x11 || true)"
        title="$(focused_wm_title_x11 || true)"
        log "insert: auto keys=${keys} wm_class=${cls:-unknown} wm_title=${title:-unknown}"
    fi
    refocus_target_window_before_insert

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        if command -v wtype >/dev/null 2>&1; then
            case "$keys" in
                shift+insert) wtype -M shift -P Insert -p Insert -m shift ;;
                ctrl+shift+v) wtype -M ctrl -M shift -P v -p v -m shift -m ctrl ;;
                *)            wtype -M ctrl -P v -p v -m ctrl ;;
            esac
            return 0
        fi
        if command -v ydotool >/dev/null 2>&1; then
            case "$keys" in
                shift+insert) ydotool key 42:1 110:1 110:0 42:0 ;;
                ctrl+shift+v) ydotool key 29:1 42:1 47:1 47:0 42:0 29:0 ;;
                *)            ydotool key 29:1 47:1 47:0 29:0 ;;
            esac
            return 0
        fi
        return 1
    fi

    type_timeout_sec="${S2T_X11_TYPE_TIMEOUT_SEC:-2}"
    if is_positive_int "$type_timeout_sec" && [ "$type_timeout_sec" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        timeout_cmd=(timeout --signal=TERM "${type_timeout_sec}s")
    fi

    if command -v xdotool >/dev/null 2>&1; then
        case "$keys" in
            shift+insert) "${timeout_cmd[@]}" xdotool key --clearmodifiers shift+Insert ;;
            ctrl+shift+v) "${timeout_cmd[@]}" xdotool key --clearmodifiers ctrl+shift+v ;;
            *)            "${timeout_cmd[@]}" xdotool key --clearmodifiers ctrl+v ;;
        esac
        return $?
    fi
    if command -v ydotool >/dev/null 2>&1; then
        case "$keys" in
            shift+insert) "${timeout_cmd[@]}" ydotool key 42:1 110:1 110:0 42:0 ;;
            ctrl+shift+v) "${timeout_cmd[@]}" ydotool key 29:1 42:1 47:1 47:0 42:0 29:0 ;;
            *)            "${timeout_cmd[@]}" ydotool key 29:1 47:1 47:0 29:0 ;;
        esac
        return $?
    fi
    return 1
}

x11_insert_via_clipboard_transport() {
    local text="$1"
    local prev_clip_file="$RUNTIME_DIR/clipboard_prev.txt"
    local preserve_ok=0
    local restore_delay_ms

    if [ "${XDG_SESSION_TYPE:-}" != "x11" ]; then
        return 1
    fi

    if [ "$S2T_PRESERVE_CLIPBOARD" = "1" ]; then
        if clipboard_read_to_file "$prev_clip_file"; then
            preserve_ok=1
        else
            log "insert: cannot snapshot clipboard before X11 transport"
            if [ "$S2T_PRESERVE_CLIPBOARD_STRICT" = "1" ]; then
                return 1
            fi
        fi
    fi

    if ! clipboard_write_text "$text"; then
        log "insert: failed to write temporary clipboard transport"
        return 1
    fi

    # Give X-server a moment to register the new selection owner
    sleep_ms 30

    if ! paste_clipboard_shortcut; then
        log "insert: paste shortcut failed"
        if [ "$preserve_ok" = "1" ]; then
            restore_clipboard_with_retry "$prev_clip_file" 6 80 || true
        fi
        return 1
    fi

    log "insert: pasted-via-clipboard-transport"
    if [ "$preserve_ok" = "1" ]; then
        # Extremely fast restoration
        sleep_ms "${S2T_CLIPBOARD_RESTORE_DELAY_MS:-50}"
        if ! restore_clipboard_with_retry "$prev_clip_file" 3 50; then
            log "insert: failed to restore previous clipboard after X11 transport"
        fi
    fi
    return 0
}

secondary_mode_allows_insert() {
    local mode="${1:-auto}"

    if [ "${XDG_SESSION_TYPE:-}" != "x11" ]; then
        return 0
    fi

    case "$mode" in
        manual)
            [ "${S2T_X11_SECONDARY_MANUAL_PASTE:-1}" = "1" ]
            ;;
        *)
            [ "${S2T_X11_SECONDARY_AUTO_INSERT:-0}" = "1" ]
            ;;
    esac
}

insert_from_secondary_buffer() {
    local text="$1"
    local mode="${2:-auto}"
    if [ -z "${text//[[:space:]]/}" ]; then
        return 1
    fi
    if ! secondary_mode_allows_insert "$mode"; then
        return 2
    fi
    if [ "${XDG_SESSION_TYPE:-}" = "x11" ]; then
        x11_insert_via_clipboard_transport "$text"
        return $?
    fi
    refocus_target_window_before_insert
    inject_text_without_clipboard "$text"
}

secondary_paste_to_focused_app() {
    local text
    local insert_rc=0
    local wait_ms
    wait_ms="${S2T_SECONDARY_WAIT_FOR_FRESH_MS:-12000}"

    if is_recording_or_transcribing; then
        log "manual-secondary: waiting for active record/transcribe before paste"
        if ! wait_for_transcribe_idle "$wait_ms"; then
            log "manual-secondary: paste refused; transcribe still in progress after ${wait_ms}ms"
            notify -t 900 "S2T still transcribing"
            return 1
        fi
    fi

    text="$(load_secondary_buffer_text || true)"
    if [ -z "${text//[[:space:]]/}" ]; then
        log "manual-secondary: paste requested but buffer is empty"
        notify -t 800 "S2T secondary is empty"
        return 1
    fi

    if insert_from_secondary_buffer "$text" manual; then
        log "manual-secondary: pasted via secondary buffer len=${#text}"
        notify -t 700 "S2T secondary typed"
        return 0
    else
        insert_rc=$?
    fi
    if [ "$insert_rc" -eq 2 ]; then
        log "manual-secondary: paste blocked on X11 (manual secondary paste disabled)"
        notify -t 900 "S2T secondary paste disabled on X11"
        return 1
    fi
    log "manual-secondary: paste failed (no injection tool)"
    notify -t 900 "S2T paste failed"
    return 1
}

inject_text_without_clipboard() {
    local text="$1"
    local type_timeout_sec timeout_cmd=()

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        if command -v wtype >/dev/null 2>&1; then
            wtype "$text"
            return 0
        fi
        if command -v ydotool >/dev/null 2>&1; then
            ydotool type "$text"
            return 0
        fi
        return 1
    fi

    type_timeout_sec="${S2T_X11_TYPE_TIMEOUT_SEC:-2}"
    if is_positive_int "$type_timeout_sec" && [ "$type_timeout_sec" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        timeout_cmd=(timeout --signal=TERM "${type_timeout_sec}s")
    fi

    if command -v xdotool >/dev/null 2>&1; then
        "${timeout_cmd[@]}" xdotool type --clearmodifiers --delay "$S2T_XDOTOOL_DELAY_MS" -- "$text"
        return $?
    fi
    if command -v ydotool >/dev/null 2>&1; then
        "${timeout_cmd[@]}" ydotool type "$text"
        return $?
    fi
    return 1
}

capture_target_window_for_insert() {
    local win_id
    if [ "${S2T_REFOCUS_TARGET_WINDOW:-1}" != "1" ]; then
        rm -f "$TARGET_WINDOW_FILE" 2>/dev/null || true
        return 0
    fi
    win_id="$(focused_window_id_x11 || true)"
    if [[ "${win_id:-}" =~ ^[0-9]+$ ]] && [ "$win_id" -gt 0 ]; then
        printf '%s\n' "$win_id" >"$TARGET_WINDOW_FILE" 2>/dev/null || true
        logv "insert: captured target_window_id=$win_id"
    else
        rm -f "$TARGET_WINDOW_FILE" 2>/dev/null || true
    fi
}

refocus_target_window_before_insert() {
    local win_id
    if [ "${S2T_REFOCUS_TARGET_WINDOW:-1}" != "1" ]; then
        return 0
    fi
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] || ! command -v xdotool >/dev/null 2>&1; then
        return 0
    fi
    win_id="$(cat "$TARGET_WINDOW_FILE" 2>/dev/null || true)"
    if ! [[ "${win_id:-}" =~ ^[0-9]+$ ]] || [ "$win_id" -le 0 ]; then
        return 0
    fi
    if xdotool windowactivate --sync "$win_id" >/dev/null 2>&1; then
        sleep_ms 40
        xdotool windowfocus "$win_id" >/dev/null 2>&1 || true
        logv "insert: refocused target_window_id=$win_id"
    else
        logv "insert: failed to refocus target_window_id=$win_id"
    fi
}


transcribe_with_server() {
    require_cmd curl
    require_cmd jq

    local audio_sec="${1:-}"
    local server_timeout_sec="$S2T_SERVER_TIMEOUT_SEC"
    # For local-first mode, do not cut long dictation by client-side timeout.
    # Keep timeout behavior only when local server is used as a fallback from cloud providers.
    if [ "$S2T_ASR_PROVIDER" = "local" ]; then
        server_timeout_sec=0
    else
        server_timeout_sec="$(compute_server_effective_timeout_sec "$audio_sec")"
    fi

    local curl_timeout_args=()
    if is_positive_int "$server_timeout_sec" && [ "$server_timeout_sec" -gt 0 ]; then
        curl_timeout_args=(--max-time "$server_timeout_sec")
    fi
    local response
    response="$(curl -sf "${curl_timeout_args[@]}" \
        -F "file=@${AUDIO_FILE};type=audio/wav" \
        "$S2T_WHISPER_SERVER_URL" \
        2>>"$LOG_FILE" || true)"

    if [ -z "${response//[[:space:]]/}" ]; then
        return 1
    fi

    printf '%s' "$response" | jq -r '.text // ""' 2>/dev/null || true
}

transcribe_with_openai() {
    require_cmd curl
    require_cmd jq

    if [ -z "${S2T_OPENAI_API_KEY:-}" ]; then
        log "asr: openai missing S2T_OPENAI_API_KEY"
        return 1
    fi

    local url="${S2T_OPENAI_BASE_URL%/}/audio/transcriptions"
    local curl_timeout_args=()
    if is_positive_int "$S2T_OPENAI_TIMEOUT_SEC" && [ "$S2T_OPENAI_TIMEOUT_SEC" -gt 0 ]; then
        curl_timeout_args=(--max-time "$S2T_OPENAI_TIMEOUT_SEC")
    fi
    local response
    response="$(curl -sf "${curl_timeout_args[@]}" \
        -H "Authorization: Bearer ${S2T_OPENAI_API_KEY}" \
        -F "file=@${AUDIO_FILE};type=audio/wav" \
        -F "model=${S2T_OPENAI_MODEL}" \
        -F "response_format=json" \
        "$url" \
        2>>"$LOG_FILE" || true)"

    if [ -z "${response//[[:space:]]/}" ]; then
        return 1
    fi

    printf '%s' "$response" | jq -r '.text // ""' 2>/dev/null || true
}

transcribe_with_gcp_l4() {
    require_cmd curl
    require_cmd jq

    local audio_sec="${1:-}"
    if [ -z "${S2T_GCP_WHISPER_URL//[[:space:]]/}" ]; then
        log "asr: gcp-l4 missing S2T_GCP_WHISPER_URL"
        return 1
    fi

    local infer_path="${S2T_GCP_WHISPER_INFER_PATH:-/inference}"
    if [ -z "${infer_path:-}" ]; then
        infer_path="/inference"
    elif [ "${infer_path#/}" = "$infer_path" ]; then
        infer_path="/${infer_path}"
    fi

    local url="${S2T_GCP_WHISPER_URL%/}${infer_path}"
    local language="${S2T_LANG:-auto}"
    local curl_timeout_args=()
    local curl_connect_args=()
    local curl_auth_args=()
    local curl_form_args=()
    local response

    if is_positive_int "$S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC" && [ "$S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC" -gt 0 ]; then
        curl_connect_args=(--connect-timeout "$S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC")
    fi
    local gcp_timeout_sec
    gcp_timeout_sec="$(compute_gcp_effective_timeout_sec "$audio_sec")"
    if is_positive_int "$gcp_timeout_sec" && [ "$gcp_timeout_sec" -gt 0 ]; then
        curl_timeout_args=(--max-time "$gcp_timeout_sec")
    fi
    if [ -n "${S2T_GCP_WHISPER_BEARER_TOKEN:-}" ]; then
        curl_auth_args=(-H "Authorization: Bearer ${S2T_GCP_WHISPER_BEARER_TOKEN}")
    fi

    curl_form_args=(-F "audio=@${AUDIO_FILE};type=audio/wav")
    if [ -n "${language//[[:space:]]/}" ]; then
        curl_form_args+=(-F "language=${language}")
    fi
    if [ "${S2T_GCP_WHISPER_TRANSLATE}" = "1" ]; then
        curl_form_args+=(-F "translate=true")
    else
        curl_form_args+=(-F "translate=false")
    fi
    if is_positive_int "$S2T_GCP_WHISPER_THREADS" && [ "$S2T_GCP_WHISPER_THREADS" -gt 0 ]; then
        curl_form_args+=(-F "threads=${S2T_GCP_WHISPER_THREADS}")
    fi

    response="$(curl -sf "${curl_connect_args[@]}" "${curl_timeout_args[@]}" "${curl_auth_args[@]}" \
        "${curl_form_args[@]}" \
        "$url" \
        2>>"$LOG_FILE" || true)"

    if [ -z "${response//[[:space:]]/}" ]; then
        return 1
    fi

    printf '%s' "$response" \
        | jq -r '.text // .result.text // .result.whisper.text // (.whisper.transcription // [] | map(.text // "") | join(" ")) // (.result.whisper.transcription // [] | map(.text // "") | join(" ")) // ""' 2>/dev/null \
        || true
}

transcribe_with_google() {
    require_cmd python3

    if [ -z "${S2T_GOOGLE_API_KEY:-}" ] && [ -z "${S2T_GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
        log "asr: google missing S2T_GOOGLE_API_KEY and S2T_GOOGLE_APPLICATION_CREDENTIALS"
        return 1
    fi

    local google_timeout_sec google_guard_sec
    google_timeout_sec="${S2T_GOOGLE_REQUEST_TIMEOUT_SEC:-$S2T_GOOGLE_TIMEOUT_SEC}"
    google_guard_sec="${S2T_GOOGLE_REQUEST_GUARD_SEC:-$S2T_MAX_RESPONSE_SECONDS}"

    local google_guard_cmd=()
    if is_positive_int "$google_guard_sec" && [ "$google_guard_sec" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        google_guard_cmd=(timeout --signal=TERM "${google_guard_sec}s")
    fi

    # Timeout semantics:
    # - optional hard cap for the whole cloud request (S2T_MAX_RESPONSE_SECONDS)
    # - optional response timeout once request is sent (S2T_GOOGLE_TIMEOUT_SEC)
    S2T_GOOGLE_API_KEY="${S2T_GOOGLE_API_KEY:-}" \
    S2T_GOOGLE_APPLICATION_CREDENTIALS="${S2T_GOOGLE_APPLICATION_CREDENTIALS:-}" \
    S2T_GOOGLE_API_ENDPOINT="$S2T_GOOGLE_API_ENDPOINT" \
    S2T_GOOGLE_MODEL="$S2T_GOOGLE_MODEL" \
    S2T_GOOGLE_LANGUAGE_CODE="$S2T_GOOGLE_LANGUAGE_CODE" \
    S2T_GOOGLE_ALT_LANGUAGE_CODES="$S2T_GOOGLE_ALT_LANGUAGE_CODES" \
    S2T_GOOGLE_ENABLE_PUNCTUATION="$S2T_GOOGLE_ENABLE_PUNCTUATION" \
    S2T_GOOGLE_CONNECT_TIMEOUT_SEC="$S2T_GOOGLE_CONNECT_TIMEOUT_SEC" \
    S2T_GOOGLE_TIMEOUT_SEC="$google_timeout_sec" \
    "${google_guard_cmd[@]}" python3 - "$AUDIO_FILE" 2>>"$LOG_FILE" <<'PY'
import base64
import http.client
import json
import os
import socket
import sys
import urllib.parse

audio_path = sys.argv[1]
api_key = os.environ.get("S2T_GOOGLE_API_KEY", "").strip()
creds_path = os.environ.get("S2T_GOOGLE_APPLICATION_CREDENTIALS", "").strip()
endpoint = os.environ.get("S2T_GOOGLE_API_ENDPOINT", "https://speech.googleapis.com/v1/speech:recognize")
lang = os.environ.get("S2T_GOOGLE_LANGUAGE_CODE", "ru-RU")
model = os.environ.get("S2T_GOOGLE_MODEL", "latest_short")
alt = os.environ.get("S2T_GOOGLE_ALT_LANGUAGE_CODES", "").strip()
punct = os.environ.get("S2T_GOOGLE_ENABLE_PUNCTUATION", "1") == "1"
connect_timeout_raw = os.environ.get("S2T_GOOGLE_CONNECT_TIMEOUT_SEC", "3")
timeout_raw = os.environ.get("S2T_GOOGLE_TIMEOUT_SEC", "0")

if not api_key and not creds_path:
    sys.stderr.write("google missing api key and credentials\n")
    raise SystemExit(1)

try:
    connect_timeout = float(connect_timeout_raw)
except ValueError:
    connect_timeout = 3.0
if connect_timeout <= 0:
    connect_timeout = None

try:
    response_timeout = float(timeout_raw)
except ValueError:
    response_timeout = 0.0
if response_timeout <= 0:
    response_timeout = None

with open(audio_path, "rb") as f:
    content_b64 = base64.b64encode(f.read()).decode("ascii")

alt_list = [x.strip() for x in alt.split(",") if x.strip()] if alt else []
req = {
    "config": {
        "encoding": "LINEAR16",
        "sampleRateHertz": 16000,
        "languageCode": lang,
        "alternativeLanguageCodes": alt_list,
        "model": model,
        "enableAutomaticPunctuation": punct,
    },
    "audio": {"content": content_b64},
}
body = json.dumps(req, ensure_ascii=False).encode("utf-8")

parsed = urllib.parse.urlparse(endpoint)
scheme = parsed.scheme or "https"
host = parsed.netloc
path = parsed.path or "/"
if parsed.query:
    path = f"{path}?{parsed.query}"

headers = {"Content-Type": "application/json"}

if api_key:
    sep = "&" if "?" in path else "?"
    path = f"{path}{sep}key={urllib.parse.quote(api_key, safe='')}"
else:
    import urllib.request
    try:
        with open(creds_path) as f:
            creds = json.load(f)
        req_token = urllib.request.Request("https://oauth2.googleapis.com/token", data=urllib.parse.urlencode({
            "client_id": creds["client_id"],
            "client_secret": creds["client_secret"],
            "refresh_token": creds["refresh_token"],
            "grant_type": "refresh_token"
        }).encode("utf-8"))
        with urllib.request.urlopen(req_token) as resp_token:
            token = json.loads(resp_token.read())["access_token"]
        headers["Authorization"] = f"Bearer {token}"
        headers["x-goog-user-project"] = creds.get("quota_project_id", "")
    except Exception as e:
        sys.stderr.write(f"google failed to get token: {e}\n")
        raise SystemExit(1)

if not host:
    sys.stderr.write(f"google invalid endpoint: {endpoint}\n")
    raise SystemExit(1)

conn_cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
conn = conn_cls(host, timeout=connect_timeout)

try:
    conn.request("POST", path, body=body, headers=headers)
    if response_timeout is not None and conn.sock is not None:
        conn.sock.settimeout(response_timeout)
    resp = conn.getresponse()
    payload = resp.read().decode("utf-8", errors="replace")
except socket.timeout:
    sys.stderr.write("google response timeout\n")
    raise SystemExit(124)
except Exception as e:
    sys.stderr.write(f"google request failed: {e}\n")
    raise SystemExit(1)
finally:
    try:
        conn.close()
    except Exception:
        pass

if not payload.strip():
    raise SystemExit(0)

try:
    data = json.loads(payload)
except json.JSONDecodeError:
    sys.stderr.write("google returned invalid json\n")
    raise SystemExit(1)

error = data.get("error") or {}
err_msg = error.get("message")
if err_msg:
    sys.stderr.write(f"google error: {err_msg}\n")
    raise SystemExit(1)

parts = []
for result in data.get("results", []) or []:
    for alt_item in result.get("alternatives", []) or []:
        text = alt_item.get("transcript")
        if text:
            parts.append(text)

out = " ".join(parts).strip()
try:
    sys.stdout.write(out)
except BrokenPipeError:
    pass
PY
}

resolve_gcp_project() {
    local project
    project="${S2T_GCP_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}"
    if [ -n "${project//[[:space:]]/}" ]; then
        printf '%s' "$project"
        return 0
    fi

    if [ -n "${S2T_GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -r "${S2T_GOOGLE_APPLICATION_CREDENTIALS:-}" ] && command -v python3 >/dev/null 2>&1; then
        project="$(python3 - "${S2T_GOOGLE_APPLICATION_CREDENTIALS}" 2>/dev/null <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    raise SystemExit(0)

project = (data.get("project_id") or data.get("quota_project_id") or "").strip()
if project:
    print(project)
PY
)"
        if [ -n "${project//[[:space:]]/}" ]; then
            printf '%s' "$project"
            return 0
        fi
    fi

    return 1
}

google_v2_ready_for_retry() {
    local project
    [ "$S2T_GOOGLE_V2_ON_EMPTY" = "1" ] || return 1
    [ -n "${S2T_GOOGLE_APPLICATION_CREDENTIALS//[[:space:]]/}" ] || return 1
    [ -r "${S2T_GOOGLE_APPLICATION_CREDENTIALS}" ] || return 1
    project="$(resolve_gcp_project || true)"
    [ -n "${project//[[:space:]]/}" ] || return 1
    if ! python3 -c 'import google.cloud.speech_v2' >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

transcribe_with_google_v2() {
    require_cmd python3

    local project
    project="$(resolve_gcp_project || true)"
    if [ -z "${project//[[:space:]]/}" ]; then
        log "asr: google-v2 missing GCP project (set S2T_GCP_PROJECT)"
        return 1
    fi

    if [ -z "${S2T_GOOGLE_APPLICATION_CREDENTIALS//[[:space:]]/}" ]; then
        log "asr: google-v2 missing credentials (set S2T_GOOGLE_APPLICATION_CREDENTIALS to a service-account JSON path)"
        return 1
    fi
    if [ ! -r "${S2T_GOOGLE_APPLICATION_CREDENTIALS}" ]; then
        log "asr: google-v2 credentials file unreadable: ${S2T_GOOGLE_APPLICATION_CREDENTIALS}"
        return 1
    fi

    local location="${S2T_GOOGLE_V2_LOCATION}"
    local recognizer_id="${S2T_GOOGLE_V2_RECOGNIZER}"
    if [ -z "${recognizer_id//[[:space:]]/}" ]; then
        recognizer_id="_"
    fi

    local recognizer_name="projects/${project}/locations/${location}/recognizers/${recognizer_id}"

    local endpoint
    if [ "$location" = "global" ]; then
        endpoint="speech.googleapis.com"
    else
        endpoint="${location}-speech.googleapis.com"
    fi

    local model langs
    model="${S2T_GOOGLE_V2_MODEL}"
    langs="${S2T_GOOGLE_V2_LANGUAGE_CODES}"

    local google_v2_timeout_for_call
    if is_positive_int "${S2T_GOOGLE_V2_TIMEOUT_SEC:-0}" && [ "${S2T_GOOGLE_V2_TIMEOUT_SEC}" -gt 0 ]; then
        google_v2_timeout_for_call="${S2T_GOOGLE_V2_TIMEOUT_SEC}"
    else
        google_v2_timeout_for_call="$(compute_dynamic_timeout_sec \
            "10" \
            "1" \
            "$audio_sec" \
            "4" \
            "0.5" \
            "60")"
    fi

    S2T_GOOGLE_APPLICATION_CREDENTIALS="$S2T_GOOGLE_APPLICATION_CREDENTIALS" \
    GOOGLE_CLOUD_PROJECT="$project" \
    S2T_GOOGLE_V2_ENDPOINT="$endpoint" \
    S2T_GOOGLE_V2_RECOGNIZER_NAME="$recognizer_name" \
    S2T_GOOGLE_V2_MODEL="$model" \
    S2T_GOOGLE_V2_LANGUAGE_CODES="$langs" \
    S2T_GOOGLE_V2_ENABLE_PUNCTUATION="$S2T_GOOGLE_V2_ENABLE_PUNCTUATION" \
    S2T_GOOGLE_V2_TIMEOUT_SEC="$google_v2_timeout_for_call" \
    S2T_GOOGLE_CONNECT_TIMEOUT_SEC="$S2T_GOOGLE_CONNECT_TIMEOUT_SEC" \
    python3 - "$AUDIO_FILE" 2>>"$LOG_FILE" <<'PY'
import base64
import http.client
import json
import os
import socket
import sys
import urllib.parse
import urllib.request

audio_path = sys.argv[1]
creds_path = os.environ.get("S2T_GOOGLE_APPLICATION_CREDENTIALS", "").strip()
endpoint = os.environ.get("S2T_GOOGLE_V2_ENDPOINT", "speech.googleapis.com")
recognizer = os.environ["S2T_GOOGLE_V2_RECOGNIZER_NAME"]
model = os.environ.get("S2T_GOOGLE_V2_MODEL", "chirp_2")
langs = os.environ.get("S2T_GOOGLE_V2_LANGUAGE_CODES", "ru-RU,en-US")
punct = os.environ.get("S2T_GOOGLE_V2_ENABLE_PUNCTUATION", "1") == "1"
timeout_raw = os.environ.get("S2T_GOOGLE_V2_TIMEOUT_SEC", "0")
connect_timeout_raw = os.environ.get("S2T_GOOGLE_CONNECT_TIMEOUT_SEC", "3")

try:
    connect_timeout = float(connect_timeout_raw)
except ValueError:
    connect_timeout = 3.0
if connect_timeout <= 0:
    connect_timeout = None

try:
    response_timeout = float(timeout_raw)
except ValueError:
    response_timeout = 0.0
if response_timeout <= 0:
    response_timeout = None

with open(audio_path, "rb") as f:
    content_b64 = base64.b64encode(f.read()).decode("ascii")

language_codes = [x.strip() for x in langs.split(",") if x.strip()]

req = {
    "config": {
        "autoDecodingConfig": {},
        "languageCodes": language_codes,
        "model": model,
        "features": {
            "enableAutomaticPunctuation": punct
        }
    },
    "content": content_b64
}
body = json.dumps(req, ensure_ascii=False).encode("utf-8")

try:
    with open(creds_path) as f:
        creds = json.load(f)
    req_token = urllib.request.Request("https://oauth2.googleapis.com/token", data=urllib.parse.urlencode({
        "client_id": creds["client_id"],
        "client_secret": creds["client_secret"],
        "refresh_token": creds["refresh_token"],
        "grant_type": "refresh_token"
    }).encode("utf-8"))
    with urllib.request.urlopen(req_token) as resp_token:
        token = json.loads(resp_token.read())["access_token"]
except Exception as e:
    sys.stderr.write(f"google-v2 failed to get token: {e}\n")
    raise SystemExit(1)

host = endpoint
path = f"/v2/{recognizer}:recognize"

headers = {
    "Content-Type": "application/json",
    "Authorization": f"Bearer {token}",
    "x-goog-user-project": creds.get("quota_project_id", "")
}

conn = http.client.HTTPSConnection(host, timeout=connect_timeout or 10.0)

try:
    conn.request("POST", path, body=body, headers=headers)
    if response_timeout is not None and conn.sock is not None:
        conn.sock.settimeout(response_timeout)
    resp = conn.getresponse()
    payload = resp.read().decode("utf-8", errors="replace")
except socket.timeout:
    sys.stderr.write("google-v2 response timeout\n")
    raise SystemExit(124)
except Exception as e:
    sys.stderr.write(f"google-v2 request failed: {e}\n")
    raise SystemExit(1)
finally:
    try:
        conn.close()
    except Exception:
        pass

if not payload.strip():
    raise SystemExit(0)

try:
    data = json.loads(payload)
except json.JSONDecodeError:
    sys.stderr.write("google-v2 returned invalid json\n")
    raise SystemExit(1)

error = data.get("error") or {}
err_msg = error.get("message")
if err_msg:
    sys.stderr.write(f"google-v2 error: {err_msg}\n")
    raise SystemExit(1)

results = data.get("results", [])
for result in results:
    alts = result.get("alternatives", [])
    if alts:
        print(alts[0].get("transcript", ""))
PY
}

google_result_too_short_for_audio() {
    local text="${1:-}"
    local audio_sec="${2:-}"
    local compact_len min_chars

    if [ "$S2T_GOOGLE_RETRY_ON_SHORT" != "1" ]; then
        return 1
    fi
    if [ -z "${text//[[:space:]]/}" ] || [ -z "${audio_sec:-}" ]; then
        return 1
    fi
    if ! duration_gt "$audio_sec" "$S2T_GOOGLE_SHORT_RESULT_AUDIO_SEC"; then
        return 1
    fi

    compact_len="$(text_non_space_len "$text")"
    min_chars="$(awk -v sec="$audio_sec" -v rate="$S2T_GOOGLE_MIN_CHARS_PER_AUDIO_SEC" '
        BEGIN {
            r = rate + 0
            if (r <= 0) r = 3.5
            m = int((sec + 0) * r)
            if (m < 1) m = 1
            print m
        }' </dev/null)"
    [ "${compact_len:-0}" -lt "${min_chars:-1}" ]
}

if is_positive_int "$S2T_MAX_RESPONSE_SECONDS" && [ "$S2T_MAX_RESPONSE_SECONDS" -gt 0 ]; then
    if is_positive_int "$S2T_OPENAI_TIMEOUT_SEC" && [ "$S2T_OPENAI_TIMEOUT_SEC" -gt "$S2T_MAX_RESPONSE_SECONDS" ]; then
        S2T_OPENAI_TIMEOUT_SEC="$S2T_MAX_RESPONSE_SECONDS"
    fi
    if is_positive_int "$S2T_GCP_WHISPER_TIMEOUT_SEC" && [ "$S2T_GCP_WHISPER_TIMEOUT_SEC" -gt "$S2T_MAX_RESPONSE_SECONDS" ]; then
        S2T_GCP_WHISPER_TIMEOUT_SEC="$S2T_MAX_RESPONSE_SECONDS"
    fi
    if is_positive_int "$S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC" && [ "$S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC" -gt "$S2T_MAX_RESPONSE_SECONDS" ]; then
        S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC="$S2T_MAX_RESPONSE_SECONDS"
    fi
    if is_positive_int "$S2T_GOOGLE_TIMEOUT_SEC" && [ "$S2T_GOOGLE_TIMEOUT_SEC" -gt "$S2T_MAX_RESPONSE_SECONDS" ]; then
        S2T_GOOGLE_TIMEOUT_SEC="$S2T_MAX_RESPONSE_SECONDS"
    fi
    if is_positive_int "$S2T_GOOGLE_CONNECT_TIMEOUT_SEC" && [ "$S2T_GOOGLE_CONNECT_TIMEOUT_SEC" -gt "$S2T_MAX_RESPONSE_SECONDS" ]; then
        S2T_GOOGLE_CONNECT_TIMEOUT_SEC="$S2T_MAX_RESPONSE_SECONDS"
    fi
    if is_positive_int "$S2T_GOOGLE_V2_TIMEOUT_SEC" && [ "$S2T_GOOGLE_V2_TIMEOUT_SEC" -gt "$S2T_MAX_RESPONSE_SECONDS" ]; then
        S2T_GOOGLE_V2_TIMEOUT_SEC="$S2T_MAX_RESPONSE_SECONDS"
    fi
fi

file_size_bytes() {
    local file="$1"
    stat -c '%s' "$file" 2>/dev/null || echo 0
}

rotate_file_if_needed() {
    local file="$1"
    local max_bytes="$2"
    local keep_count="$3"
    local size i src dst

    [ -f "$file" ] || return 0
    is_positive_int "$max_bytes" || return 0
    is_positive_int "$keep_count" || keep_count=0

    size="$(file_size_bytes "$file")"
    if [ "$size" -lt "$max_bytes" ]; then
        return 0
    fi

    if [ "$keep_count" -gt 0 ]; then
        for i in $(seq "$keep_count" -1 1); do
            src="$file.$((i - 1))"
            dst="$file.$i"
            if [ "$i" -eq 1 ]; then
                src="$file"
            fi
            [ -f "$src" ] && mv -f "$src" "$dst"
        done
        : > "$file"
    else
        : > "$file"
    fi
}

cap_file_size() {
    local file="$1"
    local max_bytes="$2"
    local size

    [ -f "$file" ] || return 0
    is_positive_int "$max_bytes" || return 0

    size="$(file_size_bytes "$file")"
    if [ "$size" -le "$max_bytes" ]; then
        return 0
    fi

    tail -c "$max_bytes" "$file" > "${file}.tmp" 2>/dev/null || return 0
    mv -f "${file}.tmp" "$file"
}

prune_old_files() {
    local pattern="$1"
    local keep_count="$2"
    local idx=0
    local file

    is_positive_int "$keep_count" || keep_count=0

    while IFS= read -r file; do
        idx=$((idx + 1))
        if [ "$idx" -gt "$keep_count" ]; then
            rm -f -- "$file"
        fi
    done < <(ls -1t $pattern 2>/dev/null || true)
}

cleanup_transcribe_artifacts() {
    prune_old_files "$RUNTIME_DIR/whisper_*.log" "$S2T_WHISPER_ARTIFACT_KEEP"
    prune_old_files "$RUNTIME_DIR/whisper_out_*.txt" "$S2T_WHISPER_ARTIFACT_KEEP"
}

capture_fail_count() {
    local count
    count="$(cat "$CAPTURE_FAIL_FILE" 2>/dev/null || echo 0)"
    if is_positive_int "$count"; then
        printf '%s' "$count"
    else
        printf '0'
    fi
}

set_capture_fail_count() {
    local count="$1"
    is_positive_int "$count" || count=0
    printf '%s\n' "$count" >"$CAPTURE_FAIL_FILE" 2>/dev/null || true
}

increment_capture_fail_count() {
    local current
    current="$(capture_fail_count)"
    current=$((current + 1))
    set_capture_fail_count "$current"
    printf '%s' "$current"
}

reset_capture_fail_count() {
    rm -f "$CAPTURE_FAIL_FILE" 2>/dev/null || true
}

set_capture_default_until_now_plus() {
    local seconds="$1"
    local now until
    if ! is_positive_int "$seconds" || [ "$seconds" -le 0 ]; then
        return 0
    fi
    now="$(now_ms)"
    until=$((now + seconds * 1000))
    printf '%s\n' "$until" >"$CAPTURE_DEFAULT_UNTIL_FILE" 2>/dev/null || true
}

capture_default_mode_active() {
    local until now
    until="$(cat "$CAPTURE_DEFAULT_UNTIL_FILE" 2>/dev/null || true)"
    if ! [[ "${until:-}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    now="$(now_ms)"
    if [ "$now" -lt "$until" ]; then
        return 0
    fi
    rm -f "$CAPTURE_DEFAULT_UNTIL_FILE" 2>/dev/null || true
    return 1
}

terminate_pid_gracefully() {
    local pid="$1"

    if ! [[ "${pid:-}" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done

    kill -KILL "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
}

mark_transcribe_lock_owner() {
    local owner_file started_file
    owner_file="$TRANSCRIBE_LOCK_DIR/pid"
    started_file="$TRANSCRIBE_LOCK_DIR/started_ms"
    printf '%s\n' "$$" >"$owner_file" 2>/dev/null || true
    printf '%s\n' "$(now_ms)" >"$started_file" 2>/dev/null || true
}

acquire_transcribe_slot() {
    local owner_file owner_pid started_file owner_started now lock_age_ms stale_after_ms

    mkdir -p "$RUNTIME_DIR" >/dev/null 2>&1 || true
    owner_file="$TRANSCRIBE_LOCK_DIR/pid"
    started_file="$TRANSCRIBE_LOCK_DIR/started_ms"

    if mkdir "$TRANSCRIBE_LOCK_DIR" 2>/dev/null; then
        mark_transcribe_lock_owner
        return 0
    fi

    owner_pid="$(cat "$owner_file" 2>/dev/null || true)"
    if [[ "${owner_pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
        if is_positive_int "$S2T_TRANSCRIBE_STALE_SEC" && [ "$S2T_TRANSCRIBE_STALE_SEC" -gt 0 ]; then
            owner_started="$(cat "$started_file" 2>/dev/null || true)"
            if [[ "${owner_started:-}" =~ ^[0-9]+$ ]]; then
                now="$(now_ms)"
                lock_age_ms=0
                if [ "$now" -ge "$owner_started" ]; then
                    lock_age_ms=$((now - owner_started))
                fi
                stale_after_ms=$((S2T_TRANSCRIBE_STALE_SEC * 1000))
                if [ "$lock_age_ms" -ge "$stale_after_ms" ]; then
                    log "transcribe: stale lock owner pid=$owner_pid age_ms=$lock_age_ms, forcing recovery"
                    terminate_pid_gracefully "$owner_pid"
                fi
            fi
        fi
        if kill -0 "$owner_pid" 2>/dev/null; then
            return 1
        fi
    fi

    rm -rf "$TRANSCRIBE_LOCK_DIR" 2>/dev/null || true
    if mkdir "$TRANSCRIBE_LOCK_DIR" 2>/dev/null; then
        mark_transcribe_lock_owner
        return 0
    fi

    return 1
}

release_transcribe_slot() {
    local owner_file owner_pid
    owner_file="$TRANSCRIBE_LOCK_DIR/pid"
    owner_pid="$(cat "$owner_file" 2>/dev/null || true)"
    if [ -n "${owner_pid:-}" ] && [ "$owner_pid" != "$$" ]; then
        return 0
    fi
    rm -rf "$TRANSCRIBE_LOCK_DIR" 2>/dev/null || true
}

is_recording_or_transcribing() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ "${pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    if transcribe_slot_busy; then
        return 0
    fi
    return 1
}

transcribe_slot_busy() {
    local owner_file owner_pid
    owner_file="$TRANSCRIBE_LOCK_DIR/pid"
    if [ ! -d "$TRANSCRIBE_LOCK_DIR" ]; then
        return 1
    fi
    owner_pid="$(cat "$owner_file" 2>/dev/null || true)"
    if [[ "${owner_pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
        return 0
    fi
    rm -rf "$TRANSCRIBE_LOCK_DIR" 2>/dev/null || true
    return 1
}

wait_for_transcribe_idle() {
    local timeout_ms="${1:-0}"
    local started_ms now elapsed_ms

    if ! is_positive_int "$timeout_ms" || [ "$timeout_ms" -le 0 ]; then
        transcribe_slot_busy
        return $?
    fi

    started_ms="$(now_ms)"
    while transcribe_slot_busy; do
        sleep 0.05
        now="$(now_ms)"
        if [ "$now" -lt "$started_ms" ]; then
            continue
        fi
        elapsed_ms=$((now - started_ms))
        if [ "$elapsed_ms" -ge "$timeout_ms" ]; then
            return 1
        fi
    done
    return 0
}

log() {
    mkdir -p "$RUNTIME_DIR" >/dev/null 2>&1 || true
    rotate_file_if_needed "$LOG_FILE" "$S2T_LOG_MAX_BYTES" "$S2T_LOG_KEEP"
    printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

logv() {
    if [ "$S2T_LOG_VERBOSE" = "1" ]; then
        log "$@"
    fi
}

sanitize_one_line_text() {
    local value="${1:-}"
    printf '%s\n' "$value" \
        | tr '\r\n' ' ' \
        | sed 's/[[:space:]][[:space:]]*/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

is_valid_wav_file() {
    local path="${1:-}"
    local hex
    [ -n "${path:-}" ] || return 1
    [ -f "$path" ] || return 1
    hex="$(dd if="$path" bs=12 count=1 2>/dev/null | od -An -t x1 | tr -d ' \n')"
    [ "${#hex}" -ge 24 ] || return 1
    [ "${hex:0:8}" = "52494646" ] || return 1
    [ "${hex:16:8}" = "57415645" ] || return 1
    return 0
}

record_training_sample() {
    local sample_id="$1"
    local audio_path="$2"
    local raw_text="$3"
    local pending_audio pending_raw pending_meta

    [ -n "${sample_id:-}" ] || return 0
    [ -f "$audio_path" ] || return 0
    if ! is_valid_wav_file "$audio_path"; then
        log "dataset: skip invalid wav sample_id=$sample_id audio=$audio_path"
        return 0
    fi

    mkdir -p "$S2T_DATASET_PENDING_DIR" >/dev/null 2>&1 || return 0

    pending_audio="$S2T_DATASET_PENDING_DIR/${sample_id}.wav"
    pending_raw="$S2T_DATASET_PENDING_DIR/${sample_id}.raw.txt"
    pending_meta="$S2T_DATASET_PENDING_DIR/${sample_id}.meta"

    if ! cp -f "$audio_path" "$pending_audio" 2>/dev/null; then
        log "dataset: failed to stage pending audio for sample_id=$sample_id"
        return 0
    fi

    printf '%s\n' "$raw_text" >"$pending_raw" 2>/dev/null || true
    {
        printf 'sample_id=%s\n' "$sample_id"
        printf 'audio=%s\n' "$pending_audio"
        printf 'raw_text=%s\n' "$pending_raw"
        printf 'created_ms=%s\n' "$(now_ms)"
    } >"$pending_meta" 2>/dev/null || true
    cp -f "$pending_meta" "$LAST_SAMPLE_META_FILE" 2>/dev/null || true
    logv "dataset: staged pending sample id=$sample_id (awaiting submit-correction)"

    # Optional debug mode: persist ASR draft immediately.
    # Normal training flow should keep data in pending until corrected text arrives.
    auto_submit_pending_raw "$sample_id" "$raw_text"
}

auto_submit_pending_raw() {
    local sample_id="$1"
    local raw_text="$2"
    local day partition_dir normalized_text audio_src audio_dst text_dst

    [ "${S2T_DATASET_AUTO_SUBMIT_RAW:-0}" = "1" ] || return 0
    [ -n "${sample_id:-}" ] || return 0

    normalized_text="$(sanitize_one_line_text "$raw_text")"
    [ -n "${normalized_text:-}" ] || return 0

    audio_src="$S2T_DATASET_PENDING_DIR/${sample_id}.wav"
    [ -f "$audio_src" ] || return 0

    day="$(date +%Y-%m-%d 2>/dev/null || echo unknown-date)"
    partition_dir="$S2T_DATASET_RAW_DIR/$day"
    mkdir -p "$partition_dir" >/dev/null 2>&1 || return 0

    audio_dst="$partition_dir/${sample_id}.wav"
    text_dst="$partition_dir/${sample_id}.txt"
    cp -f "$audio_src" "$audio_dst" 2>/dev/null || return 0
    printf '%s\n' "$normalized_text" >"$text_dst" 2>/dev/null || true

    if [ "$S2T_DATASET_ENQUEUE_CORRECTION" = "1" ]; then
        if enqueue_dataset_job "$sample_id" "$audio_dst" "$text_dst"; then
            log "dataset: auto-submitted sample_id=$sample_id audio=$audio_dst text=$text_dst (queued)"
        else
            log "dataset: auto-submit queue write failed sample_id=$sample_id"
        fi
    else
        log "dataset: auto-submitted sample_id=$sample_id audio=$audio_dst text=$text_dst (queue disabled)"
    fi
}

extract_meta_value() {
    local file="$1"
    local key="$2"
    if [ ! -f "$file" ]; then
        return 1
    fi
    sed -n "s/^${key}=//p" "$file" | head -n1
}

latest_pending_sample_id() {
    local meta sample_id latest_meta

    meta="$LAST_SAMPLE_META_FILE"
    if [ ! -f "$meta" ]; then
        latest_meta="$(ls -1t "$S2T_DATASET_PENDING_DIR"/*.meta 2>/dev/null | head -n1 || true)"
        if [ -n "${latest_meta:-}" ]; then
            meta="$latest_meta"
        fi
    fi

    sample_id="$(extract_meta_value "$meta" "sample_id" || true)"
    if [ -n "${sample_id:-}" ]; then
        printf '%s' "$sample_id"
        return 0
    fi
    return 1
}

pending_sample_ids_for_submit() {
    local requested_id="${1:-}"

    if [ "${S2T_DATASET_CLUSTER_ON_SUBMIT:-1}" != "1" ]; then
        if [ -n "$requested_id" ]; then
            printf '%s\n' "$requested_id"
            return 0
        fi
        latest_pending_sample_id || return 1
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        if [ -n "$requested_id" ]; then
            printf '%s\n' "$requested_id"
            return 0
        fi
        latest_pending_sample_id || return 1
        return 0
    fi

    python3 - "$S2T_DATASET_PENDING_DIR" "$LAST_SAMPLE_META_FILE" "${S2T_DATASET_MULTI_SEGMENT_GAP_SEC:-20}" "${S2T_DATASET_MULTI_SEGMENT_MAX_COUNT:-6}" "$requested_id" <<'PY'
import glob
import pathlib
import sys

pending_dir = pathlib.Path(sys.argv[1])
last_meta = pathlib.Path(sys.argv[2])
requested_id = sys.argv[5].strip()

try:
    gap_sec = float(sys.argv[3])
except Exception:
    gap_sec = 20.0

try:
    max_count = int(sys.argv[4])
except Exception:
    max_count = 6

if max_count < 0:
    max_count = 0

gap_ms = int(gap_sec * 1000.0)


def parse_meta(path: pathlib.Path):
    sample_id = ""
    created_ms = -1
    try:
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if line.startswith("sample_id="):
                sample_id = line.split("=", 1)[1].strip()
            elif line.startswith("created_ms="):
                value = line.split("=", 1)[1].strip()
                if value.isdigit():
                    created_ms = int(value)
    except Exception:
        return None
    if not sample_id or created_ms < 0:
        return None
    return (created_ms, sample_id)


items = []
for meta in glob.glob(str(pending_dir / "*.meta")):
    parsed = parse_meta(pathlib.Path(meta))
    if parsed is not None:
        items.append(parsed)

if not items:
    raise SystemExit(1)

items.sort()
ids = [sid for _, sid in items]

anchor_id = ""
if requested_id:
    if requested_id in ids:
        anchor_id = requested_id
    else:
        raise SystemExit(1)
elif last_meta.is_file():
    parsed_last = parse_meta(last_meta)
    if parsed_last is not None and parsed_last[1] in ids:
        anchor_id = parsed_last[1]

if not anchor_id:
    anchor_id = items[-1][1]

anchor_idx = next((i for i in range(len(items) - 1, -1, -1) if items[i][1] == anchor_id), len(items) - 1)
anchor_created = items[anchor_idx][0]

if gap_ms <= 0:
    print(anchor_id)
    raise SystemExit(0)

selected = [(anchor_created, anchor_id)]
cursor_created = anchor_created

for idx in range(anchor_idx - 1, -1, -1):
    created_ms, sample_id = items[idx]
    if cursor_created - created_ms > gap_ms:
        break
    selected.append((created_ms, sample_id))
    cursor_created = created_ms
    if max_count > 0 and len(selected) >= max_count:
        break

selected.sort()
for _, sample_id in selected:
    print(sample_id)
PY
}

enqueue_dataset_job_file() {
    local sample_id="$1"
    local audio_path="$2"
    local text_path="$3"
    local job_file

    mkdir -p "$S2T_DATASET_QUEUE_DIR" >/dev/null 2>&1 || return 1
    job_file="$S2T_DATASET_QUEUE_DIR/$(now_ms)_${sample_id}.job"

    {
        printf 'sample_id=%s\n' "$sample_id"
        printf 'audio=%s\n' "$audio_path"
        printf 'text=%s\n' "$text_path"
        printf 'queued_ms=%s\n' "$(now_ms)"
    } >"$job_file"
}

enqueue_dataset_job_rabbit() {
    local sample_id="$1"
    local audio_path="$2"
    local text_path="$3"
    local queued_ms

    queued_ms="$(now_ms)"
    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi
    if [ ! -f "$S2T_RABBITMQ_PUBLISHER" ]; then
        return 1
    fi

    python3 "$S2T_RABBITMQ_PUBLISHER" \
        --sample-id "$sample_id" \
        --audio "$audio_path" \
        --text "$text_path" \
        --queued-ms "$queued_ms" >/dev/null 2>&1
}

enqueue_dataset_job() {
    local sample_id="$1"
    local audio_path="$2"
    local text_path="$3"

    if [ "${S2T_QUEUE_BACKEND:-file}" = "rabbitmq" ]; then
        if enqueue_dataset_job_rabbit "$sample_id" "$audio_path" "$text_path"; then
            return 0
        fi
        log "dataset: rabbitmq enqueue failed sample_id=$sample_id backend_fallback=file"
    fi

    enqueue_dataset_job_file "$sample_id" "$audio_path" "$text_path"
}

submit_correction() {
    local sample_id=""
    local corrected_text=""
    local audio_src audio_dst text_dst sid
    local day partition_dir normalized_text current_last_id
    local -a sample_ids=()
    local -a processed_ids=()
    local processed_count=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --id)
                sample_id="${2:-}"
                shift 2
                ;;
            --text)
                corrected_text="${2:-}"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
    done

    if [ -z "${corrected_text:-}" ] && [ "$#" -gt 0 ]; then
        corrected_text="$*"
    fi
    if [ -z "${corrected_text:-}" ] && [ ! -t 0 ]; then
        corrected_text="$(cat || true)"
    fi
    normalized_text="$(sanitize_one_line_text "$corrected_text")"
    if [ -z "${normalized_text:-}" ]; then
        log "dataset: submit-correction rejected: empty corrected text"
        echo "submit-correction: empty corrected text" >&2
        return 1
    fi

    if ! mapfile -t sample_ids < <(pending_sample_ids_for_submit "$sample_id"); then
        sample_ids=()
    fi
    if [ "${#sample_ids[@]}" -eq 0 ]; then
        log "dataset: submit-correction rejected: no pending sample id"
        echo "submit-correction: no pending sample id" >&2
        return 1
    fi

    day="$(date +%Y-%m-%d 2>/dev/null || echo unknown-date)"
    partition_dir="$S2T_DATASET_RAW_DIR/$day"
    mkdir -p "$partition_dir" >/dev/null 2>&1 || {
        log "dataset: submit-correction rejected: cannot create dataset dir: $partition_dir"
        echo "submit-correction: cannot create dataset dir: $partition_dir" >&2
        return 1
    }

    for sid in "${sample_ids[@]}"; do
        audio_src="$S2T_DATASET_PENDING_DIR/${sid}.wav"
        if [ ! -f "$audio_src" ]; then
            log "dataset: submit-correction skipped: pending audio not found sample_id=$sid"
            continue
        fi

        audio_dst="$partition_dir/${sid}.wav"
        text_dst="$partition_dir/${sid}.txt"
        cp -f "$audio_src" "$audio_dst"
        printf '%s\n' "$normalized_text" >"$text_dst"

        if [ "$S2T_DATASET_ENQUEUE_CORRECTION" = "1" ]; then
            if enqueue_dataset_job "$sid" "$audio_dst" "$text_dst"; then
                log "dataset: correction submitted sample_id=$sid audio=$audio_dst text=$text_dst (queued)"
            else
                log "dataset: correction submitted sample_id=$sid but queue write failed"
            fi
        else
            log "dataset: correction submitted sample_id=$sid audio=$audio_dst text=$text_dst (queue disabled)"
        fi

        rm -f "$S2T_DATASET_PENDING_DIR/${sid}.wav" \
            "$S2T_DATASET_PENDING_DIR/${sid}.raw.txt" \
            "$S2T_DATASET_PENDING_DIR/${sid}.meta" 2>/dev/null || true

        processed_ids+=("$sid")
        processed_count=$((processed_count + 1))
        printf '%s\n' "$text_dst"
    done

    if [ "$processed_count" -eq 0 ]; then
        log "dataset: submit-correction rejected: no pending audio files found for selected sample ids"
        echo "submit-correction: no pending audio found for selected sample ids" >&2
        return 1
    fi

    current_last_id="$(extract_meta_value "$LAST_SAMPLE_META_FILE" "sample_id" || true)"
    for sid in "${processed_ids[@]}"; do
        if [ "$current_last_id" = "$sid" ]; then
            rm -f "$LAST_SAMPLE_META_FILE" 2>/dev/null || true
            break
        fi
    done

    if [ "$processed_count" -gt 1 ]; then
        log "dataset: correction mapped to multi-segment cluster count=$processed_count ids=${processed_ids[*]}"
    fi

    return 0
}

sleep_ms() {
    local ms="${1:-0}"
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<PY
import time
time.sleep(${ms} / 1000.0)
PY
        return 0
    fi
    # crude fallback
    sleep "0.$(printf '%03d' "$ms")" 2>/dev/null || sleep 0.1
}

focused_wm_class_x11() {
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        return 1
    fi
    if ! command -v xdotool >/dev/null 2>&1; then
        return 1
    fi
    xdotool getwindowfocus getwindowclassname 2>/dev/null || true
}

focused_window_id_x11() {
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        return 1
    fi
    if ! command -v xdotool >/dev/null 2>&1; then
        return 1
    fi
    xdotool getwindowfocus 2>/dev/null || true
}

focused_wm_title_x11() {
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        return 1
    fi
    if ! command -v xdotool >/dev/null 2>&1; then
        return 1
    fi
    xdotool getwindowfocus getwindowname 2>/dev/null || true
}

is_terminal_class() {
    local cls="${1:-}"
    cls="${cls,,}"
    case "$cls" in
        *gnome-terminal*|*terminal*|*kitty*|*alacritty*|*wezterm*|*tilix*|*konsole*|*xterm*|*rxvt*|*st-*|*foot*)
            return 0
            ;;
    esac
    return 1
}

is_vscodium_terminal_focus() {
    local cls="${1:-}"
    local title="${2:-}"
    local cls_lc title_lc

    cls_lc="${cls,,}"
    title_lc="${title,,}"

    case "$cls_lc" in
        *vscodium*|*code*|*codium*)
            ;;
        *)
            return 1
            ;;
    esac

    case "$title_lc" in
        *terminal*|*терминал*|*tmux*|*bash*|*zsh*|*fish*)
            return 0
            ;;
    esac
    return 1
}

select_paste_keys() {
    if [ "$S2T_PASTE_KEYS" != "auto" ]; then
        printf '%s' "$S2T_PASTE_KEYS"
        return 0
    fi

    local cls title
    cls="$(focused_wm_class_x11 || true)"
    title="$(focused_wm_title_x11 || true)"
    if [ -n "${cls:-}" ]; then
        if is_terminal_class "$cls"; then
            printf '%s' "$S2T_PASTE_KEYS_TERMINAL"
        elif is_vscodium_terminal_focus "$cls" "$title"; then
            printf '%s' "$S2T_PASTE_KEYS_TERMINAL"
        else
            printf '%s' "$S2T_PASTE_KEYS_GUI"
        fi
        return 0
    fi

    printf '%s' "$S2T_PASTE_KEYS_FALLBACK"
}

now_ms() {
    # GNU date supports %N. If not available, fall back to python.
    local ms
    ms="$(date +%s%3N 2>/dev/null || true)"
    if [[ "$ms" =~ ^[0-9]+$ ]]; then
        printf '%s' "$ms"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
        return 0
    fi
    date +%s 2>/dev/null | awk '{print $1 "000"}'
}

# We assume binaries are in PATH due to nix profile wrapper or direct call
# Prefer the Nix build output from this project if present.
S2T_PREPEND_RESULT_BIN="${S2T_PREPEND_RESULT_BIN:-1}"
if [ "$S2T_PREPEND_RESULT_BIN" = "1" ] && [ -d /etc/s2t/result/bin ]; then
    PATH="/etc/s2t/result/bin:$PATH"
fi

notify() {
    if [ "$S2T_NOTIFY" != "1" ]; then
        return 0
    fi
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "$@" || true
    else
        printf '%s\n' "$*" >&2
    fi
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        notify "S2T" "Missing dependency: $cmd"
        exit 1
    fi
}

ensure_model() {
    if [ ! -f "$MODEL_PATH" ]; then
        log "model: downloading to $MODEL_PATH"
        mkdir -p "$(dirname "$MODEL_PATH")"
        require_cmd curl
        curl -L --fail "$MODEL_URL" -o "$MODEL_PATH"
    fi
}

list_pactl_sources() {
    if ! command -v pactl >/dev/null 2>&1; then
        return 1
    fi
    pactl list short sources 2>/dev/null | awk '{print $2}'
}

pactl_source_exists() {
    local wanted="$1"
    [ -n "${wanted:-}" ] || return 1
    list_pactl_sources | grep -Fxq -- "$wanted"
}

first_non_excluded_pactl_source() {
    local source
    while IFS= read -r source; do
        [ -n "${source:-}" ] || continue
        if [ -n "${S2T_AUDIO_TARGET_EXCLUDE_RE:-}" ] && printf '%s\n' "$source" | grep -Eiq -- "$S2T_AUDIO_TARGET_EXCLUDE_RE"; then
            continue
        fi
        printf '%s' "$source"
        return 0
    done < <(list_pactl_sources)
    return 1
}

detect_audio_target() {
    local node_name node_id node_desc alsa_driver configured_name fallback_source

    # Prefer explicit config.
    if [ -n "${S2T_AUDIO_TARGET:-}" ]; then
        logv "audio: explicit target from env S2T_AUDIO_TARGET='$S2T_AUDIO_TARGET'"
        printf '%s' "$S2T_AUDIO_TARGET"
        return 0
    fi

    is_excluded_source() {
        local value="$1"
        [ -n "${S2T_AUDIO_TARGET_EXCLUDE_RE:-}" ] || return 1
        printf '%s\n' "$value" | grep -Eiq -- "$S2T_AUDIO_TARGET_EXCLUDE_RE"
    }

    # Best-effort: ask WirePlumber for the default audio source node name.
    if command -v wpctl >/dev/null 2>&1; then
        node_name="$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | sed -n 's/^[[:space:]]*\* node\.name = \"\(.*\)\"$/\1/p' | head -n1)"
        node_desc="$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | sed -n 's/^[[:space:]]*\* node\.description = \"\(.*\)\"$/\1/p' | head -n1)"
        alsa_driver="$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | sed -n 's/^[[:space:]]*alsa\.driver_name = \"\(.*\)\"$/\1/p' | head -n1)"
        if [ -n "${node_name:-}" ]; then
            logv "audio: default source node='${node_name}' desc='${node_desc:-?}' driver='${alsa_driver:-?}'"
        fi

        if [ "$S2T_AVOID_LOOPBACK_SOURCE" = "1" ] && [ -n "${node_name:-}" ] && is_excluded_source "$node_name"; then
            log "audio: default source '$node_name' looks loopback/monitor; trying non-loopback source"
            fallback_source="$(first_non_excluded_pactl_source || true)"
            if [ -n "${fallback_source:-}" ]; then
                log "audio: fallback source from pactl -> $fallback_source"
                printf '%s' "$fallback_source"
                return 0
            fi
            configured_name="$(wpctl status 2>/dev/null | sed -n 's/^[[:space:]]*[0-9]\+\.[[:space:]]*Audio\/Source[[:space:]]\+\(.*\)$/\1/p' | head -n1)"
            if [ -n "${configured_name:-}" ] && ! is_excluded_source "$configured_name" && pactl_source_exists "$configured_name"; then
                log "audio: fallback source from wpctl status -> $configured_name"
                printf '%s' "$configured_name"
                return 0
            fi
            if [ -n "${configured_name:-}" ] && ! pactl_source_exists "$configured_name"; then
                logv "audio: wpctl configured source '$configured_name' is not present in current sources"
            fi
            log "audio: no non-loopback source found; leaving pw-record target=default"
            return 2
        fi

        if [ -n "${node_name:-}" ]; then
            printf '%s' "$node_name"
            return 0
        fi
        node_id="$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | sed -n 's/^id \([0-9][0-9]*\),.*/\1/p' | head -n1)"
        if [ -n "${node_id:-}" ]; then
            logv "audio: using default source node id=$node_id"
            printf '%s' "$node_id"
            return 0
        fi
    fi

    log "audio: default source detection failed; using PipeWire default input"
    return 1
}

detect_alsa_capture_device() {
    if ! command -v arecord >/dev/null 2>&1; then
        return 1
    fi
    arecord -l 2>/dev/null \
        | awk '
            /^card [0-9]+:/ {
                lower = tolower($0)
                if (lower ~ /loopback/) next
                card = ""
                device = ""
                if (match($0, /card [0-9]+/)) {
                    card = substr($0, RSTART + 5, RLENGTH - 5)
                }
                if (match($0, /device [0-9]+/)) {
                    device = substr($0, RSTART + 7, RLENGTH - 7)
                }
                if (card != "" && device != "") {
                    printf "plughw:%s,%s\n", card, device
                    exit
                }
            }
        ' | head -n1
}

attempt_start_recorder() {
    local recorder_label="$1"
    shift
    local recorder_pid
    local -a record_cmd=( "$@" )

    rotate_file_if_needed "$RECORDER_LOG_FILE" "$S2T_RECORDER_LOG_MAX_BYTES" "$S2T_RECORDER_LOG_KEEP"
    if is_positive_int "$S2T_MAX_RECORD_SECONDS" && [ "$S2T_MAX_RECORD_SECONDS" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        log "start: spawning ${recorder_label} (max ${S2T_MAX_RECORD_SECONDS}s)"
        timeout --signal=TERM "${S2T_MAX_RECORD_SECONDS}s" "${record_cmd[@]}" >>"$RECORDER_LOG_FILE" 2>&1 &
    else
        log "start: spawning ${recorder_label}"
        "${record_cmd[@]}" >>"$RECORDER_LOG_FILE" 2>&1 &
    fi
    recorder_pid=$!

    # If recorder dies immediately we otherwise get random header-only files later.
    sleep 0.08
    if ! kill -0 "$recorder_pid" 2>/dev/null; then
        log "start: ${recorder_label} exited immediately pid=$recorder_pid (see $RECORDER_LOG_FILE)"
        return 1
    fi

    PID="$recorder_pid"
    echo "$PID" > "$PID_FILE"
    echo "$(now_ms)" > "$START_TS_FILE"
    echo "$recorder_label" > "$RECORDER_KIND_FILE"
    return 0
}

start_recording() {
    if [ -f "$PID_FILE" ]; then
        existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "${existing_pid:-}" ] && kill -0 "$existing_pid" 2>/dev/null; then
            # Already recording
            exit 0
        fi
        # Stale PID file from crashed recorder.
        rm -f "$PID_FILE" "$START_TS_FILE" "$RECORDER_KIND_FILE"
    fi
    
    mkdir -p "$RUNTIME_DIR"
    logv "start: ctx uid=$(id -u 2>/dev/null || echo ?) user=$(id -un 2>/dev/null || echo ?) session=${XDG_SESSION_TYPE:-?} display=${DISPLAY:-?} wayland=${WAYLAND_DISPLAY:-?} insert=${S2T_INSERT_METHOD}"

    rm -f "$AUDIO_FILE"

    # Use pipewire record
    # Format s16le 16kHz mono
    local capture_fail_streak force_default_target recorder_backend alsa_device target_rc recorder_label
    capture_fail_streak="$(capture_fail_count)"
    force_default_target=0
    recorder_backend="pipewire"
    recorder_label="pw-record"
    alsa_device=""
    if capture_default_mode_active; then
        force_default_target=1
        log "start: capture fallback cooldown active, forcing pw-record target=default"
    elif is_positive_int "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" \
        && [ "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" -gt 0 ] \
        && [ "$capture_fail_streak" -ge "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" ]; then
        force_default_target=1
    fi

    TARGET_ARGS=()
    if [ "$force_default_target" = "1" ]; then
        log "start: capture fail streak=$capture_fail_streak, forcing pw-record target=default"
    elif target="$(detect_audio_target)"; then
        TARGET_ARGS+=(--target "$target")
        log "start: pw-record target=$target"
    else
        target_rc=$?
        if [ "$S2T_ENABLE_ALSA_CAPTURE_FALLBACK" = "1" ] && [ "$target_rc" -eq 2 ]; then
            alsa_device="$(detect_alsa_capture_device || true)"
            if [ -n "${alsa_device:-}" ]; then
                recorder_backend="alsa"
                log "start: no valid PipeWire source; using arecord fallback device=$alsa_device"
            else
                log "start: pw-record target=default"
            fi
        else
            log "start: pw-record target=default"
        fi
    fi

    local recorder_started=0
    if [ "$recorder_backend" = "alsa" ]; then
        require_cmd arecord
        recorder_label="arecord"
        RECORD_CMD=(arecord -q -D "$alsa_device" -f S16_LE -r 16000 -c 1 -t wav "$AUDIO_FILE")
    else
        require_cmd pw-record
        RECORD_CMD=(pw-record --format=s16 --rate=16000 --channels=1 "${TARGET_ARGS[@]}" "$AUDIO_FILE")
    fi

    if attempt_start_recorder "$recorder_label" "${RECORD_CMD[@]}"; then
        recorder_started=1
    elif [ "$recorder_backend" = "pipewire" ] && [ "${#TARGET_ARGS[@]}" -gt 0 ]; then
        # PipeWire node names can disappear between detection and start; retry on default source.
        log "start: retrying pw-record without explicit target"
        RECORD_CMD=(pw-record --format=s16 --rate=16000 --channels=1 "$AUDIO_FILE")
        if attempt_start_recorder "pw-record" "${RECORD_CMD[@]}"; then
            recorder_started=1
        fi
    fi

    if [ "$recorder_started" != "1" ] && [ "$recorder_backend" = "pipewire" ] && [ "$S2T_ENABLE_ALSA_CAPTURE_FALLBACK" = "1" ]; then
        alsa_device="$(detect_alsa_capture_device || true)"
        if [ -n "${alsa_device:-}" ]; then
            log "start: retrying with arecord fallback device=$alsa_device"
            RECORD_CMD=(arecord -q -D "$alsa_device" -f S16_LE -r 16000 -c 1 -t wav "$AUDIO_FILE")
            if command -v arecord >/dev/null 2>&1 && attempt_start_recorder "arecord" "${RECORD_CMD[@]}"; then
                recorder_started=1
            fi
        fi
    fi

    if [ "$recorder_started" != "1" ]; then
        rm -f "$PID_FILE" "$START_TS_FILE" "$RECORDER_KIND_FILE"
        rm -f "$AUDIO_FILE" 2>/dev/null || true
        notify "S2T" "Recorder failed to start"
        exit 1
    fi
    
    # Visual feedback
    block_input_feedback
    notify -t 800 -h string:x-canonical-private-synchronous:s2t "Listening..."
}

save_secondary_buffer_text() {
    local text="$1"
    local source_id="${2:-}"
    [ "${S2T_SECONDARY_BUFFER_ENABLE:-1}" = "1" ] || return 0

    mkdir -p "$RUNTIME_DIR" >/dev/null 2>&1 || true
    printf '%s' "$text" >"$SECONDARY_TEXT_FILE" 2>/dev/null || return 1
    printf 'updated_ms=%s\nsource_id=%s\n' "$(now_ms)" "$source_id" >"$SECONDARY_META_FILE" 2>/dev/null || true

    # Mirror to X11 SECONDARY selection for power users/tools.
    if [ "${XDG_SESSION_TYPE:-}" != "wayland" ] && command -v xclip >/dev/null 2>&1; then
        printf '%s' "$text" | timeout 1s xclip -selection secondary >/dev/null 2>&1 || true
    fi
    return 0
}

load_secondary_buffer_text() {
    local text=""
    [ "${S2T_SECONDARY_BUFFER_ENABLE:-1}" = "1" ] || return 1

    if [ -f "$SECONDARY_TEXT_FILE" ]; then
        text="$(cat "$SECONDARY_TEXT_FILE" 2>/dev/null || true)"
        if [ -n "${text:-}" ]; then
            printf '%s' "$text"
            return 0
        fi
    fi

    # Fallback: try X11 SECONDARY selection.
    if [ "${XDG_SESSION_TYPE:-}" != "wayland" ] && command -v xclip >/dev/null 2>&1; then
        text="$(timeout 1s xclip -selection secondary -o 2>/dev/null || true)"
        if [ -n "${text:-}" ]; then
            printf '%s' "$text"
            return 0
        fi
    fi

    return 1
}

secondary_clear() {
    rm -f "$SECONDARY_TEXT_FILE" 2>/dev/null || true
    rm -f "$SECONDARY_META_FILE" 2>/dev/null || true
    if [ "${XDG_SESSION_TYPE:-}" != "wayland" ] && command -v xclip >/dev/null 2>&1; then
        printf '' | timeout 1s xclip -selection secondary >/dev/null 2>&1 || true
    fi
    log "manual-secondary: clear"
    notify -t 600 "S2T secondary cleared"
}

secondary_copy_buffer() {
    local text
    text="$(load_secondary_buffer_text || true)"
    if [ -z "${text//[[:space:]]/}" ]; then
        log "manual-secondary: copy requested but buffer is empty"
        notify -t 800 "S2T secondary is empty"
        return 1
    fi

    if save_secondary_buffer_text "$text"; then
        log "manual-secondary: copied len=${#text}"
        notify -t 700 "S2T secondary copied"
        return 0
    fi
    log "manual-secondary: failed to copy (secondary unavailable)"
    notify -t 900 "S2T secondary unavailable"
    return 1
}

clipboard_read_to_file() {
    local out_file="$1"
    mkdir -p "$(dirname "$out_file")" >/dev/null 2>&1 || true

    if [ "${XDG_SESSION_TYPE:-}" = "x11" ] && command -v xclip >/dev/null 2>&1; then
        if timeout 1s xclip -selection clipboard -o >"$out_file" 2>/dev/null; then
            return 0
        fi
        : >"$out_file"
        return 0
    fi

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && command -v wl-paste >/dev/null 2>&1; then
        if timeout 1s wl-paste >"$out_file" 2>/dev/null; then
            return 0
        fi
        : >"$out_file"
        return 0
    fi

    return 1
}

clipboard_write_from_file() {
    local in_file="$1"
    if [ ! -f "$in_file" ]; then
        return 1
    fi

    if [ "${XDG_SESSION_TYPE:-}" = "x11" ] && command -v xclip >/dev/null 2>&1; then
        timeout 1s xclip -selection clipboard -i <"$in_file" >/dev/null 2>&1
        return $?
    fi

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && command -v wl-copy >/dev/null 2>&1; then
        timeout 1s wl-copy <"$in_file" >/dev/null 2>&1
        return $?
    fi

    return 1
}

clipboard_write_text() {
    local text="$1"
    local tmp_file
    tmp_file="$(mktemp "$RUNTIME_DIR/clipboard_text.XXXXXX")"
    printf '%s' "$text" >"$tmp_file"
    clipboard_write_from_file "$tmp_file"
    local rc=$?
    rm -f "$tmp_file" 2>/dev/null || true
    return $rc
}

restore_clipboard_with_retry() {
    local in_file="$1"
    local attempts="${2:-5}"
    local retry_delay_ms="${3:-80}"
    local i

    if [ ! -f "$in_file" ]; then
        return 1
    fi

    for i in $(seq 1 "$attempts"); do
        if clipboard_write_from_file "$in_file"; then
            return 0
        fi
        sleep_ms "$retry_delay_ms"
    done
    return 1
}

compute_clipboard_restore_delay_ms() {
    local text="$1"
    local base extra delay text_len per_char extra_max
    base="$S2T_CLIPBOARD_RESTORE_DELAY_MS"
    per_char="$S2T_CLIPBOARD_RESTORE_PER_CHAR_MS"
    extra_max="$S2T_CLIPBOARD_RESTORE_EXTRA_MAX_MS"
    text_len=${#text}

    if ! is_positive_int "$base"; then
        base=350
    fi
    if ! is_positive_int "$per_char"; then
        per_char=0
    fi
    if ! is_positive_int "$extra_max"; then
        extra_max=2500
    fi

    extra=0
    if [ "$per_char" -gt 0 ] && [ "$text_len" -gt 0 ]; then
        extra=$((text_len * per_char))
        if [ "$extra_max" -gt 0 ] && [ "$extra" -gt "$extra_max" ]; then
            extra="$extra_max"
        fi
    fi
    delay=$((base + extra))
    printf '%s' "$delay"
}

paste_clipboard_shortcut() {
    local keys cls title
    local type_timeout_sec timeout_cmd=()
    keys="$(select_paste_keys)"
    if [ "$S2T_DEBUG_TIMING" = "1" ] && [ "$S2T_PASTE_KEYS" = "auto" ]; then
        cls="$(focused_wm_class_x11 || true)"
        title="$(focused_wm_title_x11 || true)"
        log "insert: auto keys=${keys} wm_class=${cls:-unknown} wm_title=${title:-unknown}"
    fi
    refocus_target_window_before_insert

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        if command -v wtype >/dev/null 2>&1; then
            case "$keys" in
                shift+insert) wtype -M shift -P Insert -p Insert -m shift ;;
                ctrl+shift+v) wtype -M ctrl -M shift -P v -p v -m shift -m ctrl ;;
                *)            wtype -M ctrl -P v -p v -m ctrl ;;
            esac
            return 0
        fi
        if command -v ydotool >/dev/null 2>&1; then
            case "$keys" in
                shift+insert) ydotool key 42:1 110:1 110:0 42:0 ;;
                ctrl+shift+v) ydotool key 29:1 42:1 47:1 47:0 42:0 29:0 ;;
                *)            ydotool key 29:1 47:1 47:0 29:0 ;;
            esac
            return 0
        fi
        return 1
    fi

    type_timeout_sec="${S2T_X11_TYPE_TIMEOUT_SEC:-2}"
    if is_positive_int "$type_timeout_sec" && [ "$type_timeout_sec" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        timeout_cmd=(timeout --signal=TERM "${type_timeout_sec}s")
    fi

    if command -v xdotool >/dev/null 2>&1; then
        case "$keys" in
            shift+insert) "${timeout_cmd[@]}" xdotool key --clearmodifiers shift+Insert ;;
            ctrl+shift+v) "${timeout_cmd[@]}" xdotool key --clearmodifiers ctrl+shift+v ;;
            *)            "${timeout_cmd[@]}" xdotool key --clearmodifiers ctrl+v ;;
        esac
        return $?
    fi
    if command -v ydotool >/dev/null 2>&1; then
        case "$keys" in
            shift+insert) "${timeout_cmd[@]}" ydotool key 42:1 110:1 110:0 42:0 ;;
            ctrl+shift+v) "${timeout_cmd[@]}" ydotool key 29:1 42:1 47:1 47:0 42:0 29:0 ;;
            *)            "${timeout_cmd[@]}" ydotool key 29:1 47:1 47:0 29:0 ;;
        esac
        return $?
    fi
    return 1
}

x11_insert_via_clipboard_transport() {
    local text="$1"
    local prev_clip_file="$RUNTIME_DIR/clipboard_prev.txt"
    local preserve_ok=0
    local restore_delay_ms

    if [ "${XDG_SESSION_TYPE:-}" != "x11" ]; then
        return 1
    fi

    if [ "$S2T_PRESERVE_CLIPBOARD" = "1" ]; then
        if clipboard_read_to_file "$prev_clip_file"; then
            preserve_ok=1
        else
            log "insert: cannot snapshot clipboard before X11 transport"
            if [ "$S2T_PRESERVE_CLIPBOARD_STRICT" = "1" ]; then
                return 1
            fi
        fi
    fi

    if ! clipboard_write_text "$text"; then
        log "insert: failed to write temporary clipboard transport"
        return 1
    fi

    # Give X-server a moment to register the new selection owner
    sleep_ms 30

    if ! paste_clipboard_shortcut; then
        log "insert: paste shortcut failed"
        if [ "$preserve_ok" = "1" ]; then
            restore_clipboard_with_retry "$prev_clip_file" 6 80 || true
        fi
        return 1
    fi

    log "insert: pasted-via-clipboard-transport"
    if [ "$preserve_ok" = "1" ]; then
        # Extremely fast restoration
        sleep_ms "${S2T_CLIPBOARD_RESTORE_DELAY_MS:-50}"
        if ! restore_clipboard_with_retry "$prev_clip_file" 3 50; then
            log "insert: failed to restore previous clipboard after X11 transport"
        fi
    fi
    return 0
}

secondary_mode_allows_insert() {
    local mode="${1:-auto}"

    if [ "${XDG_SESSION_TYPE:-}" != "x11" ]; then
        return 0
    fi

    case "$mode" in
        manual)
            [ "${S2T_X11_SECONDARY_MANUAL_PASTE:-1}" = "1" ]
            ;;
        *)
            [ "${S2T_X11_SECONDARY_AUTO_INSERT:-0}" = "1" ]
            ;;
    esac
}

insert_from_secondary_buffer() {
    local text="$1"
    local mode="${2:-auto}"
    if [ -z "${text//[[:space:]]/}" ]; then
        return 1
    fi
    if ! secondary_mode_allows_insert "$mode"; then
        return 2
    fi
    if [ "${XDG_SESSION_TYPE:-}" = "x11" ]; then
        x11_insert_via_clipboard_transport "$text"
        return $?
    fi
    refocus_target_window_before_insert
    inject_text_without_clipboard "$text"
}

secondary_paste_to_focused_app() {
    local text
    local insert_rc=0
    local wait_ms
    wait_ms="${S2T_SECONDARY_WAIT_FOR_FRESH_MS:-12000}"

    if is_recording_or_transcribing; then
        log "manual-secondary: waiting for active record/transcribe before paste"
        if ! wait_for_transcribe_idle "$wait_ms"; then
            log "manual-secondary: paste refused; transcribe still in progress after ${wait_ms}ms"
            notify -t 900 "S2T still transcribing"
            return 1
        fi
    fi

    text="$(load_secondary_buffer_text || true)"
    if [ -z "${text//[[:space:]]/}" ]; then
        log "manual-secondary: paste requested but buffer is empty"
        notify -t 800 "S2T secondary is empty"
        return 1
    fi

    if insert_from_secondary_buffer "$text" manual; then
        log "manual-secondary: pasted via secondary buffer len=${#text}"
        notify -t 700 "S2T secondary typed"
        return 0
    else
        insert_rc=$?
    fi
    if [ "$insert_rc" -eq 2 ]; then
        log "manual-secondary: paste blocked on X11 (manual secondary paste disabled)"
        notify -t 900 "S2T secondary paste disabled on X11"
        return 1
    fi
    log "manual-secondary: paste failed (no injection tool)"
    notify -t 900 "S2T paste failed"
    return 1
}

inject_text_without_clipboard() {
    local text="$1"
    local type_timeout_sec timeout_cmd=()

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        if command -v wtype >/dev/null 2>&1; then
            wtype "$text"
            return 0
        fi
        if command -v ydotool >/dev/null 2>&1; then
            ydotool type "$text"
            return 0
        fi
        return 1
    fi

    type_timeout_sec="${S2T_X11_TYPE_TIMEOUT_SEC:-2}"
    if is_positive_int "$type_timeout_sec" && [ "$type_timeout_sec" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        timeout_cmd=(timeout --signal=TERM "${type_timeout_sec}s")
    fi

    if command -v xdotool >/dev/null 2>&1; then
        "${timeout_cmd[@]}" xdotool type --clearmodifiers --delay "$S2T_XDOTOOL_DELAY_MS" -- "$text"
        return $?
    fi
    if command -v ydotool >/dev/null 2>&1; then
        "${timeout_cmd[@]}" ydotool type "$text"
        return $?
    fi
    return 1
}

capture_target_window_for_insert() {
    local win_id
    if [ "${S2T_REFOCUS_TARGET_WINDOW:-1}" != "1" ]; then
        rm -f "$TARGET_WINDOW_FILE" 2>/dev/null || true
        return 0
    fi
    win_id="$(focused_window_id_x11 || true)"
    if [[ "${win_id:-}" =~ ^[0-9]+$ ]] && [ "$win_id" -gt 0 ]; then
        printf '%s\n' "$win_id" >"$TARGET_WINDOW_FILE" 2>/dev/null || true
        logv "insert: captured target_window_id=$win_id"
    else
        rm -f "$TARGET_WINDOW_FILE" 2>/dev/null || true
    fi
}

refocus_target_window_before_insert() {
    local win_id
    if [ "${S2T_REFOCUS_TARGET_WINDOW:-1}" != "1" ]; then
        return 0
    fi
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] || ! command -v xdotool >/dev/null 2>&1; then
        return 0
    fi
    win_id="$(cat "$TARGET_WINDOW_FILE" 2>/dev/null || true)"
    if ! [[ "${win_id:-}" =~ ^[0-9]+$ ]] || [ "$win_id" -le 0 ]; then
        return 0
    fi
    if xdotool windowactivate --sync "$win_id" >/dev/null 2>&1; then
        sleep_ms 40
        xdotool windowfocus "$win_id" >/dev/null 2>&1 || true
        logv "insert: refocused target_window_id=$win_id"
    else
        logv "insert: failed to refocus target_window_id=$win_id"
    fi
}


transcribe_with_server() {
    require_cmd curl
    require_cmd jq

    local audio_sec="${1:-}"
    local server_timeout_sec="$S2T_SERVER_TIMEOUT_SEC"
    # For local-first mode, do not cut long dictation by client-side timeout.
    # Keep timeout behavior only when local server is used as a fallback from cloud providers.
    if [ "$S2T_ASR_PROVIDER" = "local" ]; then
        server_timeout_sec=0
    else
        server_timeout_sec="$(compute_server_effective_timeout_sec "$audio_sec")"
    fi

    local curl_timeout_args=()
    if is_positive_int "$server_timeout_sec" && [ "$server_timeout_sec" -gt 0 ]; then
        curl_timeout_args=(--max-time "$server_timeout_sec")
    fi
    local response
    response="$(curl -sf "${curl_timeout_args[@]}" \
        -F "file=@${AUDIO_FILE};type=audio/wav" \
        "$S2T_WHISPER_SERVER_URL" \
        2>>"$LOG_FILE" || true)"

    if [ -z "${response//[[:space:]]/}" ]; then
        return 1
    fi

    printf '%s' "$response" | jq -r '.text // ""' 2>/dev/null || true
}

transcribe_with_openai() {
    require_cmd curl
    require_cmd jq

    if [ -z "${S2T_OPENAI_API_KEY:-}" ]; then
        log "asr: openai missing S2T_OPENAI_API_KEY"
        return 1
    fi

    local url="${S2T_OPENAI_BASE_URL%/}/audio/transcriptions"
    local curl_timeout_args=()
    if is_positive_int "$S2T_OPENAI_TIMEOUT_SEC" && [ "$S2T_OPENAI_TIMEOUT_SEC" -gt 0 ]; then
        curl_timeout_args=(--max-time "$S2T_OPENAI_TIMEOUT_SEC")
    fi
    local response
    response="$(curl -sf "${curl_timeout_args[@]}" \
        -H "Authorization: Bearer ${S2T_OPENAI_API_KEY}" \
        -F "file=@${AUDIO_FILE};type=audio/wav" \
        -F "model=${S2T_OPENAI_MODEL}" \
        -F "response_format=json" \
        "$url" \
        2>>"$LOG_FILE" || true)"

    if [ -z "${response//[[:space:]]/}" ]; then
        return 1
    fi

    printf '%s' "$response" | jq -r '.text // ""' 2>/dev/null || true
}

transcribe_with_gcp_l4() {
    require_cmd curl
    require_cmd jq

    local audio_sec="${1:-}"
    if [ -z "${S2T_GCP_WHISPER_URL//[[:space:]]/}" ]; then
        log "asr: gcp-l4 missing S2T_GCP_WHISPER_URL"
        return 1
    fi

    local infer_path="${S2T_GCP_WHISPER_INFER_PATH:-/inference}"
    if [ -z "${infer_path:-}" ]; then
        infer_path="/inference"
    elif [ "${infer_path#/}" = "$infer_path" ]; then
        infer_path="/${infer_path}"
    fi

    local url="${S2T_GCP_WHISPER_URL%/}${infer_path}"
    local language="${S2T_LANG:-auto}"
    local curl_timeout_args=()
    local curl_connect_args=()
    local curl_auth_args=()
    local curl_form_args=()
    local response

    if is_positive_int "$S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC" && [ "$S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC" -gt 0 ]; then
        curl_connect_args=(--connect-timeout "$S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC")
    fi
    local gcp_timeout_sec
    gcp_timeout_sec="$(compute_gcp_effective_timeout_sec "$audio_sec")"
    if is_positive_int "$gcp_timeout_sec" && [ "$gcp_timeout_sec" -gt 0 ]; then
        curl_timeout_args=(--max-time "$gcp_timeout_sec")
    fi
    if [ -n "${S2T_GCP_WHISPER_BEARER_TOKEN:-}" ]; then
        curl_auth_args=(-H "Authorization: Bearer ${S2T_GCP_WHISPER_BEARER_TOKEN}")
    fi

    curl_form_args=(-F "audio=@${AUDIO_FILE};type=audio/wav")
    if [ -n "${language//[[:space:]]/}" ]; then
        curl_form_args+=(-F "language=${language}")
    fi
    if [ "${S2T_GCP_WHISPER_TRANSLATE}" = "1" ]; then
        curl_form_args+=(-F "translate=true")
    else
        curl_form_args+=(-F "translate=false")
    fi
    if is_positive_int "$S2T_GCP_WHISPER_THREADS" && [ "$S2T_GCP_WHISPER_THREADS" -gt 0 ]; then
        curl_form_args+=(-F "threads=${S2T_GCP_WHISPER_THREADS}")
    fi

    response="$(curl -sf "${curl_connect_args[@]}" "${curl_timeout_args[@]}" "${curl_auth_args[@]}" \
        "${curl_form_args[@]}" \
        "$url" \
        2>>"$LOG_FILE" || true)"

    if [ -z "${response//[[:space:]]/}" ]; then
        return 1
    fi

    printf '%s' "$response" \
        | jq -r '.text // .result.text // .result.whisper.text // (.whisper.transcription // [] | map(.text // "") | join(" ")) // (.result.whisper.transcription // [] | map(.text // "") | join(" ")) // ""' 2>/dev/null \
        || true
}

transcribe_with_google() {
    require_cmd python3

    if [ -z "${S2T_GOOGLE_API_KEY:-}" ] && [ -z "${S2T_GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
        log "asr: google missing S2T_GOOGLE_API_KEY and S2T_GOOGLE_APPLICATION_CREDENTIALS"
        return 1
    fi

    local google_timeout_sec google_guard_sec
    google_timeout_sec="${S2T_GOOGLE_REQUEST_TIMEOUT_SEC:-$S2T_GOOGLE_TIMEOUT_SEC}"
    google_guard_sec="${S2T_GOOGLE_REQUEST_GUARD_SEC:-$S2T_MAX_RESPONSE_SECONDS}"

    local google_guard_cmd=()
    if is_positive_int "$google_guard_sec" && [ "$google_guard_sec" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        google_guard_cmd=(timeout --signal=TERM "${google_guard_sec}s")
    fi

    # Timeout semantics:
    # - optional hard cap for the whole cloud request (S2T_MAX_RESPONSE_SECONDS)
    # - optional response timeout once request is sent (S2T_GOOGLE_TIMEOUT_SEC)
    S2T_GOOGLE_API_KEY="${S2T_GOOGLE_API_KEY:-}" \
    S2T_GOOGLE_APPLICATION_CREDENTIALS="${S2T_GOOGLE_APPLICATION_CREDENTIALS:-}" \
    S2T_GOOGLE_API_ENDPOINT="$S2T_GOOGLE_API_ENDPOINT" \
    S2T_GOOGLE_MODEL="$S2T_GOOGLE_MODEL" \
    S2T_GOOGLE_LANGUAGE_CODE="$S2T_GOOGLE_LANGUAGE_CODE" \
    S2T_GOOGLE_ALT_LANGUAGE_CODES="$S2T_GOOGLE_ALT_LANGUAGE_CODES" \
    S2T_GOOGLE_ENABLE_PUNCTUATION="$S2T_GOOGLE_ENABLE_PUNCTUATION" \
    S2T_GOOGLE_CONNECT_TIMEOUT_SEC="$S2T_GOOGLE_CONNECT_TIMEOUT_SEC" \
    S2T_GOOGLE_TIMEOUT_SEC="$google_timeout_sec" \
    "${google_guard_cmd[@]}" python3 - "$AUDIO_FILE" 2>>"$LOG_FILE" <<'PY'
import base64
import http.client
import json
import os
import socket
import sys
import urllib.parse

audio_path = sys.argv[1]
api_key = os.environ.get("S2T_GOOGLE_API_KEY", "").strip()
creds_path = os.environ.get("S2T_GOOGLE_APPLICATION_CREDENTIALS", "").strip()
endpoint = os.environ.get("S2T_GOOGLE_API_ENDPOINT", "https://speech.googleapis.com/v1/speech:recognize")
lang = os.environ.get("S2T_GOOGLE_LANGUAGE_CODE", "ru-RU")
model = os.environ.get("S2T_GOOGLE_MODEL", "latest_short")
alt = os.environ.get("S2T_GOOGLE_ALT_LANGUAGE_CODES", "").strip()
punct = os.environ.get("S2T_GOOGLE_ENABLE_PUNCTUATION", "1") == "1"
connect_timeout_raw = os.environ.get("S2T_GOOGLE_CONNECT_TIMEOUT_SEC", "3")
timeout_raw = os.environ.get("S2T_GOOGLE_TIMEOUT_SEC", "0")

if not api_key and not creds_path:
    sys.stderr.write("google missing api key and credentials\n")
    raise SystemExit(1)

try:
    connect_timeout = float(connect_timeout_raw)
except ValueError:
    connect_timeout = 3.0
if connect_timeout <= 0:
    connect_timeout = None

try:
    response_timeout = float(timeout_raw)
except ValueError:
    response_timeout = 0.0
if response_timeout <= 0:
    response_timeout = None

with open(audio_path, "rb") as f:
    content_b64 = base64.b64encode(f.read()).decode("ascii")

alt_list = [x.strip() for x in alt.split(",") if x.strip()] if alt else []
req = {
    "config": {
        "encoding": "LINEAR16",
        "sampleRateHertz": 16000,
        "languageCode": lang,
        "alternativeLanguageCodes": alt_list,
        "model": model,
        "enableAutomaticPunctuation": punct,
    },
    "audio": {"content": content_b64},
}
body = json.dumps(req, ensure_ascii=False).encode("utf-8")

parsed = urllib.parse.urlparse(endpoint)
scheme = parsed.scheme or "https"
host = parsed.netloc
path = parsed.path or "/"
if parsed.query:
    path = f"{path}?{parsed.query}"

headers = {"Content-Type": "application/json"}

if api_key:
    sep = "&" if "?" in path else "?"
    path = f"{path}{sep}key={urllib.parse.quote(api_key, safe='')}"
else:
    import urllib.request
    try:
        with open(creds_path) as f:
            creds = json.load(f)
        req_token = urllib.request.Request("https://oauth2.googleapis.com/token", data=urllib.parse.urlencode({
            "client_id": creds["client_id"],
            "client_secret": creds["client_secret"],
            "refresh_token": creds["refresh_token"],
            "grant_type": "refresh_token"
        }).encode("utf-8"))
        with urllib.request.urlopen(req_token) as resp_token:
            token = json.loads(resp_token.read())["access_token"]
        headers["Authorization"] = f"Bearer {token}"
        headers["x-goog-user-project"] = creds.get("quota_project_id", "")
    except Exception as e:
        sys.stderr.write(f"google failed to get token: {e}\n")
        raise SystemExit(1)

if not host:
    sys.stderr.write(f"google invalid endpoint: {endpoint}\n")
    raise SystemExit(1)

conn_cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
conn = conn_cls(host, timeout=connect_timeout)

try:
    conn.request("POST", path, body=body, headers=headers)
    if response_timeout is not None and conn.sock is not None:
        conn.sock.settimeout(response_timeout)
    resp = conn.getresponse()
    payload = resp.read().decode("utf-8", errors="replace")
except socket.timeout:
    sys.stderr.write("google response timeout\n")
    raise SystemExit(124)
except Exception as e:
    sys.stderr.write(f"google request failed: {e}\n")
    raise SystemExit(1)
finally:
    try:
        conn.close()
    except Exception:
        pass

if not payload.strip():
    raise SystemExit(0)

try:
    data = json.loads(payload)
except json.JSONDecodeError:
    sys.stderr.write("google returned invalid json\n")
    raise SystemExit(1)

error = data.get("error") or {}
err_msg = error.get("message")
if err_msg:
    sys.stderr.write(f"google error: {err_msg}\n")
    raise SystemExit(1)

parts = []
for result in data.get("results", []) or []:
    for alt_item in result.get("alternatives", []) or []:
        text = alt_item.get("transcript")
        if text:
            parts.append(text)

out = " ".join(parts).strip()
try:
    sys.stdout.write(out)
except BrokenPipeError:
    pass
PY
}

resolve_gcp_project() {
    local project
    project="${S2T_GCP_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}"
    if [ -n "${project//[[:space:]]/}" ]; then
        printf '%s' "$project"
        return 0
    fi

    if [ -n "${S2T_GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -r "${S2T_GOOGLE_APPLICATION_CREDENTIALS:-}" ] && command -v python3 >/dev/null 2>&1; then
        project="$(python3 - "${S2T_GOOGLE_APPLICATION_CREDENTIALS}" 2>/dev/null <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    raise SystemExit(0)

project = (data.get("project_id") or data.get("quota_project_id") or "").strip()
if project:
    print(project)
PY
)"
        if [ -n "${project//[[:space:]]/}" ]; then
            printf '%s' "$project"
            return 0
        fi
    fi

    return 1
}

google_v2_ready_for_retry() {
    local project
    [ "$S2T_GOOGLE_V2_ON_EMPTY" = "1" ] || return 1
    [ -n "${S2T_GOOGLE_APPLICATION_CREDENTIALS//[[:space:]]/}" ] || return 1
    [ -r "${S2T_GOOGLE_APPLICATION_CREDENTIALS}" ] || return 1
    project="$(resolve_gcp_project || true)"
    [ -n "${project//[[:space:]]/}" ] || return 1
    if ! python3 -c 'import google.cloud.speech_v2' >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

transcribe_with_google_v2() {
    require_cmd python3
    if ! python3 -c 'import google.cloud.speech_v2' >/dev/null 2>&1; then
        log "asr: google-v2 missing python deps (google-cloud-speech). Reinstall S2T."
        return 1
    fi

    local project
    project="$(resolve_gcp_project || true)"
    if [ -z "${project//[[:space:]]/}" ]; then
        log "asr: google-v2 missing GCP project (set S2T_GCP_PROJECT)"
        return 1
    fi

    if [ -z "${S2T_GOOGLE_APPLICATION_CREDENTIALS//[[:space:]]/}" ]; then
        log "asr: google-v2 missing credentials (set S2T_GOOGLE_APPLICATION_CREDENTIALS to a service-account JSON path)"
        return 1
    fi
    if [ ! -r "${S2T_GOOGLE_APPLICATION_CREDENTIALS}" ]; then
        log "asr: google-v2 credentials file unreadable: ${S2T_GOOGLE_APPLICATION_CREDENTIALS}"
        return 1
    fi

    local location="${S2T_GOOGLE_V2_LOCATION}"
    local recognizer_id="${S2T_GOOGLE_V2_RECOGNIZER}"
    if [ -z "${recognizer_id//[[:space:]]/}" ]; then
        recognizer_id="_"
    fi

    local recognizer_name="projects/${project}/locations/${location}/recognizers/${recognizer_id}"

    # Run the v2 call via the official client (gRPC) so regional endpoints work.
    # Endpoint defaults:
    # - global: speech.googleapis.com
    # - regional: ${location}-speech.googleapis.com
    local endpoint
    if [ "$location" = "global" ]; then
        endpoint="speech.googleapis.com"
    else
        endpoint="${location}-speech.googleapis.com"
    fi

    local model langs
    model="${S2T_GOOGLE_V2_MODEL}"
    langs="${S2T_GOOGLE_V2_LANGUAGE_CODES}"

    GOOGLE_APPLICATION_CREDENTIALS="$S2T_GOOGLE_APPLICATION_CREDENTIALS" \
    GOOGLE_CLOUD_PROJECT="$project" \
    S2T_GOOGLE_V2_ENDPOINT="$endpoint" \
    S2T_GOOGLE_V2_RECOGNIZER_NAME="$recognizer_name" \
    S2T_GOOGLE_V2_MODEL="$model" \
    S2T_GOOGLE_V2_LANGUAGE_CODES="$langs" \
    S2T_GOOGLE_V2_ENABLE_PUNCTUATION="$S2T_GOOGLE_V2_ENABLE_PUNCTUATION" \
    S2T_GOOGLE_V2_TIMEOUT_SEC="$S2T_GOOGLE_V2_TIMEOUT_SEC" \
    python3 - "$AUDIO_FILE" 2>>"$LOG_FILE" <<'PY'
import os, sys
from google.cloud.speech_v2 import SpeechClient
from google.cloud.speech_v2.types import cloud_speech
from google.api_core.client_options import ClientOptions
from google.api_core import exceptions

audio_path = sys.argv[1]
with open(audio_path, "rb") as f:
    content = f.read()

endpoint = os.environ.get("S2T_GOOGLE_V2_ENDPOINT", "speech.googleapis.com")
recognizer = os.environ["S2T_GOOGLE_V2_RECOGNIZER_NAME"]
model = os.environ.get("S2T_GOOGLE_V2_MODEL", "chirp_2")
langs = os.environ.get("S2T_GOOGLE_V2_LANGUAGE_CODES", "ru-RU,en-US")
punct = os.environ.get("S2T_GOOGLE_V2_ENABLE_PUNCTUATION", "1") == "1"

language_codes = [x.strip() for x in langs.split(",") if x.strip()]

client = SpeechClient(client_options=ClientOptions(api_endpoint=endpoint))

config = cloud_speech.RecognitionConfig(
    auto_decoding_config=cloud_speech.AutoDetectDecodingConfig(),
    language_codes=language_codes,
    model=model,
    features=cloud_speech.RecognitionFeatures(enable_automatic_punctuation=punct),
)

req = cloud_speech.RecognizeRequest(
    recognizer=recognizer,
    config=config,
    content=content,
)

timeout_raw = os.environ.get("S2T_GOOGLE_V2_TIMEOUT_SEC", "0")
timeout = None
try:
    timeout_value = float(timeout_raw)
    if timeout_value > 0:
        timeout = timeout_value
except ValueError:
    timeout = None

try:
    if timeout is None:
        resp = client.recognize(request=req)
    else:
        resp = client.recognize(request=req, timeout=timeout)
except exceptions.GoogleAPICallError as e:
    sys.stderr.write(f"google-v2 error: {e}\\n")
    raise SystemExit(1)

parts = []
for r in resp.results:
    for alt in r.alternatives:
        if getattr(alt, "transcript", ""):
            parts.append(alt.transcript)

sys.stdout.write(" ".join(parts).strip())
PY
}

stop_and_transcribe() {
    local stop_lock_held=0
    local transcribe_slot_held=0
    local transcribe_slot_acquired=0
    local transcribe_acquire_retry_iters=0
    local recorder_kind stop_signal

    if [ ! -f "$PID_FILE" ]; then
        exit 0
    fi
    mkdir -p "$RUNTIME_DIR"

    # Prevent duplicate stop/transcribe handlers from racing on shared files.
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$STOP_LOCK_FILE"
        if ! flock -n 9; then
            log "stop: another transcribe is in progress; ignoring duplicate stop"
            exit 0
        fi
        stop_lock_held=1
    fi

    transcribe_id="$(now_ms)_$$"
    session_audio_file="$RUNTIME_DIR/current_recording_${transcribe_id}.wav"
    logv "stop: begin transcribe_id=$transcribe_id controller_pid=$$"

    cleanup_audio() {
        if [ "${transcribe_slot_held:-0}" = "1" ]; then
            release_transcribe_slot
            transcribe_slot_held=0
        fi
        if [ "$S2T_KEEP_AUDIO" != "1" ]; then
            rm -f "$AUDIO_FILE" 2>/dev/null || true
        fi
        cleanup_transcribe_artifacts
    }
    trap cleanup_audio EXIT

    recording_ms=""
    if [ -f "$START_TS_FILE" ]; then
        start_ms="$(cat "$START_TS_FILE" 2>/dev/null || true)"
        if [[ "${start_ms:-}" =~ ^[0-9]+$ ]]; then
            stop_ms_now="$(now_ms)"
            if [ "$stop_ms_now" -ge "$start_ms" ]; then
                recording_ms=$((stop_ms_now - start_ms))
            fi
        fi
    fi

    PID=$(cat "$PID_FILE")
    recorder_kind="$(cat "$RECORDER_KIND_FILE" 2>/dev/null || echo recorder)"
    stop_signal="TERM"
    if [ "$recorder_kind" = "arecord" ]; then
        stop_signal="INT"
    fi
    # Graceful stop
    t_stop_start="$(now_ms)"
    log "stop: stopping recorder pid=$PID kind=$recorder_kind signal=$stop_signal"
    kill -s "$stop_signal" "$PID" 2>/dev/null || true

    # `start` and `stop` run in separate controller processes, so the recorder
    # PID is usually not our child. Avoid `wait` and poll instead so we don't
    # race against the WAV header flush.
    stop_wait_iters=0
    for _ in $(seq 1 200); do
        stop_wait_iters=$((stop_wait_iters + 1))
        if ! kill -0 "$PID" 2>/dev/null; then
            break
        fi
        sleep 0.01
    done
    if kill -0 "$PID" 2>/dev/null; then
        log "stop: pw-record still alive after TERM, sending KILL pid=$PID"
        kill -KILL "$PID" 2>/dev/null || true
        for _ in $(seq 1 100); do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 0.01
        done
    fi

    # Keep PID_FILE until this capture is isolated from subsequent recordings.
    if [ -f "$AUDIO_FILE" ]; then
        if mv -f "$AUDIO_FILE" "$session_audio_file" 2>/dev/null; then
            AUDIO_FILE="$session_audio_file"
        elif cp -f "$AUDIO_FILE" "$session_audio_file" 2>/dev/null; then
            AUDIO_FILE="$session_audio_file"
        fi
    fi
    rm -f "$PID_FILE" "$START_TS_FILE" "$RECORDER_KIND_FILE"
    capture_target_window_for_insert

    # Release stop lock before long-running network/transcription/insert ops.
    # Some injection tools can keep background children alive and would
    # otherwise inherit the lock fd and block all future "stop" actions.
    if [ "$stop_lock_held" = "1" ]; then
        flock -u 9 || true
        exec 9>&-
        stop_lock_held=0
    fi

    t_stop_end="$(now_ms)"
    if [ "$S2T_DEBUG_TIMING" = "1" ]; then
        log "timing: stop_flush_ms=$((t_stop_end - t_stop_start)) iters=${stop_wait_iters}"
    fi

    notify -t 800 -h string:x-canonical-private-synchronous:s2t "Transcribing..."

    if [ ! -s "$AUDIO_FILE" ]; then
        fail_count="$(increment_capture_fail_count)"
        log "stop: no audio captured (empty wav, fail_streak=$fail_count)"
        if is_positive_int "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" \
            && [ "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" -gt 0 ] \
            && [ "$fail_count" -ge "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" ]; then
            set_capture_default_until_now_plus "$S2T_CAPTURE_DEFAULT_COOLDOWN_SEC"
        fi
        exit 0
    fi

    audio_bytes="$(file_size_bytes "$AUDIO_FILE")"
    if [ "${audio_bytes:-0}" -le 44 ]; then
        # Give PipeWire a brief chance to finish flushing file payload.
        for _ in $(seq 1 20); do
            sleep 0.02
            audio_bytes="$(file_size_bytes "$AUDIO_FILE")"
            if [ "${audio_bytes:-0}" -gt 44 ]; then
                break
            fi
        done
    fi
    if [ "${audio_bytes:-0}" -le 44 ]; then
        fail_count="$(increment_capture_fail_count)"
        log "stop: no audio captured (wav header only, bytes=$audio_bytes hold_ms=${recording_ms:-?} fail_streak=$fail_count)"
        if is_positive_int "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" \
            && [ "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" -gt 0 ] \
            && [ "$fail_count" -ge "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" ]; then
            set_capture_default_until_now_plus "$S2T_CAPTURE_DEFAULT_COOLDOWN_SEC"
        fi
        exit 0
    fi

    if acquire_transcribe_slot; then
        transcribe_slot_acquired=1
    elif is_positive_int "$S2T_TRANSCRIBE_ACQUIRE_RETRY_MS" && [ "$S2T_TRANSCRIBE_ACQUIRE_RETRY_MS" -gt 0 ]; then
        transcribe_acquire_retry_iters=$(((S2T_TRANSCRIBE_ACQUIRE_RETRY_MS + 49) / 50))
        if [ "$transcribe_acquire_retry_iters" -lt 1 ]; then
            transcribe_acquire_retry_iters=1
        fi
        for _ in $(seq 1 "$transcribe_acquire_retry_iters"); do
            sleep 0.05
            if acquire_transcribe_slot; then
                transcribe_slot_acquired=1
                break
            fi
        done
    fi

    if [ "$transcribe_slot_acquired" != "1" ]; then
        if [ "$S2T_DROP_WHEN_BUSY" = "1" ]; then
            log "transcribe: busy, dropping capture to avoid queue buildup (hold_ms=${recording_ms:-?} bytes=$audio_bytes)"
            exit 0
        fi
        log "transcribe: busy, waiting for slot (drop_when_busy=0)"
        while true; do
            sleep 0.05
            if acquire_transcribe_slot; then
                transcribe_slot_acquired=1
                break
            fi
        done
    fi
    transcribe_slot_held=1

    audio_sec=""
    if command -v sox >/dev/null 2>&1; then
        audio_sec="$(sox --i -D "$AUDIO_FILE" 2>/dev/null || true)"
    fi
    logv "audio: transcribe_id=$transcribe_id bytes=$audio_bytes sec=${audio_sec:-?} hold_ms=${recording_ms:-?} file=$(basename "$AUDIO_FILE")"
    if [ -n "${audio_sec:-}" ] && ! duration_gt "$audio_sec" "$S2T_MIN_AUDIO_SECONDS"; then
        fail_count="$(increment_capture_fail_count)"
        log "stop: skipping invalid audio capture (audio_sec=$audio_sec bytes=$audio_bytes min=$S2T_MIN_AUDIO_SECONDS fail_streak=$fail_count)"
        if is_positive_int "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" \
            && [ "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" -gt 0 ] \
            && [ "$fail_count" -ge "$S2T_CAPTURE_FAIL_FALLBACK_THRESHOLD" ]; then
            set_capture_default_until_now_plus "$S2T_CAPTURE_DEFAULT_COOLDOWN_SEC"
        fi
        exit 0
    fi
    reset_capture_fail_count

    # Provider 1: Whisper Large-v3-Turbo on GCP Cloud Run (optional)
    if [ "$S2T_ASR_PROVIDER" = "gcp-l4" ]; then
        log "asr: gcp-l4 request -> ${S2T_GCP_WHISPER_URL:-<unset>}${S2T_GCP_WHISPER_INFER_PATH:-/inference}"
        t_req_start="$(now_ms)"
        GCP_L4_TEXT="$(transcribe_with_gcp_l4 "${audio_sec:-}" || true)"
        t_req_end="$(now_ms)"
        if [ "$S2T_DEBUG_TIMING" = "1" ]; then
            log "timing: gcp_l4_ms=$((t_req_end - t_req_start)) audio_sec=${audio_sec:-?}"
        fi

        GCP_L4_TEXT_CLEAN="$(printf '%s\n' "$GCP_L4_TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ -n "${GCP_L4_TEXT_CLEAN//[[:space:]]/}" ]; then
            TEXT="$(printf '%s\n' "$GCP_L4_TEXT_CLEAN" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
            record_training_sample "$transcribe_id" "$AUDIO_FILE" "$TEXT"
            printf '%s\n' "$TEXT" >"$RUNTIME_DIR/last_transcript.txt" 2>/dev/null || true
            log "asr: gcp-l4 ok len=${#TEXT}"
            type_text "$TEXT" "$transcribe_id"
            exit 0
        fi
        if [ "$S2T_NETWORK_ONLY" = "1" ]; then
            log "asr: gcp-l4 empty/fail; network-only enabled, skipping local fallback"
            exit 0
        fi
        log "asr: gcp-l4 empty/fail; falling back to local"
    fi

    # Provider 1: OpenAI (optional)
    if [ "$S2T_ASR_PROVIDER" = "openai" ]; then
        log "asr: openai request -> $S2T_OPENAI_MODEL"
        t_req_start="$(now_ms)"
        OPENAI_TEXT="$(transcribe_with_openai || true)"
        t_req_end="$(now_ms)"
        if [ "$S2T_DEBUG_TIMING" = "1" ]; then
            log "timing: openai_ms=$((t_req_end - t_req_start)) audio_sec=${audio_sec:-?}"
        fi

        OPENAI_TEXT_CLEAN="$(printf '%s\n' "$OPENAI_TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ -n "${OPENAI_TEXT_CLEAN//[[:space:]]/}" ]; then
            TEXT="$(printf '%s\n' "$OPENAI_TEXT_CLEAN" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
            record_training_sample "$transcribe_id" "$AUDIO_FILE" "$TEXT"
            printf '%s\n' "$TEXT" >"$RUNTIME_DIR/last_transcript.txt" 2>/dev/null || true
            log "asr: openai ok len=${#TEXT}"
            type_text "$TEXT" "$transcribe_id"
            exit 0
        fi
        if [ "$S2T_NETWORK_ONLY" = "1" ]; then
            log "asr: openai empty/fail; network-only enabled, skipping local fallback"
            exit 0
        fi
        log "asr: openai empty/fail; falling back to local"
    fi

    # Provider 1b: Google (optional)
    if [ "$S2T_ASR_PROVIDER" = "google" ]; then
        local google_rc=0
        local google_timed_out=0
        local google_v2_retry_attempted=0
        local google_noalt_retry_attempted=0
        local google_short_result_detected=0
        local google_timeout_for_call google_guard_for_call
        google_request_model="$S2T_GOOGLE_MODEL"
        google_retry_model=""
        if [ -n "${audio_sec:-}" ] && duration_gt "$S2T_GOOGLE_SHORT_AUDIO_SEC" 0 \
            && ! duration_gt "$audio_sec" "$S2T_GOOGLE_SHORT_AUDIO_SEC"; then
            google_request_model="$S2T_GOOGLE_SHORT_MODEL"
            if [ "$google_request_model" != "$S2T_GOOGLE_MODEL" ]; then
                google_retry_model="$S2T_GOOGLE_MODEL"
            fi
        fi
        google_timeout_for_call="$(compute_google_effective_timeout_sec "${audio_sec:-}")"
        google_guard_for_call="$(compute_google_effective_guard_sec "$google_timeout_for_call")"
        if [ "$S2T_DEBUG_TIMING" = "1" ]; then
            log "timing: google_timeout_sec=$google_timeout_for_call guard_sec=${google_guard_for_call:-0} audio_sec=${audio_sec:-?}"
        fi
        log "asr: google request -> $google_request_model"
        t_req_start="$(now_ms)"
        if GOOGLE_TEXT="$(S2T_GOOGLE_MODEL="$google_request_model" \
            S2T_GOOGLE_REQUEST_TIMEOUT_SEC="$google_timeout_for_call" \
            S2T_GOOGLE_REQUEST_GUARD_SEC="$google_guard_for_call" \
            transcribe_with_google)"; then
            google_rc=0
        else
            google_rc=$?
        fi
        t_req_end="$(now_ms)"
        if [ "$S2T_DEBUG_TIMING" = "1" ]; then
            log "timing: google_ms=$((t_req_end - t_req_start)) audio_sec=${audio_sec:-?} rc=$google_rc"
        fi
        if [ "$google_rc" -eq 124 ]; then
            google_timed_out=1
        fi

        GOOGLE_TEXT_CLEAN="$(printf '%s\n' "$GOOGLE_TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ "$google_rc" -eq 0 ] \
            && [ "$S2T_GOOGLE_RETRY_ON_EMPTY" = "1" ] \
            && [ -z "${GOOGLE_TEXT_CLEAN//[[:space:]]/}" ] \
            && [ -n "${google_retry_model:-}" ]; then
            log "asr: google empty with $google_request_model; retry -> $google_retry_model"
            t_req_start="$(now_ms)"
            if GOOGLE_TEXT="$(S2T_GOOGLE_MODEL="$google_retry_model" \
                S2T_GOOGLE_REQUEST_TIMEOUT_SEC="$google_timeout_for_call" \
                S2T_GOOGLE_REQUEST_GUARD_SEC="$google_guard_for_call" \
                transcribe_with_google)"; then
                google_rc=0
            else
                google_rc=$?
            fi
            t_req_end="$(now_ms)"
            if [ "$S2T_DEBUG_TIMING" = "1" ]; then
                log "timing: google_retry_ms=$((t_req_end - t_req_start)) audio_sec=${audio_sec:-?} rc=$google_rc"
            fi
            GOOGLE_TEXT_CLEAN="$(printf '%s\n' "$GOOGLE_TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        fi
        local google_need_noalt_retry=0
        local google_noalt_reason="empty"
        if [ "$google_rc" -eq 0 ] \
            && [ "$google_timed_out" != "1" ] \
            && [ "$S2T_GOOGLE_RETRY_ON_EMPTY" = "1" ] \
            && [ -n "${S2T_GOOGLE_ALT_LANGUAGE_CODES//[[:space:]]/}" ]; then
            if [ -z "${GOOGLE_TEXT_CLEAN//[[:space:]]/}" ]; then
                google_need_noalt_retry=1
                google_noalt_reason="empty"
            elif google_result_too_short_for_audio "$GOOGLE_TEXT_CLEAN" "${audio_sec:-}"; then
                google_need_noalt_retry=1
                google_noalt_reason="short"
                google_short_result_detected=1
            fi
        fi
        if [ "$google_need_noalt_retry" = "1" ]; then
            google_noalt_retry_attempted=1
            if [ "$google_noalt_reason" = "short" ]; then
                log "asr: google transcript too short for audio; retry same model without alt languages"
            else
                log "asr: google empty with $google_request_model; retry same model without alt languages"
            fi
            t_req_start="$(now_ms)"
            if GOOGLE_TEXT="$(S2T_GOOGLE_MODEL="$google_request_model" \
                S2T_GOOGLE_ALT_LANGUAGE_CODES="" \
                S2T_GOOGLE_REQUEST_TIMEOUT_SEC="$google_timeout_for_call" \
                S2T_GOOGLE_REQUEST_GUARD_SEC="$google_guard_for_call" \
                transcribe_with_google)"; then
                google_rc=0
            else
                google_rc=$?
            fi
            t_req_end="$(now_ms)"
            if [ "$S2T_DEBUG_TIMING" = "1" ]; then
                log "timing: google_retry_noalt_ms=$((t_req_end - t_req_start)) audio_sec=${audio_sec:-?} rc=$google_rc"
            fi
            GOOGLE_TEXT_CLEAN="$(printf '%s\n' "$GOOGLE_TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        fi
        if [ "$google_rc" -eq 0 ] && [ -n "${GOOGLE_TEXT_CLEAN//[[:space:]]/}" ] \
            && google_result_too_short_for_audio "$GOOGLE_TEXT_CLEAN" "${audio_sec:-}"; then
            google_short_result_detected=1
            log "asr: google transcript too short for audio; continuing fallback chain"
            logv "asr: google short-result details len_nonspace=$(text_non_space_len "$GOOGLE_TEXT_CLEAN") audio_sec=${audio_sec:-?} min_chars_per_sec=$S2T_GOOGLE_MIN_CHARS_PER_AUDIO_SEC"
            GOOGLE_TEXT_CLEAN=""
        fi
        if [ -n "${GOOGLE_TEXT_CLEAN//[[:space:]]/}" ]; then
            TEXT="$(printf '%s\n' "$GOOGLE_TEXT_CLEAN" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
            record_training_sample "$transcribe_id" "$AUDIO_FILE" "$TEXT"
            printf '%s\n' "$TEXT" >"$RUNTIME_DIR/last_transcript.txt" 2>/dev/null || true
            log "asr: google ok len=${#TEXT}"
            type_text "$TEXT" "$transcribe_id"
            exit 0
        fi

        if [ "$google_timed_out" != "1" ] && google_v2_ready_for_retry; then
            google_v2_retry_attempted=1
            log "asr: google empty/fail; retry -> google-v2 ($S2T_GOOGLE_V2_MODEL)"
            t_req_start="$(now_ms)"
            GOOGLE_V2_TEXT="$(transcribe_with_google_v2 || true)"
            t_req_end="$(now_ms)"
            if [ "$S2T_DEBUG_TIMING" = "1" ]; then
                log "timing: google_v2_from_v1_ms=$((t_req_end - t_req_start)) audio_sec=${audio_sec:-?}"
            fi
            GOOGLE_V2_TEXT_CLEAN="$(printf '%s\n' "$GOOGLE_V2_TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [ -n "${GOOGLE_V2_TEXT_CLEAN//[[:space:]]/}" ]; then
                TEXT="$(printf '%s\n' "$GOOGLE_V2_TEXT_CLEAN" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
                record_training_sample "$transcribe_id" "$AUDIO_FILE" "$TEXT"
                printf '%s\n' "$TEXT" >"$RUNTIME_DIR/last_transcript.txt" 2>/dev/null || true
                log "asr: google-v2 ok len=${#TEXT}"
                type_text "$TEXT" "$transcribe_id"
                exit 0
            fi
        fi

        logv "asr: google empty rc=$google_rc model=$google_request_model retry_model=${google_retry_model:-none}"
        if [ "$google_noalt_retry_attempted" = "1" ]; then
            logv "asr: google no-alt retry returned empty"
        fi
        if [ "$google_short_result_detected" = "1" ]; then
            logv "asr: google short transcript was rejected for audio_sec=${audio_sec:-?}"
        fi
        if [ "$google_v2_retry_attempted" = "1" ]; then
            logv "asr: google-v2 retry on v1-empty returned empty"
        fi
        if [ "$S2T_NETWORK_ONLY" = "1" ]; then
            log "asr: google empty/fail; network-only enabled, skipping local fallback"
            exit 0
        fi
        if [ "$google_timed_out" = "1" ] && [ "$S2T_SKIP_LOCAL_FALLBACK_ON_TIMEOUT" = "1" ]; then
            log "asr: google timeout; skipping local fallback to keep UI responsive"
            exit 0
        fi
        log "asr: google empty/fail; falling back to local"
    fi

    # Provider 1c: Google v2 (Chirp) (optional)
    if [ "$S2T_ASR_PROVIDER" = "google-v2" ]; then
        local google_fallback_timeout google_fallback_guard
        log "asr: google-v2 request -> $S2T_GOOGLE_V2_MODEL"
        t_req_start="$(now_ms)"
        GOOGLE_V2_TEXT="$(transcribe_with_google_v2 || true)"
        t_req_end="$(now_ms)"
        if [ "$S2T_DEBUG_TIMING" = "1" ]; then
            log "timing: google_v2_ms=$((t_req_end - t_req_start)) audio_sec=${audio_sec:-?}"
        fi

        GOOGLE_V2_TEXT_CLEAN="$(printf '%s\n' "$GOOGLE_V2_TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ -z "${GOOGLE_V2_TEXT_CLEAN//[[:space:]]/}" ] && [ -n "${S2T_GOOGLE_V2_FALLBACK_LANGUAGE_CODES//[[:space:]]/}" ]; then
            log "asr: google-v2 empty; retry with fallback languages -> ${S2T_GOOGLE_V2_FALLBACK_LANGUAGE_CODES}"
            t_req_start="$(now_ms)"
            GOOGLE_V2_TEXT="$(S2T_GOOGLE_V2_LANGUAGE_CODES="$S2T_GOOGLE_V2_FALLBACK_LANGUAGE_CODES" transcribe_with_google_v2 || true)"
            t_req_end="$(now_ms)"
            if [ "$S2T_DEBUG_TIMING" = "1" ]; then
                log "timing: google_v2_fallback_ms=$((t_req_end - t_req_start)) audio_sec=${audio_sec:-?}"
            fi
            GOOGLE_V2_TEXT_CLEAN="$(printf '%s\n' "$GOOGLE_V2_TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        fi
        if [ -n "${GOOGLE_V2_TEXT_CLEAN//[[:space:]]/}" ]; then
            TEXT="$(printf '%s\n' "$GOOGLE_V2_TEXT_CLEAN" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
            record_training_sample "$transcribe_id" "$AUDIO_FILE" "$TEXT"
            printf '%s\n' "$TEXT" >"$RUNTIME_DIR/last_transcript.txt" 2>/dev/null || true
            log "asr: google-v2 ok len=${#TEXT}"
                type_text "$TEXT" "$transcribe_id"
            exit 0
        fi

        # If v2 fails, fall back to v1 (API key) before local.
        log "asr: google-v2 empty/fail; falling back to google(v1)"
        google_fallback_timeout="$(compute_google_effective_timeout_sec "${audio_sec:-}")"
        google_fallback_guard="$(compute_google_effective_guard_sec "$google_fallback_timeout")"
        log "asr: google request -> $S2T_GOOGLE_MODEL"
        t_req_start="$(now_ms)"
        GOOGLE_TEXT="$(S2T_GOOGLE_REQUEST_TIMEOUT_SEC="$google_fallback_timeout" \
            S2T_GOOGLE_REQUEST_GUARD_SEC="$google_fallback_guard" \
            transcribe_with_google || true)"
        t_req_end="$(now_ms)"
        if [ "$S2T_DEBUG_TIMING" = "1" ]; then
            log "timing: google_ms=$((t_req_end - t_req_start)) audio_sec=${audio_sec:-?}"
        fi

        GOOGLE_TEXT_CLEAN="$(printf '%s\n' "$GOOGLE_TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ -n "${GOOGLE_TEXT_CLEAN//[[:space:]]/}" ]; then
            TEXT="$(printf '%s\n' "$GOOGLE_TEXT_CLEAN" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
            record_training_sample "$transcribe_id" "$AUDIO_FILE" "$TEXT"
            printf '%s\n' "$TEXT" >"$RUNTIME_DIR/last_transcript.txt" 2>/dev/null || true
            log "asr: google ok len=${#TEXT}"
            type_text "$TEXT" "$transcribe_id"
            exit 0
        fi

        if [ "$S2T_NETWORK_ONLY" = "1" ]; then
            log "asr: google empty/fail; network-only enabled, skipping local fallback"
            exit 0
        fi
        log "asr: google empty/fail; falling back to local"
    fi

    if [ "$S2T_NETWORK_ONLY" = "1" ]; then
        log "asr: network-only enabled; local provider disabled"
        exit 0
    fi

    # Provider 2: local whisper-server
    if [ "$S2T_USE_SERVER" = "1" ]; then
        log "asr: server request -> $S2T_WHISPER_SERVER_URL"
        t_req_start="$(now_ms)"
        SERVER_TEXT="$(transcribe_with_server "${audio_sec:-}" || true)"
        t_req_end="$(now_ms)"
        if [ "$S2T_DEBUG_TIMING" = "1" ]; then
            log "timing: server_ms=$((t_req_end - t_req_start)) audio_sec=${audio_sec:-?}"
        fi
        SERVER_TEXT_CLEAN="$(printf '%s\n' "$SERVER_TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ "$SERVER_TEXT_CLEAN" = "[BLANK_AUDIO]" ]; then
            SERVER_TEXT_CLEAN=""
        fi
        if [ -n "${SERVER_TEXT_CLEAN//[[:space:]]/}" ]; then
            TEXT="$(printf '%s\n' "$SERVER_TEXT_CLEAN" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
            record_training_sample "$transcribe_id" "$AUDIO_FILE" "$TEXT"
            printf '%s\n' "$TEXT" >"$RUNTIME_DIR/last_transcript.txt" 2>/dev/null || true
            log "asr: server ok len=${#TEXT}"
            type_text "$TEXT" "$transcribe_id"
            exit 0
        fi
        if [ "$S2T_ASR_PROVIDER" = "local" ] && [ "${S2T_LOCAL_DISABLE_CLI_FALLBACK:-1}" = "1" ]; then
            log "asr: server empty/fail; local strict mode enabled, skipping whisper-cli fallback"
            exit 0
        fi
        log "asr: server empty/fail; falling back to whisper-cli"
    fi

    require_cmd whisper-cli
    ensure_model

    # Whisper
    # Use file output to avoid relying on stdout formatting/flags.
    THREADS_DEFAULT="$(nproc 2>/dev/null || echo 4)"
    if ! [[ "$THREADS_DEFAULT" =~ ^[0-9]+$ ]] || [ "$THREADS_DEFAULT" -lt 1 ]; then
        THREADS_DEFAULT=4
    elif [ "$THREADS_DEFAULT" -gt 4 ]; then
        THREADS_DEFAULT=4
    fi
    THREADS="${S2T_THREADS:-$THREADS_DEFAULT}"
    NO_SPEECH_THOLD="${S2T_NO_SPEECH_THOLD:-0.6}"
    LANG="${S2T_LANG:-auto}"
    BEAM_SIZE="${S2T_BEAM_SIZE:-1}"
    BEST_OF="${S2T_BEST_OF:-1}"
    WHISPER_LOG="$RUNTIME_DIR/whisper_${transcribe_id}.log"
    WHISPER_OUT_PREFIX="$RUNTIME_DIR/whisper_out_${transcribe_id}"
    WHISPER_OUT_TXT="${WHISPER_OUT_PREFIX}.txt"

    rm -f "$WHISPER_OUT_TXT" "$WHISPER_LOG"

    EXTRA_ARGS=()
    if [ -n "${S2T_WHISPER_ARGS:-}" ]; then
        # shellcheck disable=SC2206
        EXTRA_ARGS=(${S2T_WHISPER_ARGS})
    fi

    t_cli_start="$(now_ms)"
    set +e
    log "asr: whisper-cli start (model=$(basename "$MODEL_PATH"))"
    whisper-cli -m "$MODEL_PATH" -f "$AUDIO_FILE" -nt -otxt -of "$WHISPER_OUT_PREFIX" \
      -t "$THREADS" \
      -bs "$BEAM_SIZE" \
      -bo "$BEST_OF" \
      -nth "$NO_SPEECH_THOLD" \
      -l "$LANG" \
      "${EXTRA_ARGS[@]}" \
      >/dev/null 2>"$WHISPER_LOG"
    WHISPER_RC=$?
    set -e
    t_cli_end="$(now_ms)"
    if [ "$S2T_DEBUG_TIMING" = "1" ]; then
        log "timing: whisper_cli_ms=$((t_cli_end - t_cli_start)) audio_sec=${audio_sec:-?}"
    fi
    log "asr: whisper-cli rc=$WHISPER_RC"

    RAW_OUT=""
    if [ -s "$WHISPER_OUT_TXT" ]; then
        RAW_OUT="$(cat "$WHISPER_OUT_TXT")"
    fi

    if [ "$WHISPER_RC" -ne 0 ]; then
        cap_file_size "$WHISPER_LOG" "$S2T_WHISPER_LOG_MAX_BYTES"
        log "asr: failed rc=$WHISPER_RC (see $WHISPER_LOG)"
        exit 0
    fi

    if [ -z "${RAW_OUT//[[:space:]]/}" ]; then
        rm -f "$WHISPER_LOG"
        log "asr: empty output (no speech?)"
        exit 0
    fi

    TEXT="$(
        printf '%s\n' "$RAW_OUT" \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | sed '/^$/d' \
        | tr '\n' ' ' \
        | sed 's/[[:space:]][[:space:]]*/ /g'
    )"
    
    if [ -n "$TEXT" ]; then
        rm -f "$WHISPER_LOG" "$WHISPER_OUT_TXT"
        record_training_sample "$transcribe_id" "$AUDIO_FILE" "$TEXT"
        printf '%s\n' "$TEXT" >"$RUNTIME_DIR/last_transcript.txt" 2>/dev/null || true
        log "asr: got text len=${#TEXT}"
        type_text "$TEXT" "$transcribe_id"
    else
        log "asr: normalized text empty"
    fi
}

type_text() {
    local text="$1"
    local source_id="${2:-}"
    local insert_rc=0
    save_secondary_buffer_text "$text" "$source_id" || logv "secondary: failed to store transcript in buffer"

    if [ "$S2T_INSERT_METHOD" = "none" ]; then
        log "insert: disabled"
        return 0
    fi

    if [ "$S2T_INSERT_METHOD" = "paste" ]; then
        t_insert_start="$(now_ms)"
        if insert_from_secondary_buffer "$text" auto; then
            if [ "$S2T_DEBUG_TIMING" = "1" ]; then
                t_insert_end="$(now_ms)"
                log "timing: insert_ms=$((t_insert_end - t_insert_start))"
            fi
            log "insert: pasted-from-secondary"
            return 0
        else
            insert_rc=$?
        fi
        if [ "$insert_rc" -eq 2 ]; then
            log "insert: skipped auto insert on X11; transcript kept in secondary buffer"
            notify -t 900 "S2T saved transcript to secondary buffer"
            return 0
        fi
        log "insert: paste failed (no injector)"
        return 1
    fi

    if [ "$S2T_INSERT_METHOD" = "type" ]; then
        inject_text_without_clipboard "$text"
    fi
}

block_input_feedback() {
    # Optional: play system sound
    true
}

logv "controller: pid=$$ action=${1:-?} runtime_dir=$RUNTIME_DIR provider=$S2T_ASR_PROVIDER network_only=$S2T_NETWORK_ONLY max_response=${S2T_MAX_RESPONSE_SECONDS} configured_google_model=$S2T_GOOGLE_MODEL gcp_l4_url=${S2T_GCP_WHISPER_URL:-} local_server_url=$S2T_WHISPER_SERVER_URL"

case "$1" in
    start)
        start_recording
        ;;
    stop)
        stop_and_transcribe
        ;;
    toggle)
        if [ -f "$PID_FILE" ]; then
            stop_and_transcribe
        else
            start_recording
        fi
        ;;
    submit-correction)
        shift || true
        submit_correction "$@"
        ;;
    secondary-clear)
        secondary_clear
        ;;
    secondary-copy)
        secondary_copy_buffer
        ;;
    secondary-paste)
        secondary_paste_to_focused_app
        ;;
    *)
        echo "Usage: $0 {start|stop|toggle|submit-correction [--id <sample_id>] [--text <text>] [text...]|secondary-clear|secondary-copy|secondary-paste}"
        exit 1
        ;;
esac
