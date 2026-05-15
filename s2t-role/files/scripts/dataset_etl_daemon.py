#!/usr/bin/env python3
"""Asynchronous dataset ETL daemon for S2T correction jobs."""

from __future__ import annotations

import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass

from s2t_common import Logger, env_bool, env_float, env_int, env_path, env_str


@dataclass
class Config:
    dataset_root: pathlib.Path
    raw_dir: pathlib.Path
    queue_dir: pathlib.Path
    output_dir: pathlib.Path
    quarantine_dir: pathlib.Path
    builder_path: pathlib.Path
    poll_interval_sec: float
    test_ratio: float
    jobs: int
    seed: int
    autorun: bool
    run_once: bool
    validate_pairs: bool
    validate_with_llm: bool
    llm_required: bool
    llm_timeout_sec: int
    llm_validator_cmd: str
    llm_model: str
    asr_probe_enabled: bool
    asr_probe_required: bool
    asr_probe_url: str
    asr_probe_timeout_sec: int
    quarantine_mode: str
    log_verbose: bool
    log_file: pathlib.Path
    log_max_bytes: int
    log_keep: int
    python_bin: str
    requeue_processing_sec: int


@dataclass
class JobSpec:
    path: pathlib.Path
    sample_id: str
    audio_path: pathlib.Path
    text_path: pathlib.Path
    queued_ms: int


_LOGGER: Logger | None = None


def log(message: str) -> None:
    if _LOGGER is None:
        print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {message}", flush=True)
        return
    _LOGGER.log(message)


def logv(message: str) -> None:
    if _LOGGER is None:
        return
    _LOGGER.logv(message)


def clip_text(value: str, limit: int = 1200) -> str:
    value = value.strip()
    if len(value) <= limit:
        return value
    return value[: limit - 3] + "..."


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
            f"dataset-etl: {label} path '{candidate}' is not writable; using '{fallback_dir}'",
            file=sys.stderr,
            flush=True,
        )
        return fallback_dir

    return candidate


def strip_markdown_fence(value: str) -> str:
    stripped = value.strip()
    if stripped.startswith("```"):
        stripped = re.sub(r"^```[a-zA-Z0-9_-]*\n", "", stripped)
        stripped = re.sub(r"\n```$", "", stripped)
    return stripped.strip()


def load_config() -> Config:
    home = pathlib.Path.home()
    xdg_data_home = pathlib.Path(os.environ.get("XDG_DATA_HOME", str(home / ".local" / "share"))).expanduser()
    xdg_runtime_dir = pathlib.Path(os.environ.get("XDG_RUNTIME_DIR", f"/tmp/s2t-{os.getuid()}")).expanduser()

    default_dataset_root = xdg_data_home / "s2t" / "dataset"
    dataset_root = choose_writable_dir(
        env_path("S2T_DATASET_ROOT", default_dataset_root),
        default_dataset_root,
        "dataset_root",
    )
    raw_dir = choose_writable_dir(
        env_path("S2T_DATASET_RAW_DIR", dataset_root / "raw"),
        dataset_root / "raw",
        "raw_dir",
    )
    queue_dir = choose_writable_dir(
        env_path("S2T_DATASET_QUEUE_DIR", dataset_root / "queue"),
        dataset_root / "queue",
        "queue_dir",
    )
    output_dir = choose_writable_dir(
        env_path("S2T_DATASET_OUTPUT_DIR", dataset_root / "hf"),
        dataset_root / "hf",
        "output_dir",
    )
    quarantine_dir = choose_writable_dir(
        env_path("S2T_DATASET_QUARANTINE_DIR", dataset_root / "quarantine"),
        dataset_root / "quarantine",
        "quarantine_dir",
    )
    builder_path = env_path("S2T_DATASET_BUILDER", pathlib.Path("/etc/s2t/scripts/build_dataset.py"))

    poll_interval = env_float("S2T_DATASET_ETL_INTERVAL_SEC", 2.0, minimum=0.2)
    test_ratio = env_float("S2T_DATASET_TEST_RATIO", 0.1, minimum=0.0)
    if test_ratio >= 1.0:
        test_ratio = 0.1

    jobs = env_int("S2T_DATASET_JOBS", 4, minimum=1)
    seed = env_int("S2T_DATASET_SEED", 42, minimum=0)
    autorun = env_bool("S2T_DATASET_ETL_AUTORUN", True)
    run_once = env_bool("S2T_DATASET_ETL_ONCE", False)

    validate_pairs = env_bool("S2T_DATASET_VALIDATE_PAIRS", True)
    validate_with_llm = env_bool("S2T_DATASET_VALIDATE_WITH_LLM", False)
    llm_required = env_bool("S2T_DATASET_LLM_REQUIRED", False)
    llm_timeout_sec = env_int("S2T_DATASET_LLM_TIMEOUT_SEC", 45, minimum=5)
    llm_validator_cmd = env_str("S2T_DATASET_LLM_VALIDATOR_CMD", str(home / ".local" / "bin" / "codex"))
    llm_model = env_str("S2T_DATASET_LLM_MODEL", "")

    asr_probe_enabled = env_bool("S2T_DATASET_ASR_PROBE_ENABLED", True)
    asr_probe_required = env_bool("S2T_DATASET_ASR_PROBE_REQUIRED", False)
    asr_probe_url = env_str("S2T_DATASET_ASR_PROBE_URL", env_str("S2T_WHISPER_SERVER_URL", "http://127.0.0.1:9787/inference"))
    asr_probe_timeout_sec = env_int("S2T_DATASET_ASR_PROBE_TIMEOUT_SEC", 15, minimum=1)
    quarantine_mode = env_str("S2T_DATASET_QUARANTINE_MODE", "copy").lower()
    if quarantine_mode not in {"copy", "move"}:
        quarantine_mode = "copy"
    log_verbose = env_bool("S2T_DATASET_LOG_VERBOSE", True)
    log_file = env_path("S2T_DATASET_LOG_FILE", xdg_runtime_dir / "s2t" / "dataset-etl.log")
    log_max_bytes = env_int("S2T_DATASET_LOG_MAX_BYTES", 2 * 1024 * 1024, minimum=4096)
    log_keep = env_int("S2T_DATASET_LOG_KEEP", 5, minimum=1)
    requeue_processing_sec = env_int("S2T_DATASET_REQUEUE_PROCESSING_SEC", 300, minimum=10)

    python_bin = shutil.which("python3") or sys.executable

    return Config(
        dataset_root=dataset_root,
        raw_dir=raw_dir,
        queue_dir=queue_dir,
        output_dir=output_dir,
        quarantine_dir=quarantine_dir,
        builder_path=builder_path,
        poll_interval_sec=poll_interval,
        test_ratio=test_ratio,
        jobs=jobs,
        seed=seed,
        autorun=autorun,
        run_once=run_once,
        validate_pairs=validate_pairs,
        validate_with_llm=validate_with_llm,
        llm_required=llm_required,
        llm_timeout_sec=llm_timeout_sec,
        llm_validator_cmd=llm_validator_cmd,
        llm_model=llm_model,
        asr_probe_enabled=asr_probe_enabled,
        asr_probe_required=asr_probe_required,
        asr_probe_url=asr_probe_url,
        asr_probe_timeout_sec=asr_probe_timeout_sec,
        quarantine_mode=quarantine_mode,
        log_verbose=log_verbose,
        log_file=log_file,
        log_max_bytes=log_max_bytes,
        log_keep=log_keep,
        python_bin=python_bin,
        requeue_processing_sec=requeue_processing_sec,
    )


def ensure_dirs(cfg: Config) -> None:
    cfg.dataset_root.mkdir(parents=True, exist_ok=True)
    cfg.raw_dir.mkdir(parents=True, exist_ok=True)
    cfg.queue_dir.mkdir(parents=True, exist_ok=True)
    cfg.output_dir.mkdir(parents=True, exist_ok=True)
    cfg.quarantine_dir.mkdir(parents=True, exist_ok=True)


def parse_job(path: pathlib.Path) -> JobSpec:
    payload: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        payload[key.strip()] = value.strip()

    sample_id = payload.get("sample_id", "").strip()
    audio_raw = payload.get("audio", "").strip()
    text_raw = payload.get("text", "").strip()
    queued_raw = payload.get("queued_ms", "").strip()

    if not sample_id:
        raise ValueError("missing sample_id")
    if not audio_raw:
        raise ValueError("missing audio")
    if not text_raw:
        raise ValueError("missing text")

    try:
        queued_ms = int(queued_raw) if queued_raw else int(time.time() * 1000)
    except ValueError as exc:
        raise ValueError("invalid queued_ms") from exc

    return JobSpec(
        path=path,
        sample_id=sample_id,
        audio_path=pathlib.Path(audio_raw).expanduser().resolve(),
        text_path=pathlib.Path(text_raw).expanduser().resolve(),
        queued_ms=queued_ms,
    )


def claim_jobs(queue_dir: pathlib.Path) -> list[pathlib.Path]:
    claimed: list[pathlib.Path] = []
    for job in sorted(queue_dir.glob("*.job")):
        processing = job.with_suffix(job.suffix + ".processing")
        try:
            job.rename(processing)
        except FileNotFoundError:
            continue
        except OSError:
            continue
        claimed.append(processing)
    return claimed


def recover_stale_processing_jobs(queue_dir: pathlib.Path, max_age_sec: int) -> int:
    """Requeue old *.job.processing files back to *.job.

    This makes the file-queue at-least-once even across crashes/restarts.
    """
    if max_age_sec <= 0:
        return 0
    now = time.time()
    recovered = 0
    for path in sorted(queue_dir.glob("*.job.processing")):
        try:
            age = now - path.stat().st_mtime
        except OSError:
            continue
        if age < float(max_age_sec):
            continue
        dst = path.with_suffix("")
        try:
            path.rename(dst)
        except OSError:
            continue
        recovered += 1
    return recovered


def run_dataset_builder(cfg: Config) -> tuple[bool, str]:
    if not cfg.builder_path.is_file():
        return False, f"dataset builder is missing: {cfg.builder_path}"

    cmd = [
        cfg.python_bin,
        str(cfg.builder_path),
        "--input-dir",
        str(cfg.raw_dir),
        "--output-dir",
        str(cfg.output_dir),
        "--test-ratio",
        str(cfg.test_ratio),
        "--jobs",
        str(cfg.jobs),
        "--seed",
        str(cfg.seed),
    ]

    log("dataset-etl: running " + " ".join(shlex.quote(x) for x in cmd))
    completed = subprocess.run(cmd, capture_output=True, text=True)
    if completed.returncode == 0:
        stdout_tail = (completed.stdout or "").strip().splitlines()[-3:]
        for line in stdout_tail:
            if line.strip():
                logv(f"dataset-etl: builder stdout: {clip_text(line, 400)}")
        return True, ""

    stderr_tail = (completed.stderr or "").strip().splitlines()[-1:] or [""]
    stdout_tail = (completed.stdout or "").strip().splitlines()[-1:] or [""]
    for line in (completed.stderr or "").strip().splitlines()[-3:]:
        if line.strip():
            log(f"dataset-etl: builder stderr: {clip_text(line, 400)}")
    reason = stderr_tail[0] or stdout_tail[0] or f"exit code {completed.returncode}"
    return False, reason


def mark_failed(job: pathlib.Path, reason: str) -> None:
    suffix = time.strftime("%Y%m%d%H%M%S")
    failed = job.with_name(f"{job.name}.failed.{suffix}")
    try:
        job.rename(failed)
    except OSError:
        return
    try:
        with failed.open("a", encoding="utf-8") as fh:
            fh.write(f"\nerror={reason}\n")
    except OSError:
        pass


def complete_jobs(jobs: list[pathlib.Path], success: bool, reason: str = "") -> None:
    for job in jobs:
        if success:
            try:
                job.unlink(missing_ok=True)
            except OSError:
                pass
        else:
            mark_failed(job, reason)


def parse_llm_json(message: str) -> tuple[bool, str]:
    cleaned = strip_markdown_fence(message)
    payload: dict | None = None

    try:
        payload = json.loads(cleaned)
    except json.JSONDecodeError:
        match = re.search(r"\{[\s\S]*\}", cleaned)
        if match:
            try:
                payload = json.loads(match.group(0))
            except json.JSONDecodeError:
                payload = None

    if not isinstance(payload, dict):
        return False, "llm response is not valid json"

    verdict = str(payload.get("verdict", "")).strip().lower()
    reason = clip_text(str(payload.get("reason", "")).strip(), 300)
    if verdict not in {"accept", "reject"}:
        return False, "llm response has invalid verdict"

    if verdict == "accept":
        return True, reason or "llm accepted"
    return False, reason or "llm rejected pair"


def resolve_llm_executable(cmd: str) -> list[str] | None:
    tokens = shlex.split(cmd)
    if not tokens:
        return None

    exe = tokens[0]
    if not pathlib.Path(exe).is_absolute():
        resolved = shutil.which(exe)
        if not resolved:
            return None
        tokens[0] = resolved
    elif not pathlib.Path(exe).is_file():
        return None

    return tokens


def build_llm_prompt(spec: JobSpec, corrected_text: str, probe_transcript: str, audio_size: int) -> str:
    return (
        "You are validating a speech dataset pair for training.\\n"
        "Decide if corrected_text matches the meaning of audio_probe_transcript from the same audio.\\n"
        "Rules: allow punctuation/style differences and small paraphrases; reject if topic/intent differs, "
        "language is clearly different, or transcript looks unrelated.\\n"
        "Return JSON only: {\"verdict\":\"accept|reject\",\"confidence\":0.0,\"reason\":\"...\"}.\\n\\n"
        f"sample_id: {spec.sample_id}\\n"
        f"audio_path: {spec.audio_path}\\n"
        f"audio_size_bytes: {audio_size}\\n"
        f"corrected_text: {clip_text(corrected_text, 1200)}\\n"
        f"audio_probe_transcript: {clip_text(probe_transcript, 1200) if probe_transcript else '[UNAVAILABLE]'}\\n"
    )


def run_llm_validation(cfg: Config, spec: JobSpec, corrected_text: str, probe_transcript: str, audio_size: int) -> tuple[bool, str]:
    resolved = resolve_llm_executable(cfg.llm_validator_cmd)
    if not resolved:
        return (not cfg.llm_required), "llm validator command is unavailable"

    cmd = list(resolved)
    if not cmd or cmd[-1] != "exec":
        cmd.append("exec")

    cmd.extend([
        "--skip-git-repo-check",
        "--sandbox",
        "read-only",
        "-C",
        str(cfg.dataset_root),
    ])
    if cfg.llm_model:
        cmd.extend(["-m", cfg.llm_model])

    with tempfile.NamedTemporaryFile(prefix="s2t-llm-", suffix=".txt", delete=False) as tmp:
        output_file = pathlib.Path(tmp.name)

    cmd.extend(["--output-last-message", str(output_file)])

    prompt = build_llm_prompt(spec, corrected_text, probe_transcript, audio_size)
    logv(
        "dataset-etl: llm validation request "
        f"sample_id={spec.sample_id} cmd={shlex.join(cmd)} text_len={len(corrected_text)} probe_len={len(probe_transcript)}"
    )
    try:
        completed = subprocess.run(
            cmd,
            input=prompt,
            text=True,
            capture_output=True,
            timeout=cfg.llm_timeout_sec,
        )
    except subprocess.TimeoutExpired:
        output_file.unlink(missing_ok=True)
        return (not cfg.llm_required), "llm validation timeout"
    except OSError as exc:
        output_file.unlink(missing_ok=True)
        return (not cfg.llm_required), f"llm validation failed to start: {exc}"

    message = ""
    try:
        if output_file.is_file():
            message = output_file.read_text(encoding="utf-8")
    except OSError:
        message = ""
    finally:
        output_file.unlink(missing_ok=True)

    if completed.returncode != 0:
        stderr_tail = (completed.stderr or "").strip().splitlines()[-1:] or [""]
        reason = stderr_tail[0] or f"llm validator rc={completed.returncode}"
        return (not cfg.llm_required), f"llm validator execution error: {reason}"

    accepted, reason = parse_llm_json(message)
    logv(
        "dataset-etl: llm validation result "
        f"sample_id={spec.sample_id} accepted={int(accepted)} reason={clip_text(reason, 220)}"
    )
    return accepted, reason


def probe_audio_transcript(cfg: Config, sample_id: str, audio_path: pathlib.Path) -> tuple[str, str]:
    if not cfg.asr_probe_enabled:
        return "", "probe disabled"

    curl_bin = shutil.which("curl")
    if not curl_bin:
        return "", "curl is unavailable"

    cmd = [
        curl_bin,
        "-sf",
        "--max-time",
        str(cfg.asr_probe_timeout_sec),
        "-F",
        f"file=@{audio_path};type=audio/wav",
        cfg.asr_probe_url,
    ]
    logv(
        "dataset-etl: asr probe request "
        f"sample_id={sample_id} url={cfg.asr_probe_url} timeout={cfg.asr_probe_timeout_sec}s audio={audio_path}"
    )

    try:
        completed = subprocess.run(cmd, capture_output=True, text=True, timeout=cfg.asr_probe_timeout_sec + 2)
    except subprocess.TimeoutExpired:
        return "", "probe timeout"
    except OSError as exc:
        return "", f"probe execution failed: {exc}"

    if completed.returncode != 0:
        stderr_tail = (completed.stderr or "").strip().splitlines()[-1:] or [""]
        return "", stderr_tail[0] or f"probe rc={completed.returncode}"

    payload = (completed.stdout or "").strip()
    if not payload:
        return "", "probe response empty"

    try:
        data = json.loads(payload)
    except json.JSONDecodeError:
        return "", "probe response is invalid json"

    transcript = str(data.get("text", "")).strip()
    if not transcript:
        return "", "probe transcript is empty"
    logv(f"dataset-etl: asr probe ok sample_id={sample_id} transcript_len={len(transcript)}")
    return transcript, ""


def quarantine_file(path: pathlib.Path, target_dir: pathlib.Path, reason_tag: str, mode: str) -> pathlib.Path | None:
    if not path.exists():
        return None

    target_dir.mkdir(parents=True, exist_ok=True)
    safe_reason = re.sub(r"[^A-Za-z0-9_.-]+", "_", reason_tag)[:32] or "invalid"
    destination = target_dir / f"{path.stem}.{safe_reason}{path.suffix}"
    idx = 1
    while destination.exists():
        destination = target_dir / f"{path.stem}.{safe_reason}.{idx}{path.suffix}"
        idx += 1

    try:
        if mode == "move":
            shutil.move(str(path), str(destination))
        else:
            shutil.copy2(str(path), str(destination))
        return destination
    except OSError:
        return None


def quarantine_assets(cfg: Config, spec: JobSpec, reason: str) -> None:
    day = time.strftime("%Y-%m-%d")
    reason_tag = reason.split(" ", 1)[0].replace(":", "_")
    target_dir = cfg.quarantine_dir / day

    moved_audio = quarantine_file(spec.audio_path, target_dir, reason_tag, cfg.quarantine_mode)
    moved_text = quarantine_file(spec.text_path, target_dir, reason_tag, cfg.quarantine_mode)

    if moved_audio or moved_text:
        log(
            "dataset-etl: quarantined sample "
            f"sample_id={spec.sample_id} audio={moved_audio or spec.audio_path} text={moved_text or spec.text_path}"
            f" mode={cfg.quarantine_mode}"
        )


def validate_job(cfg: Config, spec: JobSpec) -> tuple[bool, str]:
    if not spec.audio_path.is_file():
        return False, f"missing audio file: {spec.audio_path}"
    if not spec.text_path.is_file():
        return False, f"missing text file: {spec.text_path}"

    try:
        audio_size = spec.audio_path.stat().st_size
    except OSError as exc:
        return False, f"cannot stat audio file: {exc}"
    if audio_size <= 44:
        return False, f"audio payload is too small: {audio_size} bytes"

    try:
        corrected_text = spec.text_path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        return False, f"cannot read text file: {exc}"
    if not corrected_text:
        return False, "corrected text is empty"
    logv(
        "dataset-etl: validate sample "
        f"sample_id={spec.sample_id} audio_size={audio_size} text_len={len(corrected_text)}"
    )

    if not cfg.validate_pairs:
        return True, "validation disabled"

    probe_transcript = ""
    probe_error = ""
    if cfg.asr_probe_enabled:
        probe_transcript, probe_error = probe_audio_transcript(cfg, spec.sample_id, spec.audio_path)
        if probe_error:
            if cfg.asr_probe_required:
                return False, f"asr probe failed: {probe_error}"
            log(f"dataset-etl: asr probe warning sample_id={spec.sample_id}: {probe_error}")

    if cfg.validate_with_llm:
        accepted, llm_reason = run_llm_validation(cfg, spec, corrected_text, probe_transcript, audio_size)
        if not accepted:
            return False, f"llm validation failed: {llm_reason}"

    return True, "ok"


def split_jobs_by_validation(cfg: Config, jobs: list[pathlib.Path]) -> list[pathlib.Path]:
    valid_jobs: list[pathlib.Path] = []

    for job in jobs:
        logv(f"dataset-etl: processing job={job}")
        try:
            spec = parse_job(job)
        except Exception as exc:  # noqa: BLE001
            mark_failed(job, f"invalid job payload: {exc}")
            continue
        logv(
            "dataset-etl: parsed job "
            f"sample_id={spec.sample_id} audio={spec.audio_path} text={spec.text_path} queued_ms={spec.queued_ms}"
        )

        accepted, reason = validate_job(cfg, spec)
        if accepted:
            valid_jobs.append(job)
            continue

        quarantine_assets(cfg, spec, reason)
        mark_failed(job, reason)
        log(f"dataset-etl: rejected sample_id={spec.sample_id}: {reason}")

    return valid_jobs


def main() -> int:
    cfg = load_config()
    global _LOGGER
    _LOGGER = Logger(
        log_file=cfg.log_file,
        verbose=cfg.log_verbose,
        max_bytes=cfg.log_max_bytes,
        keep=cfg.log_keep,
        prefix="",
    )
    ensure_dirs(cfg)

    log(
        "dataset-etl: started "
        f"queue={cfg.queue_dir} raw={cfg.raw_dir} out={cfg.output_dir} autorun={int(cfg.autorun)} "
        f"validate_pairs={int(cfg.validate_pairs)} validate_llm={int(cfg.validate_with_llm)} "
        f"llm_required={int(cfg.llm_required)} quarantine_mode={cfg.quarantine_mode} "
        f"log_file={cfg.log_file} log_verbose={int(cfg.log_verbose)}"
    )

    while True:
        recovered = recover_stale_processing_jobs(cfg.queue_dir, cfg.requeue_processing_sec)
        if recovered:
            log(f"dataset-etl: recovered stale processing jobs={recovered}")

        jobs = claim_jobs(cfg.queue_dir)
        if not jobs:
            if cfg.run_once:
                return 0
            time.sleep(cfg.poll_interval_sec)
            continue

        log(f"dataset-etl: claimed jobs={len(jobs)}")

        if not cfg.autorun:
            complete_jobs(jobs, success=True)
            log("dataset-etl: autorun disabled, jobs acknowledged")
            if cfg.run_once:
                return 0
            continue

        valid_jobs = split_jobs_by_validation(cfg, jobs)
        if not valid_jobs:
            log("dataset-etl: no valid jobs after validation")
            if cfg.run_once:
                return 0
            time.sleep(0.05)
            continue

        ok, reason = run_dataset_builder(cfg)
        if ok:
            complete_jobs(valid_jobs, success=True)
            log(f"dataset-etl: build complete, accepted_jobs={len(valid_jobs)}")
        else:
            complete_jobs(valid_jobs, success=False, reason=reason)
            log(f"dataset-etl: build failed: {reason}")

        if cfg.run_once:
            return 0
        time.sleep(0.05)


if __name__ == "__main__":
    raise SystemExit(main())
