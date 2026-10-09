#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
import sqlite3
import sys
from pathlib import Path


def now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def backup_file(path: Path, suffix: str) -> Path:
    stamp = now_utc().strftime("%Y%m%d-%H%M%S")
    dst = path.with_name(f"{path.name}.{suffix}-{stamp}")
    shutil.copy2(path, dst)
    return dst


def pick_thread(cur: sqlite3.Cursor, thread_id: str | None, query: str | None) -> sqlite3.Row:
    if thread_id:
        cur.execute("SELECT * FROM threads WHERE id = ? LIMIT 1", (thread_id,))
        row = cur.fetchone()
        if row:
            return row
        raise RuntimeError(f"Thread not found by id: {thread_id}")

    if query:
        q = f"%{query}%"
        cur.execute(
            """
            SELECT *
            FROM threads
            WHERE title LIKE ? OR first_user_message LIKE ?
            ORDER BY updated_at_ms DESC
            LIMIT 1
            """,
            (q, q),
        )
        row = cur.fetchone()
        if row:
            return row
        raise RuntimeError(f"Thread not found by query: {query}")

    raise RuntimeError("Provide --thread-id or --query")


def parse_open_turns(rollout_path: Path) -> list[tuple[str, int]]:
    started: dict[str, int] = {}
    closed: set[str] = set()

    with rollout_path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            if obj.get("type") != "event_msg":
                continue
            payload = obj.get("payload", {})
            if not isinstance(payload, dict):
                continue

            et = payload.get("type")
            turn_id = payload.get("turn_id")
            if not turn_id:
                continue

            if et == "task_started":
                started[turn_id] = int(payload.get("started_at") or 0)
            elif et in {"task_complete", "turn_aborted"}:
                closed.add(turn_id)

    return [(tid, ts) for tid, ts in started.items() if tid not in closed]


def append_task_complete(rollout_path: Path, turn_id: str, completed_at_s: int) -> None:
    ts_iso = dt.datetime.fromtimestamp(completed_at_s, dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    event = {
        "timestamp": ts_iso,
        "type": "event_msg",
        "payload": {
            "type": "task_complete",
            "turn_id": turn_id,
            "last_agent_message": "[system] recovered unmatched open turn",
            "completed_at": completed_at_s,
            "duration_ms": 0,
            "interrupted": True,
            "recovery": "manual_stuck_turn_close",
        },
    }
    with rollout_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description="Close stuck Codex turn(s) WITHOUT deleting dialog")
    ap.add_argument("--thread-id", help="Exact thread id")
    ap.add_argument("--query", help="Substring to find in title/first_user_message")
    ap.add_argument("--codex-home", default=str(Path.home() / ".codex"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    codex_home = Path(args.codex_home).expanduser()
    db_path = codex_home / "state_5.sqlite"
    idx_path = codex_home / "session_index.jsonl"

    if not db_path.exists():
        print(f"ERROR: DB not found: {db_path}", file=sys.stderr)
        return 2

    con = sqlite3.connect(str(db_path))
    con.row_factory = sqlite3.Row
    cur = con.cursor()

    try:
        row = pick_thread(cur, args.thread_id, args.query)
    except RuntimeError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 3

    thread_id = row["id"]
    rollout_path = Path(row["rollout_path"] or "")

    print(f"Thread: {thread_id}")
    print(f"Title : {row['title']}")
    print(f"Rollout: {rollout_path}")

    if not rollout_path.exists():
        print(f"ERROR: rollout file not found: {rollout_path}", file=sys.stderr)
        return 4

    open_turns = parse_open_turns(rollout_path)
    print(f"Open turns found: {len(open_turns)}")
    for tid, ts in open_turns:
        print(f"  - {tid} started_at={ts}")

    if args.dry_run:
        return 0

    db_backup = backup_file(db_path, "bak-stuckfix")
    rollout_backup = backup_file(rollout_path, "bak-stuckfix")
    idx_backup = backup_file(idx_path, "bak-stuckfix") if idx_path.exists() else None

    now = now_utc()
    now_s = int(now.timestamp())
    now_ms = int(now.timestamp() * 1000)
    now_iso = now.isoformat().replace("+00:00", "Z")

    for tid, started_at in open_turns:
        completed_at = started_at if started_at > 0 else now_s
        append_task_complete(rollout_path, tid, completed_at)

    title = str(row["title"] or "Recovered dialog")
    cur.execute(
        "UPDATE threads SET archived=0, updated_at_ms=?, updated_at=? WHERE id=?",
        (now_ms, now_s, thread_id),
    )
    con.commit()
    con.close()

    if idx_path.exists():
        entries = []
        for line in idx_path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict):
                entries.append(obj)

        entries = [e for e in entries if e.get("id") != thread_id]
        entries.insert(0, {"id": thread_id, "thread_name": title, "updated_at": now_iso})
        idx_path.write_text("".join(json.dumps(e, ensure_ascii=False) + "\n" for e in entries), encoding="utf-8")

    print("Done.")
    print(f"DB backup     : {db_backup}")
    print(f"Rollout backup: {rollout_backup}")
    if idx_backup:
        print(f"Index backup  : {idx_backup}")
    print("Dialog was NOT deleted.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
