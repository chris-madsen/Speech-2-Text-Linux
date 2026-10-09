#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
import sqlite3
import uuid
from pathlib import Path


def now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def backup(path: Path, tag: str) -> Path:
    stamp = now_utc().strftime("%Y%m%d-%H%M%S")
    dst = path.with_name(f"{path.name}.{tag}-{stamp}")
    shutil.copy2(path, dst)
    return dst


def load_index(index_path: Path) -> list[dict]:
    if not index_path.exists():
        return []
    out = []
    for line in index_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if isinstance(obj, dict):
                out.append(obj)
        except json.JSONDecodeError:
            pass
    return out


def save_index(index_path: Path, entries: list[dict]) -> None:
    index_path.write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in entries), encoding="utf-8")


def restore_in_place(
    con: sqlite3.Connection,
    index_path: Path,
    thread_id: str,
    bump_title_suffix: str = " [RESTORED]"
) -> None:
    cur = con.cursor()
    cur.execute("SELECT * FROM threads WHERE id = ?", (thread_id,))
    row = cur.fetchone()
    if not row:
        raise RuntimeError(f"Thread not found: {thread_id}")

    cols = [d[0] for d in cur.description]
    data = dict(zip(cols, row))

    now = now_utc()
    now_ms = int(now.timestamp() * 1000)
    now_s = int(now.timestamp())
    now_iso = now.isoformat().replace("+00:00", "Z")

    title = (data.get("title") or "Recovered thread").strip()
    if bump_title_suffix and bump_title_suffix not in title:
        title = f"{title}{bump_title_suffix}"

    cur.execute(
        """
        UPDATE threads
        SET archived = 0,
            updated_at_ms = ?,
            updated_at = ?,
            title = ?
        WHERE id = ?
        """,
        (now_ms, now_s, title, thread_id),
    )
    con.commit()

    entries = load_index(index_path)
    entries = [e for e in entries if e.get("id") != thread_id]
    entries.insert(0, {"id": thread_id, "thread_name": title, "updated_at": now_iso})
    save_index(index_path, entries)


def clone_thread(
    con: sqlite3.Connection,
    index_path: Path,
    sessions_root: Path,
    source_thread_id: str,
) -> str:
    cur = con.cursor()
    cur.execute("SELECT * FROM threads WHERE id = ?", (source_thread_id,))
    row = cur.fetchone()
    if not row:
        raise RuntimeError(f"Source thread not found: {source_thread_id}")

    cols = [d[0] for d in cur.description]
    src = dict(zip(cols, row))

    old_rollout = Path(src["rollout_path"] or "")
    if not old_rollout.exists():
        raise RuntimeError(f"Rollout file missing: {old_rollout}")

    new_id = str(uuid.uuid4())
    now = now_utc()
    now_ms = int(now.timestamp() * 1000)
    now_s = int(now.timestamp())
    now_iso = now.isoformat().replace("+00:00", "Z")

    rel_dir = old_rollout.parent
    new_rollout_name = f"rollout-{now.strftime('%Y-%m-%dT%H-%M-%S')}-{new_id}.jsonl"
    new_rollout = rel_dir / new_rollout_name

    lines = old_rollout.read_text(encoding="utf-8", errors="replace").splitlines()
    patched = []
    patched_meta = False
    for line in lines:
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            patched.append(line)
            continue
        if (
            not patched_meta
            and isinstance(obj, dict)
            and obj.get("type") == "session_meta"
            and isinstance(obj.get("payload"), dict)
        ):
            obj["payload"]["id"] = new_id
            patched_meta = True
        patched.append(json.dumps(obj, ensure_ascii=False))
    new_rollout.write_text("\n".join(patched) + "\n", encoding="utf-8")

    new_row = src.copy()
    new_row["id"] = new_id
    new_row["rollout_path"] = str(new_rollout)
    new_row["archived"] = 0
    new_row["archived_at"] = None
    new_row["updated_at_ms"] = now_ms
    new_row["updated_at"] = now_s
    new_row["created_at_ms"] = now_ms
    new_row["created_at"] = now_s
    base_title = (src.get("title") or "Recovered thread").strip()
    new_row["title"] = f"{base_title} [CLONE]"
    if "thread_source" in new_row:
        new_row["thread_source"] = "manual_restore_clone"

    insert_cols = list(new_row.keys())
    placeholders = ",".join("?" for _ in insert_cols)
    col_sql = ",".join(insert_cols)
    cur.execute(
        f"INSERT INTO threads ({col_sql}) VALUES ({placeholders})",
        tuple(new_row[c] for c in insert_cols),
    )
    con.commit()

    entries = load_index(index_path)
    entries = [e for e in entries if e.get("id") != new_id]
    entries.insert(0, {"id": new_id, "thread_name": new_row["title"], "updated_at": now_iso})
    save_index(index_path, entries)

    return new_id


def main() -> int:
    ap = argparse.ArgumentParser(description="Restore Codex thread in list; optionally clone if needed")
    ap.add_argument("--thread-id", required=True, help="Target thread id to restore")
    ap.add_argument("--clone", action="store_true", help="Also create a new clone thread copy")
    ap.add_argument("--codex-home", default=str(Path.home() / ".codex"))
    args = ap.parse_args()

    codex_home = Path(args.codex_home).expanduser()
    db_path = codex_home / "state_5.sqlite"
    idx_path = codex_home / "session_index.jsonl"
    sessions_root = codex_home / "sessions"

    if not db_path.exists():
        raise SystemExit(f"DB not found: {db_path}")

    db_bak = backup(db_path, "bak-restore-clone")
    idx_bak = backup(idx_path, "bak-restore-clone") if idx_path.exists() else None

    con = sqlite3.connect(str(db_path))
    try:
        restore_in_place(con, idx_path, args.thread_id)
        print(f"[OK] Restored in place: {args.thread_id}")

        if args.clone:
            new_id = clone_thread(con, idx_path, sessions_root, args.thread_id)
            print(f"[OK] Clone created: {new_id}")
    finally:
        con.close()

    print(f"[INFO] DB backup: {db_bak}")
    if idx_bak:
        print(f"[INFO] Index backup: {idx_bak}")
    print("[INFO] Nothing deleted.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
