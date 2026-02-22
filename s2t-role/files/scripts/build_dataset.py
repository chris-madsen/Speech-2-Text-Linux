#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Tuple

CONTROL_RE = re.compile(r"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]")
SPACE_RE = re.compile(r"\s+")
SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9._-]+")


@dataclass(frozen=True)
class Pair:
    rel_stem: str
    audio_path: Path
    text_path: Path


@dataclass(frozen=True)
class Sample:
    rel_stem: str
    audio_rel_path: str
    sentence: str


@dataclass(frozen=True)
class PipelineError:
    rel_stem: str
    stage: str
    message: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Build a Whisper-ready JSONL dataset from paired audio/text files. "
            "Audio is re-encoded to 16kHz mono 16-bit PCM WAV via ffmpeg."
        )
    )
    parser.add_argument("--input-dir", required=True, help="Root directory with source pairs.")
    parser.add_argument("--output-dir", required=True, help="Dataset output directory.")
    parser.add_argument("--audio-ext", default=".wav", help="Input audio extension (default: .wav).")
    parser.add_argument("--text-ext", default=".txt", help="Input text extension (default: .txt).")
    parser.add_argument("--test-ratio", type=float, default=0.1, help="Test split ratio in [0, 1].")
    parser.add_argument("--seed", type=int, default=42, help="Deterministic split seed.")
    parser.add_argument("--jobs", type=int, default=max(1, min(8, os.cpu_count() or 1)), help="Parallel workers.")
    parser.add_argument(
        "--fail-on-errors",
        action="store_true",
        help="Return non-zero exit code when any sample fails to process.",
    )
    return parser.parse_args()


def normalize_ext(value: str) -> str:
    return value if value.startswith(".") else f".{value}"


def normalize_text(raw: str) -> str:
    text = raw.replace("\ufeff", "")
    text = CONTROL_RE.sub(" ", text)
    text = SPACE_RE.sub(" ", text).strip()
    return text


def safe_audio_filename(rel_stem: str) -> str:
    base = rel_stem.replace("/", "__").replace("\\", "__")
    base = SAFE_NAME_RE.sub("_", base).strip("._")
    if not base:
        base = "sample"
    digest = hashlib.sha1(rel_stem.encode("utf-8")).hexdigest()[:10]
    return f"{base}_{digest}.wav"


def discover_pairs(input_dir: Path, audio_ext: str, text_ext: str) -> Tuple[List[Pair], List[PipelineError]]:
    pairs: List[Pair] = []
    errors: List[PipelineError] = []

    for text_path in sorted(input_dir.rglob(f"*{text_ext}")):
        if not text_path.is_file():
            continue
        rel_text = text_path.relative_to(input_dir)
        rel_stem_path = rel_text.with_suffix("")
        rel_stem = rel_stem_path.as_posix()
        audio_path = input_dir / f"{rel_stem}{audio_ext}"
        if not audio_path.is_file():
            errors.append(
                PipelineError(
                    rel_stem=rel_stem,
                    stage="pairing",
                    message=f"Missing audio pair: {audio_path}",
                )
            )
            continue
        pairs.append(Pair(rel_stem=rel_stem, audio_path=audio_path, text_path=text_path))

    for audio_path in sorted(input_dir.rglob(f"*{audio_ext}")):
        if not audio_path.is_file():
            continue
        rel_audio = audio_path.relative_to(input_dir)
        rel_stem_path = rel_audio.with_suffix("")
        rel_stem = rel_stem_path.as_posix()
        text_path = input_dir / f"{rel_stem}{text_ext}"
        if not text_path.is_file():
            errors.append(
                PipelineError(
                    rel_stem=rel_stem,
                    stage="pairing",
                    message=f"Missing text pair: {text_path}",
                )
            )

    return pairs, errors


def split_bucket(rel_stem: str, seed: int) -> float:
    digest = hashlib.sha1(f"{seed}:{rel_stem}".encode("utf-8")).hexdigest()
    value = int(digest[:8], 16)
    return value / 0xFFFFFFFF


async def run_ffmpeg(ffmpeg_bin: str, src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp_dst = dst.with_suffix(".tmp.wav")
    retryable_errno = {11}
    last_retryable_error: OSError | None = None

    for attempt in range(3):
        try:
            if tmp_dst.exists():
                tmp_dst.unlink()
            cmd = [
                ffmpeg_bin,
                "-y",
                "-v",
                "error",
                "-i",
                str(src),
                "-f",
                "wav",
                "-ac",
                "1",
                "-ar",
                "16000",
                "-sample_fmt",
                "s16",
                str(tmp_dst),
            ]
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await proc.communicate()
            if proc.returncode != 0:
                message = stderr.decode("utf-8", errors="replace").strip()
                if not message:
                    message = stdout.decode("utf-8", errors="replace").strip()
                raise RuntimeError(message or f"ffmpeg exited with code {proc.returncode}")
            if not tmp_dst.exists():
                raise RuntimeError(f"ffmpeg did not produce output file: {tmp_dst}")
            tmp_dst.replace(dst)
            return
        except OSError as exc:
            if exc.errno not in retryable_errno or attempt >= 2:
                raise
            last_retryable_error = exc
            await asyncio.sleep(0.15 * (attempt + 1))

    if last_retryable_error is not None:
        raise last_retryable_error


async def process_pair(
    pair: Pair,
    ffmpeg_bin: str,
    output_audio_dir: Path,
    output_root: Path,
) -> Tuple[Sample | None, PipelineError | None]:
    try:
        raw_text = await asyncio.to_thread(pair.text_path.read_text, encoding="utf-8")
    except UnicodeDecodeError as exc:
        return None, PipelineError(pair.rel_stem, "text_read", f"UTF-8 decode failed: {exc}")
    except OSError as exc:
        return None, PipelineError(pair.rel_stem, "text_read", str(exc))

    sentence = normalize_text(raw_text)
    if not sentence:
        return None, PipelineError(pair.rel_stem, "text_validate", "Text is empty after normalization")

    audio_name = safe_audio_filename(pair.rel_stem)
    audio_out = output_audio_dir / audio_name
    try:
        await run_ffmpeg(ffmpeg_bin, pair.audio_path, audio_out)
    except Exception as exc:  # noqa: BLE001
        return None, PipelineError(pair.rel_stem, "audio_reencode", str(exc))

    audio_rel = audio_out.relative_to(output_root).as_posix()
    return Sample(rel_stem=pair.rel_stem, audio_rel_path=audio_rel, sentence=sentence), None


def write_jsonl(path: Path, rows: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False))
            fh.write("\n")


async def run() -> int:
    args = parse_args()

    audio_ext = normalize_ext(args.audio_ext)
    text_ext = normalize_ext(args.text_ext)
    if not (0.0 <= args.test_ratio <= 1.0):
        print("--test-ratio must be in [0, 1]", file=sys.stderr)
        return 2
    if args.jobs < 1:
        print("--jobs must be >= 1", file=sys.stderr)
        return 2

    ffmpeg_bin = shutil.which("ffmpeg")
    if not ffmpeg_bin:
        print("ffmpeg not found in PATH", file=sys.stderr)
        return 2

    input_dir = Path(args.input_dir).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    output_audio_dir = output_dir / "audio"
    if not input_dir.is_dir():
        print(f"Input directory does not exist: {input_dir}", file=sys.stderr)
        return 2

    pairs, pairing_errors = discover_pairs(input_dir, audio_ext, text_ext)

    sem = asyncio.Semaphore(args.jobs)
    errors: List[PipelineError] = list(pairing_errors)
    samples: List[Sample] = []

    async def worker(pair: Pair) -> None:
        async with sem:
            sample, err = await process_pair(pair, ffmpeg_bin, output_audio_dir, output_dir)
            if err:
                errors.append(err)
            if sample:
                samples.append(sample)

    await asyncio.gather(*(worker(pair) for pair in pairs))
    samples.sort(key=lambda item: item.rel_stem)

    train_rows: List[dict] = []
    test_rows: List[dict] = []
    all_rows: List[dict] = []
    for sample in samples:
        row = {"audio": sample.audio_rel_path, "sentence": sample.sentence}
        all_rows.append(row)
        bucket = split_bucket(sample.rel_stem, args.seed)
        if bucket < args.test_ratio:
            test_rows.append(row)
        else:
            train_rows.append(row)

    write_jsonl(output_dir / "all.jsonl", all_rows)
    write_jsonl(output_dir / "train.jsonl", train_rows)
    write_jsonl(output_dir / "test.jsonl", test_rows)
    write_jsonl(
        output_dir / "errors.jsonl",
        (
            {
                "rel_stem": err.rel_stem,
                "stage": err.stage,
                "message": err.message,
            }
            for err in errors
        ),
    )

    summary = {
        "input_dir": str(input_dir),
        "output_dir": str(output_dir),
        "audio_ext": audio_ext,
        "text_ext": text_ext,
        "jobs": args.jobs,
        "seed": args.seed,
        "test_ratio": args.test_ratio,
        "discovered_pairs": len(pairs),
        "processed_samples": len(samples),
        "train_samples": len(train_rows),
        "test_samples": len(test_rows),
        "errors": len(errors),
    }
    (output_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(json.dumps(summary, ensure_ascii=False))
    if errors and args.fail_on_errors:
        return 1
    return 0


def main() -> None:
    raise SystemExit(asyncio.run(run()))


if __name__ == "__main__":
    main()
