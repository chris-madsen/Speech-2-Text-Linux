#!/usr/bin/env bash
set -euo pipefail

MODEL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/s2t"
MODEL_LARGE="${MODEL_DIR}/ggml-large-v3-turbo.bin"
MODEL_MEDIUM="${MODEL_DIR}/ggml-medium.bin"
MODEL_SMALL="${MODEL_DIR}/ggml-small.bin"
MODEL_TINY="${MODEL_DIR}/ggml-tiny.bin"

MODEL_PATH="${S2T_MODEL_PATH:-}"
MODEL_URL="${S2T_MODEL_URL:-}"
MODEL_PRESET="${S2T_MODEL_PRESET:-balanced}" # fast|balanced|medium|accurate

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
  echo "S2T: model path '$requested' is not writable/readable; falling back to '$fallback_path'" >&2
  MODEL_PATH="$fallback_path"
  if [ -z "${MODEL_URL}" ]; then
    MODEL_URL="$(model_url_for "$requested_base")"
  fi
}

model_url_for() {
  case "$1" in
    ggml-large-v3-turbo.bin) printf '%s' "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" ;;
    ggml-medium.bin)         printf '%s' "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin" ;;
    ggml-small.bin)          printf '%s' "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin" ;;
    ggml-tiny.bin)           printf '%s' "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin" ;;
    *)                       printf '%s' "" ;;
  esac
}

if [ -z "${MODEL_PATH}" ]; then
  CANDIDATES=()
  case "$MODEL_PRESET" in
    accurate) CANDIDATES=( "$MODEL_LARGE" "$MODEL_MEDIUM" "$MODEL_SMALL" "$MODEL_TINY" ) ;;
    medium)   CANDIDATES=( "$MODEL_MEDIUM" "$MODEL_SMALL" "$MODEL_LARGE" "$MODEL_TINY" ) ;;
    fast)     CANDIDATES=( "$MODEL_TINY" "$MODEL_SMALL" "$MODEL_MEDIUM" "$MODEL_LARGE" ) ;;
    *)        CANDIDATES=( "$MODEL_SMALL" "$MODEL_MEDIUM" "$MODEL_LARGE" "$MODEL_TINY" ) ;;
  esac

  for candidate in "${CANDIDATES[@]}"; do
    if [ -f "$candidate" ]; then
      MODEL_PATH="$candidate"
      break
    fi
  done

  if [ -z "${MODEL_PATH}" ]; then
    MODEL_PATH="${CANDIDATES[0]}"
  fi

  MODEL_URL="${MODEL_URL:-$(model_url_for "$(basename "$MODEL_PATH")")}"
fi

resolve_model_path_for_current_user "$MODEL_PATH"

mkdir -p "$MODEL_DIR"
if [ ! -f "$MODEL_PATH" ]; then
  if [ -z "${MODEL_URL}" ]; then
    echo "S2T: model missing and S2T_MODEL_URL not set: $MODEL_PATH" >&2
    exit 1
  fi
  echo "S2T: downloading model to $MODEL_PATH" >&2
  curl -L --fail "$MODEL_URL" -o "$MODEL_PATH"
fi
echo "S2T: using model $MODEL_PATH" >&2

PORT="${S2T_WHISPER_SERVER_PORT:-9787}"
LANG="${S2T_LANG:-auto}"
THREADS_DEFAULT="$(nproc 2>/dev/null || echo 4)"
if ! [[ "$THREADS_DEFAULT" =~ ^[0-9]+$ ]] || [ "$THREADS_DEFAULT" -lt 1 ]; then
  THREADS_DEFAULT=4
elif [ "$THREADS_DEFAULT" -gt 4 ]; then
  THREADS_DEFAULT=4
fi
THREADS="${S2T_THREADS:-$THREADS_DEFAULT}"
BEAM_SIZE="${S2T_BEAM_SIZE:-1}"
BEST_OF="${S2T_BEST_OF:-1}"
NO_SPEECH_THOLD="${S2T_NO_SPEECH_THOLD:-0.6}"

exec /etc/s2t/result/bin/whisper-server \
  --host 127.0.0.1 \
  --port "$PORT" \
  -m "$MODEL_PATH" \
  -l "$LANG" \
  -t "$THREADS" \
  -bs "$BEAM_SIZE" \
  -bo "$BEST_OF" \
  -nth "$NO_SPEECH_THOLD" \
  -nt
