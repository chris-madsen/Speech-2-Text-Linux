#!/usr/bin/env python3
"""Shared helpers for S2T Python scripts.

Keep this module dependency-free and stable: it is imported by multiple
long-running user services.
"""

from __future__ import annotations

import os
import pathlib
import time


def env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    return raw in {"1", "true", "yes", "on"}


def env_int(name: str, default: int, minimum: int = 0) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    if value < minimum:
        return default
    return value


def env_float(name: str, default: float, minimum: float = 0.0) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        return default
    if value < minimum:
        return default
    return value


def env_path(name: str, default: pathlib.Path) -> pathlib.Path:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    return pathlib.Path(raw).expanduser()


def env_str(name: str, default: str) -> str:
    raw = os.environ.get(name, "")
    if not raw.strip():
        return default
    return raw.strip()


def rotate_log_file(path: pathlib.Path, max_bytes: int, keep: int) -> None:
    if max_bytes <= 0 or keep <= 0:
        return
    try:
        if not path.exists() or path.stat().st_size <= max_bytes:
            return
    except OSError:
        return

    oldest = path.with_name(f"{path.name}.{keep}")
    try:
        oldest.unlink(missing_ok=True)
    except OSError:
        pass

    for idx in range(keep - 1, 0, -1):
        src = path.with_name(f"{path.name}.{idx}")
        dst = path.with_name(f"{path.name}.{idx + 1}")
        if src.exists():
            try:
                src.rename(dst)
            except OSError:
                pass

    try:
        path.rename(path.with_name(f"{path.name}.1"))
    except OSError:
        pass


class Logger:
    def __init__(
        self,
        *,
        log_file: pathlib.Path | None,
        verbose: bool = False,
        max_bytes: int = 0,
        keep: int = 0,
        prefix: str = "",
    ) -> None:
        self._log_file = log_file
        self._verbose = verbose
        self._max_bytes = max_bytes
        self._keep = keep
        self._prefix = prefix

    def log(self, message: str) -> None:
        ts = time.strftime("%Y-%m-%dT%H:%M:%S")
        line = f"{ts} {self._prefix}{message}".rstrip()
        print(line, flush=True)
        if self._log_file is None:
            return
        try:
            self._log_file.parent.mkdir(parents=True, exist_ok=True)
        except OSError:
            return
        try:
            rotate_log_file(self._log_file, self._max_bytes, self._keep)
            with self._log_file.open("a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError:
            pass

    def logv(self, message: str) -> None:
        if self._verbose:
            self.log(message)

