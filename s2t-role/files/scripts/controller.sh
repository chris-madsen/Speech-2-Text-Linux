#!/usr/bin/env bash
# S2T Controller
# Handles state, notification, calls record/transcribe scripts.

set -euo pipefail

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

    for base in "${XDG_RUNTIME_DIR:-}" "/run/user/$uid" "/dev/shm"; do
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
S2T_WHISPER_SERVER_PORT="${S2T_WHISPER_SERVER_PORT:-9787}"
S2T_WHISPER_SERVER_URL="${S2T_WHISPER_SERVER_URL:-http://127.0.0.1:${S2T_WHISPER_SERVER_PORT}/inference}"
S2T_DEBUG_TIMING="${S2T_DEBUG_TIMING:-0}"
S2T_PRESERVE_CLIPBOARD="${S2T_PRESERVE_CLIPBOARD:-0}" # 1: save+restore clipboard around paste
S2T_CLIPBOARD_RESTORE_DELAY_MS="${S2T_CLIPBOARD_RESTORE_DELAY_MS:-120}"
S2T_KEEP_AUDIO="${S2T_KEEP_AUDIO:-0}" # 1: keep last wav on disk (tmpfs); 0: delete after transcription
S2T_LOG_MAX_BYTES="${S2T_LOG_MAX_BYTES:-1048576}" # 1 MiB per active log file
S2T_LOG_KEEP="${S2T_LOG_KEEP:-3}" # rotated s2t.log.N files to keep
S2T_WHISPER_ARTIFACT_KEEP="${S2T_WHISPER_ARTIFACT_KEEP:-6}" # keep newest whisper_{id}.log/out files
S2T_WHISPER_LOG_MAX_BYTES="${S2T_WHISPER_LOG_MAX_BYTES:-524288}" # cap failed whisper logs to 512 KiB

# ASR provider selection:
# - local: use whisper-server (recommended) and fall back to whisper-cli
# - openai: use OpenAI Audio Transcriptions API and fall back to local
S2T_ASR_PROVIDER="${S2T_ASR_PROVIDER:-local}" # local|google|google-v2|openai
S2T_NETWORK_ONLY="${S2T_NETWORK_ONLY:-0}" # 1: never fall back to local ASR
S2T_MAX_RESPONSE_SECONDS="${S2T_MAX_RESPONSE_SECONDS:-5}" # hard cap target for network ASR
S2T_OPENAI_BASE_URL="${S2T_OPENAI_BASE_URL:-https://api.openai.com/v1}"
S2T_OPENAI_MODEL="${S2T_OPENAI_MODEL:-gpt-4o-mini-transcribe}"
S2T_OPENAI_TIMEOUT_SEC="${S2T_OPENAI_TIMEOUT_SEC:-20}"

# Google Cloud Speech-to-Text (v1 REST).
# Best for short utterances: latest_short
S2T_GOOGLE_API_ENDPOINT="${S2T_GOOGLE_API_ENDPOINT:-https://speech.googleapis.com/v1/speech:recognize}"
S2T_GOOGLE_MODEL="${S2T_GOOGLE_MODEL:-latest_short}"
S2T_GOOGLE_LANGUAGE_CODE="${S2T_GOOGLE_LANGUAGE_CODE:-ru-RU}"
S2T_GOOGLE_ALT_LANGUAGE_CODES="${S2T_GOOGLE_ALT_LANGUAGE_CODES:-en-US}"
S2T_GOOGLE_ENABLE_PUNCTUATION="${S2T_GOOGLE_ENABLE_PUNCTUATION:-1}"
S2T_GOOGLE_TIMEOUT_SEC="${S2T_GOOGLE_TIMEOUT_SEC:-20}"

# Google Cloud Speech-to-Text (v2 REST) for Chirp models (requires OAuth/ADC; API keys won't work).
S2T_GCP_PROJECT="${S2T_GCP_PROJECT:-}"
S2T_GOOGLE_V2_LOCATION="${S2T_GOOGLE_V2_LOCATION:-global}"
S2T_GOOGLE_V2_RECOGNIZER="${S2T_GOOGLE_V2_RECOGNIZER:-_}" # "_" (implicit, global-only) or custom id
S2T_GOOGLE_V2_MODEL="${S2T_GOOGLE_V2_MODEL:-chirp_2}"
S2T_GOOGLE_V2_LANGUAGE_CODES="${S2T_GOOGLE_V2_LANGUAGE_CODES:-ru-RU}"
S2T_GOOGLE_V2_FALLBACK_LANGUAGE_CODES="${S2T_GOOGLE_V2_FALLBACK_LANGUAGE_CODES:-}" # e.g. en-US
S2T_GOOGLE_V2_ENABLE_PUNCTUATION="${S2T_GOOGLE_V2_ENABLE_PUNCTUATION:-1}"
S2T_GOOGLE_V2_TIMEOUT_SEC="${S2T_GOOGLE_V2_TIMEOUT_SEC:-20}"
S2T_GOOGLE_APPLICATION_CREDENTIALS="${S2T_GOOGLE_APPLICATION_CREDENTIALS:-${GOOGLE_APPLICATION_CREDENTIALS:-}}"

is_positive_int() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

if is_positive_int "$S2T_MAX_RESPONSE_SECONDS" && [ "$S2T_MAX_RESPONSE_SECONDS" -gt 0 ]; then
    if is_positive_int "$S2T_OPENAI_TIMEOUT_SEC" && [ "$S2T_OPENAI_TIMEOUT_SEC" -gt "$S2T_MAX_RESPONSE_SECONDS" ]; then
        S2T_OPENAI_TIMEOUT_SEC="$S2T_MAX_RESPONSE_SECONDS"
    fi
    if is_positive_int "$S2T_GOOGLE_TIMEOUT_SEC" && [ "$S2T_GOOGLE_TIMEOUT_SEC" -gt "$S2T_MAX_RESPONSE_SECONDS" ]; then
        S2T_GOOGLE_TIMEOUT_SEC="$S2T_MAX_RESPONSE_SECONDS"
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

log() {
    mkdir -p "$RUNTIME_DIR" >/dev/null 2>&1 || true
    rotate_file_if_needed "$LOG_FILE" "$S2T_LOG_MAX_BYTES" "$S2T_LOG_KEEP"
    printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$*" >>"$LOG_FILE" 2>/dev/null || true
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

select_paste_keys() {
    if [ "$S2T_PASTE_KEYS" != "auto" ]; then
        printf '%s' "$S2T_PASTE_KEYS"
        return 0
    fi

    local cls
    cls="$(focused_wm_class_x11 || true)"
    if [ -n "${cls:-}" ]; then
        if is_terminal_class "$cls"; then
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

detect_audio_target() {
    # Prefer explicit config.
    if [ -n "${S2T_AUDIO_TARGET:-}" ]; then
        printf '%s' "$S2T_AUDIO_TARGET"
        return 0
    fi

    # Best-effort: ask WirePlumber for the default audio source node name.
    if command -v wpctl >/dev/null 2>&1; then
        local node_name
        node_name="$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | sed -n 's/^  \\* node\\.name = \"\\(.*\\)\"$/\\1/p' | head -n1)"
        if [ -n "${node_name:-}" ]; then
            printf '%s' "$node_name"
            return 0
        fi
    fi

    return 1
}

start_recording() {
    if [ -f "$PID_FILE" ]; then
        # Already recording
        exit 0
    fi
    
    mkdir -p "$RUNTIME_DIR"
    require_cmd pw-record

    rm -f "$AUDIO_FILE"

    # Use pipewire record
    # Format s16le 16kHz mono
    TARGET_ARGS=()
    if target="$(detect_audio_target)"; then
        TARGET_ARGS+=(--target "$target")
        log "start: pw-record target=$target"
    else
        log "start: pw-record target=default"
    fi

    RECORD_CMD=(pw-record --format=s16 --rate=16000 --channels=1 "${TARGET_ARGS[@]}" "$AUDIO_FILE")
    if is_positive_int "$S2T_MAX_RECORD_SECONDS" && [ "$S2T_MAX_RECORD_SECONDS" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        log "start: spawning pw-record (max ${S2T_MAX_RECORD_SECONDS}s)"
        timeout --signal=TERM "${S2T_MAX_RECORD_SECONDS}s" "${RECORD_CMD[@]}" &
    else
        log "start: spawning pw-record"
        "${RECORD_CMD[@]}" &
    fi
    PID=$!
    echo "$PID" > "$PID_FILE"
    
    # Visual feedback
    block_input_feedback
    notify -t 800 -h string:x-canonical-private-synchronous:s2t "Listening..."
}

set_clipboard() {
    local text="$1"
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        if command -v wl-copy >/dev/null 2>&1; then
            printf '%s' "$text" | wl-copy
            return 0
        fi
    else
        if command -v xclip >/dev/null 2>&1; then
            printf '%s' "$text" | xclip -selection clipboard
            return 0
        fi
    fi

    # fallback
    if command -v wl-copy >/dev/null 2>&1; then
        printf '%s' "$text" | wl-copy
        return 0
    fi
    if command -v xclip >/dev/null 2>&1; then
        printf '%s' "$text" | xclip -selection clipboard
        return 0
    fi
    return 1
}

clipboard_read_to_file() {
    local out_file="$1"
    mkdir -p "$(dirname "$out_file")" >/dev/null 2>&1 || true

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && command -v wl-paste >/dev/null 2>&1; then
        if wl-paste >"$out_file" 2>/dev/null; then
            return 0
        fi
    fi
    if [ "${XDG_SESSION_TYPE:-}" != "wayland" ] && command -v xclip >/dev/null 2>&1; then
        if xclip -selection clipboard -o >"$out_file" 2>/dev/null; then
            return 0
        fi
    fi

    # fallback: try any tool we have
    if command -v wl-paste >/dev/null 2>&1; then
        wl-paste >"$out_file" 2>/dev/null && return 0
    fi
    if command -v xclip >/dev/null 2>&1; then
        xclip -selection clipboard -o >"$out_file" 2>/dev/null && return 0
    fi
    return 1
}

clipboard_write_from_file() {
    local in_file="$1"
    if [ ! -f "$in_file" ]; then
        return 1
    fi

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && command -v wl-copy >/dev/null 2>&1; then
        wl-copy <"$in_file" 2>/dev/null && return 0
    fi
    if [ "${XDG_SESSION_TYPE:-}" != "wayland" ] && command -v xclip >/dev/null 2>&1; then
        xclip -selection clipboard -i <"$in_file" 2>/dev/null && return 0
    fi

    # fallback
    if command -v wl-copy >/dev/null 2>&1; then
        wl-copy <"$in_file" 2>/dev/null && return 0
    fi
    if command -v xclip >/dev/null 2>&1; then
        xclip -selection clipboard -i <"$in_file" 2>/dev/null && return 0
    fi
    return 1
}

paste_clipboard() {
    # Prefer compositor-native tools when available; otherwise fall back.
    local keys cls
    keys="$(select_paste_keys)"
    if [ "$S2T_DEBUG_TIMING" = "1" ] && [ "$S2T_PASTE_KEYS" = "auto" ]; then
        cls="$(focused_wm_class_x11 || true)"
        log "insert: auto keys=${keys} wm_class=${cls:-unknown}"
    fi

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
            # Linux input keycodes: 29=LEFTCTRL, 42=LEFTSHIFT, 47=V, 110=INSERT
            case "$keys" in
                shift+insert) ydotool key 42:1 110:1 110:0 42:0 ;;
                ctrl+shift+v) ydotool key 29:1 42:1 47:1 47:0 42:0 29:0 ;;
                *)            ydotool key 29:1 47:1 47:0 29:0 ;;
            esac
            return 0
        fi
        return 1
    fi

    # X11
    if command -v xdotool >/dev/null 2>&1; then
        case "$keys" in
            shift+insert) xdotool key --clearmodifiers shift+Insert ;;
            ctrl+shift+v) xdotool key --clearmodifiers ctrl+shift+v ;;
            *)            xdotool key --clearmodifiers ctrl+v ;;
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
}

transcribe_with_server() {
    require_cmd curl
    require_cmd jq

    local response
    response="$(curl -sf \
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
    local response
    response="$(curl -sf --max-time "$S2T_OPENAI_TIMEOUT_SEC" \
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

transcribe_with_google() {
    require_cmd curl
    require_cmd jq
    require_cmd base64
    require_cmd python3

    if [ -z "${S2T_GOOGLE_API_KEY:-}" ]; then
        log "asr: google missing S2T_GOOGLE_API_KEY"
        return 1
    fi

    local url="${S2T_GOOGLE_API_ENDPOINT}?key=${S2T_GOOGLE_API_KEY}"
    local response
    # Build request in-memory via pipes (no temporary files). This avoids ARG_MAX/E2BIG.
    response="$(
        base64 -w 0 "$AUDIO_FILE" 2>>"$LOG_FILE" \
        | python3 -c '
import os, sys, json
content = sys.stdin.read()
lang = os.environ.get("S2T_GOOGLE_LANGUAGE_CODE", "ru-RU")
model = os.environ.get("S2T_GOOGLE_MODEL", "latest_short")
alt = os.environ.get("S2T_GOOGLE_ALT_LANGUAGE_CODES", "").strip()
punct = os.environ.get("S2T_GOOGLE_ENABLE_PUNCTUATION", "1") == "1"
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
  "audio": {"content": content},
}
sys.stdout.write(json.dumps(req, ensure_ascii=False))
' \
        | curl -sS --max-time "$S2T_GOOGLE_TIMEOUT_SEC" \
            -H "Content-Type: application/json" \
            --data-binary @- \
            "$url" \
            2>>"$LOG_FILE" \
        || true
    )"

    if [ -z "${response//[[:space:]]/}" ]; then
        return 1
    fi

    # Log structured errors to make debugging easier.
    local err_msg
    err_msg="$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null || true)"
    if [ -n "${err_msg:-}" ]; then
        log "asr: google error: $err_msg"
        return 1
    fi

    printf '%s' "$response" | jq -r '[.results[]?.alternatives[]? | select(.transcript != null) | .transcript] | join(" ")' 2>/dev/null || true
    return 0
}

transcribe_with_google_v2() {
    require_cmd python3
    if ! python3 -c 'import google.cloud.speech_v2' >/dev/null 2>&1; then
        log "asr: google-v2 missing python deps (google-cloud-speech). Reinstall S2T."
        return 1
    fi

    local project
    project="${S2T_GCP_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}"
    if [ -z "${project//[[:space:]]/}" ]; then
        log "asr: google-v2 missing GCP project (set S2T_GCP_PROJECT)"
        return 1
    fi

    if [ -z "${S2T_GOOGLE_APPLICATION_CREDENTIALS//[[:space:]]/}" ]; then
        log "asr: google-v2 missing credentials (set S2T_GOOGLE_APPLICATION_CREDENTIALS to a service-account JSON path)"
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

try:
    resp = client.recognize(request=req, timeout=float(os.environ.get("S2T_GOOGLE_V2_TIMEOUT_SEC", "20")))
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

    cleanup_audio() {
        if [ "$S2T_KEEP_AUDIO" != "1" ]; then
            rm -f "$AUDIO_FILE" 2>/dev/null || true
        fi
        cleanup_transcribe_artifacts
    }
    trap cleanup_audio EXIT

    PID=$(cat "$PID_FILE")
    # Graceful stop
    t_stop_start="$(now_ms)"
    log "stop: stopping pw-record pid=$PID"
    kill -TERM "$PID" || true

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

    # Keep PID_FILE until this capture is isolated from subsequent recordings.
    if [ -f "$AUDIO_FILE" ]; then
        if mv -f "$AUDIO_FILE" "$session_audio_file" 2>/dev/null; then
            AUDIO_FILE="$session_audio_file"
        elif cp -f "$AUDIO_FILE" "$session_audio_file" 2>/dev/null; then
            AUDIO_FILE="$session_audio_file"
        fi
    fi
    rm -f "$PID_FILE"

    # Release stop lock before long-running network/transcription/clipboard ops.
    # Some clipboard tools (xclip) keep background children alive and would
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
        log "stop: no audio captured (empty wav)"
        exit 0
    fi

    audio_sec=""
    if command -v sox >/dev/null 2>&1; then
        audio_sec="$(sox --i -D "$AUDIO_FILE" 2>/dev/null || true)"
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
            printf '%s\n' "$TEXT" >"$RUNTIME_DIR/last_transcript.txt" 2>/dev/null || true
            log "asr: openai ok len=${#TEXT}"
            type_text "$TEXT"
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
        log "asr: google request -> $S2T_GOOGLE_MODEL"
        t_req_start="$(now_ms)"
        GOOGLE_TEXT="$(transcribe_with_google || true)"
        t_req_end="$(now_ms)"
        if [ "$S2T_DEBUG_TIMING" = "1" ]; then
            log "timing: google_ms=$((t_req_end - t_req_start)) audio_sec=${audio_sec:-?}"
        fi

        GOOGLE_TEXT_CLEAN="$(printf '%s\n' "$GOOGLE_TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ -n "${GOOGLE_TEXT_CLEAN//[[:space:]]/}" ]; then
            TEXT="$(printf '%s\n' "$GOOGLE_TEXT_CLEAN" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
            printf '%s\n' "$TEXT" >"$RUNTIME_DIR/last_transcript.txt" 2>/dev/null || true
            log "asr: google ok len=${#TEXT}"
            type_text "$TEXT"
            exit 0
        fi
        if [ "$S2T_NETWORK_ONLY" = "1" ]; then
            log "asr: google empty/fail; network-only enabled, skipping local fallback"
            exit 0
        fi
        log "asr: google empty/fail; falling back to local"
    fi

    # Provider 1c: Google v2 (Chirp) (optional)
    if [ "$S2T_ASR_PROVIDER" = "google-v2" ]; then
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
            printf '%s\n' "$TEXT" >"$RUNTIME_DIR/last_transcript.txt" 2>/dev/null || true
            log "asr: google-v2 ok len=${#TEXT}"
            type_text "$TEXT"
            exit 0
        fi

        # If v2 fails, fall back to v1 (API key) before local.
        log "asr: google-v2 empty/fail; falling back to google(v1)"
        log "asr: google request -> $S2T_GOOGLE_MODEL"
        t_req_start="$(now_ms)"
        GOOGLE_TEXT="$(transcribe_with_google || true)"
        t_req_end="$(now_ms)"
        if [ "$S2T_DEBUG_TIMING" = "1" ]; then
            log "timing: google_ms=$((t_req_end - t_req_start)) audio_sec=${audio_sec:-?}"
        fi

        GOOGLE_TEXT_CLEAN="$(printf '%s\n' "$GOOGLE_TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ -n "${GOOGLE_TEXT_CLEAN//[[:space:]]/}" ]; then
            TEXT="$(printf '%s\n' "$GOOGLE_TEXT_CLEAN" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
            printf '%s\n' "$TEXT" >"$RUNTIME_DIR/last_transcript.txt" 2>/dev/null || true
            log "asr: google ok len=${#TEXT}"
            type_text "$TEXT"
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
        SERVER_TEXT="$(transcribe_with_server || true)"
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
            printf '%s\n' "$TEXT" >"$RUNTIME_DIR/last_transcript.txt" 2>/dev/null || true
            log "asr: server ok len=${#TEXT}"
            type_text "$TEXT"
            exit 0
        fi
        log "asr: server empty/fail; falling back to whisper-cli"
    fi

    require_cmd whisper-cli
    ensure_model

    # Whisper
    # Use file output to avoid relying on stdout formatting/flags.
    THREADS="${S2T_THREADS:-$(nproc 2>/dev/null || echo 4)}"
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
        printf '%s\n' "$TEXT" >"$RUNTIME_DIR/last_transcript.txt" 2>/dev/null || true
        log "asr: got text len=${#TEXT}"
        type_text "$TEXT"
    else
        log "asr: normalized text empty"
    fi
}

type_text() {
    local text="$1"
    if [ "$S2T_INSERT_METHOD" = "none" ]; then
        log "insert: disabled"
        return 0
    fi

    if [ "$S2T_INSERT_METHOD" = "paste" ]; then
        local preserve_ok=0
        local prev_clip_file="$RUNTIME_DIR/clipboard_prev.txt"
        if [ "$S2T_PRESERVE_CLIPBOARD" = "1" ]; then
            if clipboard_read_to_file "$prev_clip_file"; then
                preserve_ok=1
            else
                log "insert: preserve_clipboard=1 but cannot read current clipboard"
            fi
        fi

        t_insert_start="$(now_ms)"
        if set_clipboard "$text"; then
            if paste_clipboard; then
                if [ "$S2T_DEBUG_TIMING" = "1" ]; then
                    t_insert_end="$(now_ms)"
                    log "timing: insert_ms=$((t_insert_end - t_insert_start))"
                fi
                log "insert: pasted"
                if [ "$preserve_ok" = "1" ]; then
                    sleep_ms "$S2T_CLIPBOARD_RESTORE_DELAY_MS"
                    clipboard_write_from_file "$prev_clip_file" || log "insert: failed to restore previous clipboard"
                fi
                return 0
            fi
            log "insert: paste failed (no injector)"
            if [ "$preserve_ok" = "1" ]; then
                clipboard_write_from_file "$prev_clip_file" || true
            fi
            return 1
        fi
        log "insert: clipboard tool missing"
        return 1
    fi

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        # Wayland typing is hard without root ydotool daemon.
        # But prompts says "ydotool".
        # We assume ydotool works (user has socket access).
        if command -v wtype >/dev/null; then
            wtype "$text"
        else
            ydotool type "$text"
        fi
    else
        xdotool type --clearmodifiers --delay "$S2T_XDOTOOL_DELAY_MS" -- "$text"
    fi
}

block_input_feedback() {
    # Optional: play system sound
    true
}

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
    *)
        echo "Usage: $0 {start|stop|toggle}"
        exit 1
        ;;
esac
