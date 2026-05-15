#!/usr/bin/env python3
"""Bridge Codex user chat messages to s2t-controller submit-correction."""

from __future__ import annotations

import datetime as dt
import difflib
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass

from s2t_common import Logger, env_bool, env_float, env_int, env_path, env_str


@dataclass
class Config:
    sessions_dir: pathlib.Path
    state_file: pathlib.Path
    pending_dir: pathlib.Path
    controller_cmd: list[str]
    poll_sec: float
    window_sec: float
    max_pending_age_sec: float
    max_msg_chars: int
    min_shared_tokens: int
    min_overlap_ratio: float
    submit_timeout_sec: int
    backfill_existing: bool
    run_once: bool
    allow_time_fallback: bool
    log_file: pathlib.Path
    log_verbose: bool
    log_max_bytes: int
    log_keep: int


_LOGGER: Logger | None = None


@dataclass
class PendingSample:
    sample_id: str
    created_ms: int
    raw_text: str


def log(message: str) -> None:
    if _LOGGER is None:
        print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} codex-bridge: {message}", flush=True)
        return
    _LOGGER.log(message)


def logv(message: str) -> None:
    if _LOGGER is None:
        return
    _LOGGER.logv(message)


def ensure_writable_dir(path: pathlib.Path) -> bool:
    try:
        path.mkdir(parents=True, exist_ok=True)
    except OSError:
        return False
    return os.access(path, os.W_OK | os.X_OK)


def choose_writable_dir(preferred: pathlib.Path, fallback: pathlib.Path, label: str) -> pathlib.Path:
    candidate = preferred.expanduser()
    if ensure_writable_dir(candidate):
        return candidate

    fallback_dir = fallback.expanduser()
    if ensure_writable_dir(fallback_dir):
        print(
            f"codex-bridge: {label} path '{candidate}' is not writable; using '{fallback_dir}'",
            file=sys.stderr,
            flush=True,
        )
        return fallback_dir

    return candidate


def load_config() -> Config:
    uid = os.getuid()
    home = pathlib.Path.home()
    xdg_runtime = pathlib.Path(os.environ.get("XDG_RUNTIME_DIR", f"/tmp/s2t-{uid}"))
    xdg_state = pathlib.Path(os.environ.get("XDG_STATE_HOME", str(home / ".local" / "state")))
    xdg_data = pathlib.Path(os.environ.get("XDG_DATA_HOME", str(home / ".local" / "share")))
    default_dataset_root = xdg_data / "s2t" / "dataset"
    dataset_root = choose_writable_dir(
        env_path("S2T_DATASET_ROOT", default_dataset_root),
        default_dataset_root,
        "dataset_root",
    )
    pending_dir = choose_writable_dir(
        env_path("S2T_DATASET_PENDING_DIR", dataset_root / "pending"),
        dataset_root / "pending",
        "pending_dir",
    )

    sessions_dir = env_path("S2T_CODEX_SESSIONS_DIR", home / ".codex" / "sessions")
    state_file = env_path("S2T_CODEX_BRIDGE_STATE_FILE", xdg_state / "s2t" / "codex-bridge-state.json")

    controller_raw = env_str(
        "S2T_CODEX_BRIDGE_CONTROLLER",
        env_str("S2T_CONTROLLER", "/etc/s2t/result/bin/s2t-controller"),
    )
    controller_cmd = shlex.split(controller_raw)
    if not controller_cmd:
        controller_cmd = ["/etc/s2t/result/bin/s2t-controller"]

    if not pathlib.Path(controller_cmd[0]).exists():
        controller_cmd[0] = "/etc/s2t/scripts/controller.sh"

    if not pathlib.Path(controller_cmd[0]).is_absolute():
        resolved = shutil.which(controller_cmd[0])
        if resolved:
            controller_cmd[0] = resolved

    return Config(
        sessions_dir=sessions_dir,
        state_file=state_file,
        pending_dir=pending_dir,
        controller_cmd=controller_cmd,
        poll_sec=env_float("S2T_CODEX_BRIDGE_POLL_SEC", 1.0, minimum=0.2),
        window_sec=env_float("S2T_CODEX_BRIDGE_WINDOW_SEC", 30.0, minimum=1.0),
        max_pending_age_sec=env_float("S2T_CODEX_BRIDGE_MAX_PENDING_AGE_SEC", 600.0, minimum=1.0),
        max_msg_chars=env_int("S2T_CODEX_BRIDGE_MAX_MSG_CHARS", 900, minimum=32),
        min_shared_tokens=env_int("S2T_CODEX_BRIDGE_MIN_SHARED_TOKENS", 2, minimum=0),
        min_overlap_ratio=env_float("S2T_CODEX_BRIDGE_MIN_TOKEN_OVERLAP", 0.2, minimum=0.0),
        submit_timeout_sec=env_int("S2T_CODEX_BRIDGE_SUBMIT_TIMEOUT_SEC", 20, minimum=2),
        backfill_existing=env_bool("S2T_CODEX_BRIDGE_BACKFILL_EXISTING", False),
        run_once=env_bool("S2T_CODEX_BRIDGE_RUN_ONCE", False),
        allow_time_fallback=env_bool("S2T_CODEX_BRIDGE_TIME_FALLBACK", True),
        log_file=env_path("S2T_CODEX_BRIDGE_LOG_FILE", xdg_runtime / "s2t" / "codex-bridge.log"),
        log_verbose=env_bool("S2T_CODEX_BRIDGE_LOG_VERBOSE", True),
        log_max_bytes=env_int("S2T_CODEX_BRIDGE_LOG_MAX_BYTES", 1024 * 1024, minimum=4096),
        log_keep=env_int("S2T_CODEX_BRIDGE_LOG_KEEP", 3, minimum=1),
    )


def list_session_files(sessions_dir: pathlib.Path) -> list[pathlib.Path]:
    if not sessions_dir.is_dir():
        return []
    files = [path for path in sessions_dir.rglob("*.jsonl") if path.is_file()]
    files.sort(key=lambda path: path.stat().st_mtime)
    return files


def load_state(path: pathlib.Path) -> dict:
    if not path.is_file():
        return {"offsets": {}, "initialized": False}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {"offsets": {}, "initialized": False}
    if not isinstance(data, dict):
        return {"offsets": {}, "initialized": False}
    offsets = data.get("offsets", {})
    if not isinstance(offsets, dict):
        offsets = {}
    initialized = bool(data.get("initialized", False))
    return {"offsets": offsets, "initialized": initialized}


def save_state(path: pathlib.Path, state: dict) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(state, ensure_ascii=True), encoding="utf-8")
        tmp.replace(path)
    except OSError:
        pass


def parse_timestamp_ms(value: str) -> int | None:
    if not value:
        return None
    raw = value.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        stamp = dt.datetime.fromisoformat(raw)
    except ValueError:
        return None
    return int(stamp.timestamp() * 1000)

def strip_ide_wrapper(text: str) -> str:
    """
    Codex IDE integrations often wrap the user's actual request in a long,
    multi-line context block (open tabs, active file, etc).

    We only want the user's request portion for submit-correction.
    """
    if not text:
        return ""

    marker_variants = (
        "## My request for Codex:",
        "## My request for codex:",
        "My request for Codex:",
        "My request for codex:",
    )
    lines = text.splitlines()
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if any(stripped == m for m in marker_variants):
            remainder = "\n".join(lines[idx + 1 :]).strip()
            return remainder
    return text


def extract_user_text(event: dict) -> tuple[int | None, str]:
    if event.get("type") != "response_item":
        return None, ""
    payload = event.get("payload")
    if not isinstance(payload, dict):
        return None, ""
    if payload.get("type") != "message" or payload.get("role") != "user":
        return None, ""
    content = payload.get("content")
    if not isinstance(content, list):
        return None, ""

    parts: list[str] = []
    for item in content:
        if not isinstance(item, dict):
            continue
        item_type = item.get("type")
        if item_type in {"input_text", "text"}:
            text = item.get("text", "")
            if isinstance(text, str) and text:
                parts.append(text)

    joined = "\n".join(parts).strip()
    joined = strip_ide_wrapper(joined).strip()
    ts_ms = parse_timestamp_ms(str(event.get("timestamp", "")))
    return ts_ms, joined


def parse_meta_file(path: pathlib.Path) -> tuple[str, int, pathlib.Path | None]:
    sample_id = ""
    created_ms = -1
    raw_path: pathlib.Path | None = None
    try:
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            if key == "sample_id":
                sample_id = value
            elif key == "created_ms":
                if value.isdigit():
                    created_ms = int(value)
            elif key == "raw_text":
                raw_path = pathlib.Path(value).expanduser()
    except OSError:
        return "", -1, None

    if not sample_id:
        sample_id = path.stem
    if created_ms < 0:
        head = sample_id.split("_", 1)[0]
        if head.isdigit():
            created_ms = int(head)

    if raw_path is None:
        fallback = path.with_suffix(".raw.txt")
        if fallback.is_file():
            raw_path = fallback

    return sample_id, created_ms, raw_path


def list_pending_samples(pending_dir: pathlib.Path) -> list[PendingSample]:
    result: list[PendingSample] = []
    metas = sorted(pending_dir.glob("*.meta"), key=lambda p: p.stat().st_mtime)
    for meta in metas:
        sample_id, created_ms, raw_path = parse_meta_file(meta)
        if not sample_id or created_ms < 0:
            continue

        raw_text = ""
        if raw_path is not None and raw_path.is_file():
            try:
                raw_text = raw_path.read_text(encoding="utf-8")
            except OSError:
                raw_text = ""

        result.append(PendingSample(sample_id=sample_id, created_ms=created_ms, raw_text=raw_text))
    return result


def tokenize(text: str) -> list[str]:
    return re.findall(r"[A-Za-z0-9_]+|[А-Яа-яЁё0-9_]+", text.lower())


def token_overlap(raw_text: str, corrected_text: str) -> tuple[int, float]:
    left = tokenize(raw_text)
    right = tokenize(corrected_text)
    if not left or not right:
        return 0, 0.0
    left_set = set(left)
    right_set = set(right)
    shared = len(left_set.intersection(right_set))
    denom = float(min(len(left_set), len(right_set)))
    ratio = shared / denom if denom > 0 else 0.0
    return shared, ratio


def text_similarity(raw_text: str, corrected_text: str) -> float:
    left = " ".join(tokenize(raw_text))
    right = " ".join(tokenize(corrected_text))
    if not left or not right:
        return 0.0
    return float(difflib.SequenceMatcher(a=left, b=right, autojunk=True).ratio())


def correction_rejection_reason(text: str) -> str:
    if not text:
        return "empty"
    if len(text) > 4000:
        return f"too long ({len(text)} chars)"
    if "`" in text:
        return "contains backticks/code fragment"
    if "```" in text:
        return "contains fenced code"
    if text.lstrip().startswith("# AGENTS.md"):
        return "agents snippet"
    if "Context from my IDE setup" in text:
        return "ide wrapper"

    lowered = text.lower()
    diagnostic_markers = (
        ".log",
        "sample_id=",
        "runtime_dir=",
        "provider=",
        "server_url=",
        "pid=",
        "action=",
        "dataset:",
        "asr:",
        "/home/",
        "/run/user/",
    )
    if any(marker in lowered for marker in diagnostic_markers):
        return "diagnostic/log-like message"

    if re.search(r"\b\d{4}-\d{2}-\d{2}t\d{2}:\d{2}:\d{2}", lowered):
        return "timestamp/log-like message"

    return ""


def submit_correction(cfg: Config, text: str, sample_id: str) -> tuple[bool, str]:
    cmd = list(cfg.controller_cmd) + ["submit-correction"]
    if sample_id:
        cmd += ["--id", sample_id]
    try:
        completed = subprocess.run(
            cmd,
            input=text + "\n",
            text=True,
            capture_output=True,
            timeout=cfg.submit_timeout_sec,
        )
    except subprocess.TimeoutExpired:
        return False, "submit-correction timed out"
    except OSError as exc:
        return False, f"submit-correction execution failed: {exc}"

    if completed.returncode == 0:
        out = (completed.stdout or "").strip().splitlines()
        if out:
            return True, out[-1]
        return True, "ok"

    err = (completed.stderr or "").strip().splitlines()
    reason = err[-1] if err else f"rc={completed.returncode}"
    return False, reason


def select_pending_match(
    cfg: Config,
    msg_ms: int,
    corrected_text: str,
) -> tuple[PendingSample, int, int, float, float] | None:
    candidates = list_pending_samples(cfg.pending_dir)
    if not candidates:
        return None

    window_ms = int(cfg.window_sec * 1000)
    max_age_ms = int(cfg.max_pending_age_sec * 1000)

    best: tuple[tuple[int, float, float, int], PendingSample, int, int, float, float] | None = None
    for pending in candidates:
        delta_ms = msg_ms - pending.created_ms
        if delta_ms < 0:
            continue
        if delta_ms > max_age_ms:
            continue

        shared_tokens, overlap = token_overlap(pending.raw_text, corrected_text)
        similarity = text_similarity(pending.raw_text, corrected_text)
        basic_match = (
            shared_tokens >= cfg.min_shared_tokens
            or overlap >= cfg.min_overlap_ratio
            or similarity >= 0.45
        )
        if not basic_match:
            continue

        # If user corrected text is delayed, require a stronger lexical signal.
        if delta_ms > window_ms:
            strong_match = shared_tokens >= 4 or overlap >= 0.45 or similarity >= 0.72
            if not strong_match:
                continue

        score = (shared_tokens, overlap, similarity, pending.created_ms)
        if best is None or score > best[0]:
            best = (score, pending, delta_ms, shared_tokens, overlap, similarity)

    if best is None:
        return None
    return best[1], best[2], best[3], best[4], best[5]


def select_pending_fallback_by_time(
    cfg: Config,
    msg_ms: int,
) -> PendingSample | None:
    """
    Fallback pairing when lexical matching is impossible (e.g. very bad ASR),
    but the user message is fresh.

    Rule: strict window and require exactly one candidate pending audio.
    """
    candidates = list_pending_samples(cfg.pending_dir)
    if not candidates:
        return None
    window_ms = int(cfg.window_sec * 1000)

    if not cfg.allow_time_fallback:
        return None

    in_window: list[PendingSample] = []
    for pending in candidates:
        delta_ms = msg_ms - pending.created_ms
        if 0 <= delta_ms <= window_ms:
            in_window.append(pending)
    if len(in_window) != 1:
        return None
    return in_window[0]


def process_message(cfg: Config, msg_ms: int | None, text: str) -> None:
    cleaned = strip_ide_wrapper(text.strip()).strip()
    if "\n" in cleaned:
        cleaned = " ".join(line.strip() for line in cleaned.splitlines() if line.strip()).strip()
    rejection = correction_rejection_reason(cleaned)
    if rejection:
        logv(f"skip message: {rejection}")
        return
    if len(cleaned) > cfg.max_msg_chars:
        logv(f"skip message: too long ({len(cleaned)} chars)")
        return
    if msg_ms is None:
        return

    match = select_pending_match(cfg, msg_ms, cleaned)
    if match is None:
        pending = select_pending_fallback_by_time(cfg, msg_ms)
        if pending is None:
            logv("skip message: no suitable pending sample match")
            return
        ok, result = submit_correction(cfg, cleaned, pending.sample_id)
        if ok:
            log(
                "submitted correction "
                f"sample_id={pending.sample_id} delta_ms=? shared=? overlap=? similarity=? "
                f"result={result}"
            )
        else:
            log("submit-correction failed " f"sample_id={pending.sample_id} delta_ms=? reason={result}")
        return

    pending, delta_ms, shared_tokens, overlap, similarity = match
    ok, result = submit_correction(cfg, cleaned, pending.sample_id)
    if ok:
        log(
            "submitted correction "
            f"sample_id={pending.sample_id} delta_ms={delta_ms} shared={shared_tokens} "
            f"overlap={overlap:.3f} similarity={similarity:.3f} "
            f"result={result}"
        )
    else:
        log(
            "submit-correction failed "
            f"sample_id={pending.sample_id} delta_ms={delta_ms} reason={result}"
        )


def process_new_lines(cfg: Config, state: dict) -> bool:
    changed = False
    offsets = state.setdefault("offsets", {})
    files = list_session_files(cfg.sessions_dir)
    initialized = bool(state.get("initialized", False))

    if not initialized and not cfg.backfill_existing:
        for path in files:
            try:
                offsets[str(path)] = path.stat().st_size
            except OSError:
                offsets[str(path)] = 0
        state["initialized"] = True
        if files:
            log(f"initialized at EOF for existing session files: count={len(files)}")
        return True

    if not initialized:
        state["initialized"] = True
        changed = True

    known = set(str(path) for path in files)
    stale = [path for path in list(offsets.keys()) if path not in known]
    for path in stale:
        offsets.pop(path, None)
        changed = True

    for path in files:
        key = str(path)
        start = int(offsets.get(key, 0) or 0)
        try:
            size = path.stat().st_size
        except OSError:
            continue
        if start > size:
            start = 0

        try:
            with path.open("r", encoding="utf-8", errors="ignore") as fh:
                fh.seek(start)
                while True:
                    line = fh.readline()
                    if not line:
                        break
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    msg_ms, text = extract_user_text(event)
                    if text:
                        process_message(cfg, msg_ms, text)
                offsets[key] = fh.tell()
        except OSError:
            continue

        if offsets.get(key, 0) != start:
            changed = True

    return changed


def main() -> int:
    if not env_bool("S2T_CODEX_BRIDGE_ENABLED", True):
        return 0

    cfg = load_config()
    global _LOGGER
    _LOGGER = Logger(
        log_file=cfg.log_file,
        verbose=cfg.log_verbose,
        max_bytes=cfg.log_max_bytes,
        keep=cfg.log_keep,
        prefix="codex-bridge: ",
    )
    cfg.pending_dir.mkdir(parents=True, exist_ok=True)
    state = load_state(cfg.state_file)

    log(
        "started "
        f"sessions={cfg.sessions_dir} pending={cfg.pending_dir} "
        f"window_sec={cfg.window_sec} max_pending_age_sec={cfg.max_pending_age_sec} "
        f"poll_sec={cfg.poll_sec} "
        f"controller={shlex.join(cfg.controller_cmd)}"
    )

    while True:
        changed = process_new_lines(cfg, state)
        if changed:
            save_state(cfg.state_file, state)

        if cfg.run_once:
            return 0
        time.sleep(cfg.poll_sec)


if __name__ == "__main__":
    raise SystemExit(main())
