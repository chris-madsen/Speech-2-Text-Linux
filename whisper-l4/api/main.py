from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
from functools import lru_cache
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile


APP_VERSION = "0.1.0"
MODEL_PATH = Path(os.environ.get("WHISPER_MODEL_PATH", "/models/ggml-large-v3-turbo.bin"))
WHISPER_BIN = Path(os.environ.get("WHISPER_BIN", "/opt/whisper.cpp/build/bin/whisper-cli"))
MAX_SECONDS = int(os.environ.get("WHISPER_INFER_TIMEOUT_S", "300"))
DEFAULT_THREADS = int(os.environ.get("WHISPER_THREADS", "8"))
USE_FAST_ATTENTION = os.environ.get("WHISPER_USE_FA", "1").lower() not in {"0", "false", "no", "off"}


app = FastAPI(title="whisper-large-v3-turbo-l4", version=APP_VERSION)


def _gpu_probe() -> dict[str, str | bool]:
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,memory.total,driver_version", "--format=csv,noheader"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        if out.returncode != 0:
            return {"visible": False, "details": out.stderr.strip() or "nvidia-smi failed"}
        return {"visible": True, "details": out.stdout.strip()}
    except Exception as exc:  # pragma: no cover
        return {"visible": False, "details": f"gpu probe failed: {type(exc).__name__}: {exc}"}


@lru_cache(maxsize=1)
def _supports_fast_attention() -> bool:
    try:
        out = subprocess.run(
            [str(WHISPER_BIN), "--help"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        if out.returncode != 0:
            return False
        help_output = f"{out.stdout}\n{out.stderr}"
        return "-fa" in help_output
    except Exception:
        return False


def _run_whisper(audio_path: Path, *, language: str | None, translate: bool, threads: int) -> dict:
    with tempfile.TemporaryDirectory(prefix="whisper-out-") as out_dir:
        out_prefix = Path(out_dir) / "result"
        cmd = [
            str(WHISPER_BIN),
            "-m",
            str(MODEL_PATH),
            "-f",
            str(audio_path),
            "-oj",
            "-of",
            str(out_prefix),
            "-t",
            str(max(1, threads)),
            "-l",
            language or "auto",
            "--no-prints",
        ]
        if translate:
            cmd.append("--translate")
        if USE_FAST_ATTENTION and _supports_fast_attention():
            cmd.append("-fa")

        started = time.time()
        completed = subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=MAX_SECONDS)
        elapsed_ms = int((time.time() - started) * 1000)

        if completed.returncode != 0:
            raise HTTPException(
                status_code=500,
                detail={
                    "error": "whisper-cli failed",
                    "returncode": completed.returncode,
                    "stderr": completed.stderr[-4000:],
                },
            )

        json_file = Path(f"{out_prefix}.json")
        if not json_file.exists():
            raise HTTPException(status_code=500, detail="whisper-cli did not produce JSON output")

        payload = json.loads(json_file.read_text(encoding="utf-8"))
        text = _extract_text(payload)
        return {
            "elapsed_ms": elapsed_ms,
            "text": text,
            "whisper": payload,
            "stderr": completed.stderr[-2000:],
        }


def _extract_text(payload: dict) -> str:
    direct_text = payload.get("text")
    if isinstance(direct_text, str) and direct_text.strip():
        return direct_text.strip()

    transcription = payload.get("transcription")
    if isinstance(transcription, list):
        parts: list[str] = []
        for segment in transcription:
            if not isinstance(segment, dict):
                continue
            text = segment.get("text")
            if isinstance(text, str) and text.strip():
                parts.append(text.strip())
        return " ".join(parts).strip()

    return ""


def _resolve_upload(audio: UploadFile | None, file: UploadFile | None) -> UploadFile:
    resolved = audio or file
    if resolved is None:
        raise HTTPException(status_code=400, detail="audio file is required")
    return resolved


async def _infer_payload(
    audio: UploadFile | None,
    file: UploadFile | None,
    language: str | None,
    translate: bool,
    threads: int,
) -> dict:
    upload = _resolve_upload(audio, file)

    if not WHISPER_BIN.exists():
        raise HTTPException(status_code=500, detail=f"whisper binary not found: {WHISPER_BIN}")
    if not MODEL_PATH.exists():
        raise HTTPException(status_code=500, detail=f"model not found: {MODEL_PATH}")

    suffix = Path(upload.filename or "audio.wav").suffix or ".wav"
    with tempfile.NamedTemporaryFile(prefix="whisper-in-", suffix=suffix, delete=True) as temp_audio:
        content = await upload.read()
        temp_audio.write(content)
        temp_audio.flush()

        result = _run_whisper(
            Path(temp_audio.name),
            language=language if language and language.strip() else None,
            translate=bool(translate),
            threads=int(threads),
        )

    return result


@app.get("/health")
def health() -> dict:
    fast_attention_supported = _supports_fast_attention()
    return {
        "ok": WHISPER_BIN.exists() and MODEL_PATH.exists(),
        "version": APP_VERSION,
        "model_path": str(MODEL_PATH),
        "whisper_bin": str(WHISPER_BIN),
        "fast_attention": {
            "requested": USE_FAST_ATTENTION,
            "supported": fast_attention_supported,
            "enabled": USE_FAST_ATTENTION and fast_attention_supported,
        },
        "gpu": _gpu_probe(),
    }


@app.post("/infer")
async def infer(
    audio: UploadFile | None = File(default=None),
    file: UploadFile | None = File(default=None),
    language: str | None = Form(default=None),
    translate: bool = Form(default=False),
    threads: int = Form(default=DEFAULT_THREADS),
) -> dict:
    result = await _infer_payload(audio, file, language, translate, threads)

    return {
        "ok": True,
        "model": MODEL_PATH.name,
        "language": language or "auto",
        "translate": bool(translate),
        "threads": int(threads),
        "text": result.get("text", ""),
        "result": result,
    }


@app.post("/inference")
async def inference(
    audio: UploadFile | None = File(default=None),
    file: UploadFile | None = File(default=None),
    language: str | None = Form(default=None),
    translate: bool = Form(default=False),
    threads: int = Form(default=DEFAULT_THREADS),
) -> dict:
    result = await _infer_payload(audio, file, language, translate, threads)
    return {
        "text": result.get("text", ""),
        "elapsed_ms": result.get("elapsed_ms", 0),
        "model": MODEL_PATH.name,
    }
