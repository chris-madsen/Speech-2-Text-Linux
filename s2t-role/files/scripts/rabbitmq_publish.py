#!/usr/bin/env python3
"""Publish S2T dataset queue jobs to RabbitMQ with durable delivery."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time


def env_str(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value if value else default


def env_int(name: str, default: int, minimum: int = 0) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value >= minimum else default


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Publish one S2T ETL job to RabbitMQ.")
    parser.add_argument("--sample-id", required=True)
    parser.add_argument("--audio", required=True)
    parser.add_argument("--text", required=True)
    parser.add_argument("--queued-ms", type=int, default=0)
    return parser.parse_args()


def load_pika():
    try:
        import pika  # type: ignore
    except Exception as exc:  # noqa: BLE001
        print(f"pika import failed: {exc}", file=sys.stderr)
        return None
    return pika


def build_payload(args: argparse.Namespace) -> dict[str, object]:
    queued_ms = args.queued_ms if args.queued_ms > 0 else int(time.time() * 1000)
    return {
        "sample_id": args.sample_id,
        "audio": args.audio,
        "text": args.text,
        "queued_ms": queued_ms,
    }


def main() -> int:
    args = parse_args()
    pika = load_pika()
    if pika is None:
        return 2

    rabbit_url = env_str("S2T_RABBITMQ_URL", "amqp://s2t:s2t@127.0.0.1:5672/%2F")
    queue_name = env_str("S2T_RABBITMQ_QUEUE", "s2t.dataset.jobs")
    exchange = env_str("S2T_RABBITMQ_EXCHANGE", "")
    routing_key = env_str("S2T_RABBITMQ_ROUTING_KEY", queue_name)
    queue_type = env_str("S2T_RABBITMQ_QUEUE_TYPE", "classic").lower()
    retries = env_int("S2T_RABBITMQ_PUBLISH_RETRIES", 2, minimum=1)
    retry_delay_ms = env_int("S2T_RABBITMQ_PUBLISH_RETRY_DELAY_MS", 100, minimum=0)
    socket_timeout = float(env_int("S2T_RABBITMQ_SOCKET_TIMEOUT_SEC", 1, minimum=1))

    payload = build_payload(args)
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    message_id = f"{args.sample_id}:{payload['queued_ms']}"

    queue_args: dict[str, object] = {}
    if queue_type in {"classic", "quorum"}:
        queue_args["x-queue-type"] = queue_type

    last_error = "unknown"
    for attempt in range(1, retries + 1):
        connection = None
        try:
            params = pika.URLParameters(rabbit_url)
            params.heartbeat = max(int(socket_timeout), 5)
            params.blocked_connection_timeout = socket_timeout
            params.socket_timeout = socket_timeout
            connection = pika.BlockingConnection(params)
            channel = connection.channel()
            channel.queue_declare(queue=queue_name, durable=True, arguments=queue_args)
            channel.confirm_delivery()
            ok = channel.basic_publish(
                exchange=exchange,
                routing_key=routing_key,
                body=body,
                properties=pika.BasicProperties(
                    content_type="application/json",
                    delivery_mode=2,
                    message_id=message_id,
                    timestamp=int(time.time()),
                ),
                mandatory=True,
            )
            if not ok:
                raise RuntimeError("publish did not receive broker confirm")
            return 0
        except Exception as exc:  # noqa: BLE001
            last_error = str(exc)
            if attempt >= retries:
                break
            if retry_delay_ms > 0:
                time.sleep(retry_delay_ms / 1000.0)
        finally:
            if connection is not None:
                try:
                    connection.close()
                except Exception:  # noqa: BLE001
                    pass

    print(f"rabbitmq publish failed after {retries} attempts: {last_error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
