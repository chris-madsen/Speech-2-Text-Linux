#!/usr/bin/env python3
"""Drain RabbitMQ S2T jobs into local file queue for dataset-etl daemon."""

from __future__ import annotations

import json
import os
import pathlib
import re
import tempfile
import time
from dataclasses import dataclass


@dataclass
class Config:
    queue_dir: pathlib.Path
    rabbit_url: str
    queue_name: str
    queue_type: str
    poll_sec: float
    reconnect_sec: float
    prefetch_count: int
    backend: str
    log_file: pathlib.Path
    log_verbose: bool
    log_max_bytes: int
    log_keep: int


_LOG_FILE: pathlib.Path | None = None
_LOG_VERBOSE: bool = False
_LOG_MAX_BYTES: int = 0
_LOG_KEEP: int = 0


def env_str(name: str, default: str) -> str:
    raw = os.environ.get(name, "").strip()
    return raw if raw else default


def env_int(name: str, default: int, minimum: int = 0) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value >= minimum else default


def env_float(name: str, default: float, minimum: float = 0.0) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        return default
    return value if value >= minimum else default


def env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    return raw in {"1", "true", "yes", "on"}


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


def configure_logging(cfg: Config) -> None:
    global _LOG_FILE, _LOG_VERBOSE, _LOG_MAX_BYTES, _LOG_KEEP
    _LOG_FILE = cfg.log_file
    _LOG_VERBOSE = cfg.log_verbose
    _LOG_MAX_BYTES = cfg.log_max_bytes
    _LOG_KEEP = cfg.log_keep
    try:
        cfg.log_file.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        _LOG_FILE = None


def log(message: str) -> None:
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    line = f"{ts} rabbitmq-drain: {message}"
    print(line, flush=True)
    if _LOG_FILE is None:
        return
    try:
        rotate_log_file(_LOG_FILE, _LOG_MAX_BYTES, _LOG_KEEP)
        with _LOG_FILE.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def logv(message: str) -> None:
    if _LOG_VERBOSE:
        log(message)


def load_config() -> Config:
    home = pathlib.Path.home()
    xdg_data = pathlib.Path(os.environ.get("XDG_DATA_HOME", str(home / ".local" / "share"))).expanduser()
    xdg_runtime = pathlib.Path(os.environ.get("XDG_RUNTIME_DIR", f"/tmp/s2t-{os.getuid()}"))
    dataset_root = pathlib.Path(env_str("S2T_DATASET_ROOT", str(xdg_data / "s2t" / "dataset"))).expanduser()

    return Config(
        queue_dir=pathlib.Path(env_str("S2T_DATASET_QUEUE_DIR", str(dataset_root / "queue"))).expanduser(),
        rabbit_url=env_str("S2T_RABBITMQ_URL", "amqp://s2t:s2t@127.0.0.1:5672/%2F"),
        queue_name=env_str("S2T_RABBITMQ_QUEUE", "s2t.dataset.jobs"),
        queue_type=env_str("S2T_RABBITMQ_QUEUE_TYPE", "classic").lower(),
        poll_sec=env_float("S2T_RABBITMQ_DRAIN_POLL_SEC", 0.25, minimum=0.05),
        reconnect_sec=env_float("S2T_RABBITMQ_DRAIN_RECONNECT_SEC", 2.0, minimum=0.2),
        prefetch_count=env_int("S2T_RABBITMQ_DRAIN_PREFETCH", 20, minimum=1),
        backend=env_str("S2T_QUEUE_BACKEND", "file").lower(),
        log_file=pathlib.Path(env_str("S2T_RABBITMQ_DRAIN_LOG_FILE", str(xdg_runtime / "s2t" / "rabbitmq-drain.log"))).expanduser(),
        log_verbose=env_bool("S2T_RABBITMQ_DRAIN_LOG_VERBOSE", True),
        log_max_bytes=env_int("S2T_RABBITMQ_DRAIN_LOG_MAX_BYTES", 1024 * 1024, minimum=4096),
        log_keep=env_int("S2T_RABBITMQ_DRAIN_LOG_KEEP", 3, minimum=1),
    )


def sanitize_sample_id(value: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    return safe[:120] if safe else "unknown"


def write_job_file(cfg: Config, payload: dict[str, object]) -> pathlib.Path:
    sample_id = sanitize_sample_id(str(payload["sample_id"]))
    queued_ms_raw = payload.get("queued_ms", int(time.time() * 1000))
    try:
        queued_ms = int(queued_ms_raw)
    except Exception:  # noqa: BLE001
        queued_ms = int(time.time() * 1000)

    cfg.queue_dir.mkdir(parents=True, exist_ok=True)

    base = f"{queued_ms}_{sample_id}"
    index = 0
    while True:
        suffix = "" if index == 0 else f"_{index}"
        dst = cfg.queue_dir / f"{base}{suffix}.job"
        if not dst.exists():
            break
        index += 1

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=cfg.queue_dir, delete=False) as tmp:
        tmp.write(f"sample_id={payload['sample_id']}\n")
        tmp.write(f"audio={payload['audio']}\n")
        tmp.write(f"text={payload['text']}\n")
        tmp.write(f"queued_ms={queued_ms}\n")
        tmp_path = pathlib.Path(tmp.name)

    tmp_path.replace(dst)
    return dst


def parse_payload(body: bytes) -> tuple[dict[str, object] | None, str]:
    try:
        data = json.loads(body.decode("utf-8", errors="replace"))
    except json.JSONDecodeError:
        return None, "invalid_json"
    if not isinstance(data, dict):
        return None, "invalid_type"

    required = ("sample_id", "audio", "text")
    for key in required:
        value = str(data.get(key, "")).strip()
        if not value:
            return None, f"missing_{key}"

    return data, ""


def run() -> int:
    cfg = load_config()
    configure_logging(cfg)

    if cfg.backend != "rabbitmq":
        log(f"queue backend is '{cfg.backend}', rabbitmq drain disabled")
        return 0

    try:
        import pika  # type: ignore
    except Exception as exc:  # noqa: BLE001
        log(f"pika import failed: {exc}")
        return 2

    queue_args: dict[str, object] = {}
    if cfg.queue_type in {"classic", "quorum"}:
        queue_args["x-queue-type"] = cfg.queue_type

    log(
        "started "
        f"queue_dir={cfg.queue_dir} rabbit_url={cfg.rabbit_url} queue={cfg.queue_name} "
        f"prefetch={cfg.prefetch_count} reconnect_sec={cfg.reconnect_sec}"
    )

    while True:
        connection = None
        channel = None
        try:
            params = pika.URLParameters(cfg.rabbit_url)
            params.heartbeat = 15
            params.blocked_connection_timeout = 5
            params.socket_timeout = 5

            connection = pika.BlockingConnection(params)
            channel = connection.channel()
            channel.queue_declare(queue=cfg.queue_name, durable=True, arguments=queue_args)
            channel.basic_qos(prefetch_count=cfg.prefetch_count)
            log("connected")

            while True:
                method, _props, body = channel.basic_get(queue=cfg.queue_name, auto_ack=False)
                if method is None:
                    time.sleep(cfg.poll_sec)
                    continue

                payload, error = parse_payload(body)
                if payload is None:
                    log(f"drop message reason={error} delivery_tag={method.delivery_tag}")
                    channel.basic_ack(delivery_tag=method.delivery_tag)
                    continue

                try:
                    job_path = write_job_file(cfg, payload)
                except OSError as exc:
                    log(f"failed to materialize job: {exc}; requeue delivery_tag={method.delivery_tag}")
                    channel.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
                    time.sleep(0.2)
                    continue

                channel.basic_ack(delivery_tag=method.delivery_tag)
                logv(f"queued job file={job_path}")

        except KeyboardInterrupt:
            log("stopped by signal")
            return 0
        except Exception as exc:  # noqa: BLE001
            log(f"connection loop error: {exc}; reconnect in {cfg.reconnect_sec}s")
            time.sleep(cfg.reconnect_sec)
        finally:
            if channel is not None:
                try:
                    channel.close()
                except Exception:  # noqa: BLE001
                    pass
            if connection is not None:
                try:
                    connection.close()
                except Exception:  # noqa: BLE001
                    pass


def main() -> int:
    return run()


if __name__ == "__main__":
    raise SystemExit(main())
