#!/usr/bin/env python3
"""Extract iMessage history from chat.db into clean normalized JSON.

Usage:
    python3 extract.py [path/to/chat.db] [-o output.json]

Defaults to ~/Library/Messages/chat.db. Copies db+wal+shm to a temp dir
first (never touches the live store), checkpoints the WAL on the copy so
recent messages are included, decodes attributedBody typedstream blobs
(where modern message text lives), converts Apple-epoch-nanosecond
timestamps to ISO-8601, and groups messages by conversation.
"""

import argparse
import json
import re
import shutil
import sqlite3
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

APPLE_EPOCH_OFFSET = 978307200  # 2001-01-01 UTC in unix seconds


def apple_ns_to_iso(ns):
    if not ns:
        return None
    # Older macOS stored seconds, not nanoseconds; disambiguate by magnitude.
    secs = ns / 1e9 if ns > 1e12 else ns
    return datetime.fromtimestamp(secs + APPLE_EPOCH_OFFSET, tz=timezone.utc).isoformat()


def decode_attributed_body(blob):
    """Pull the message string out of a serialized NSAttributedString.

    The blob is Apple typedstream. The message text is the first NSString
    payload: after the b"NSString" class marker comes b"\x01\x94\x84\x01"
    then '+' (0x2b), then the length (one byte, or 0x81 + uint16-LE for
    long strings), then the UTF-8 bytes.
    """
    if not blob:
        return None
    idx = blob.find(b"NSString")
    if idx == -1:
        return None
    # skip class name + the 5 marker bytes up to and including '+'
    start = idx + len(b"NSString") + 5
    if start >= len(blob):
        return None
    length_byte = blob[start]
    if length_byte == 0x81:  # two-byte little-endian length follows
        strlen = int.from_bytes(blob[start + 1:start + 3], "little")
        text_start = start + 3
    elif length_byte == 0x82:  # four-byte length (very long messages)
        strlen = int.from_bytes(blob[start + 1:start + 5], "little")
        text_start = start + 5
    else:
        strlen = length_byte
        text_start = start + 1
    raw = blob[text_start:text_start + strlen]
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("utf-8", errors="replace")


# associated_message_type: 0 = normal, 2000-2005 = tapbacks, 3000+ = removals
TAPBACKS = {
    2000: "loved", 2001: "liked", 2002: "disliked",
    2003: "laughed", 2004: "emphasized", 2005: "questioned",
}


def snapshot_db(db_path):
    """Copy db (+wal/+shm if present) to a temp dir and checkpoint the WAL."""
    tmp = Path(tempfile.mkdtemp(prefix="chatdb_"))
    dest = tmp / "chat.db"
    shutil.copy2(db_path, dest)
    for suffix in ("-wal", "-shm"):
        side = Path(str(db_path) + suffix)
        if side.exists():
            shutil.copy2(side, str(dest) + suffix)
    con = sqlite3.connect(dest)
    con.execute("PRAGMA wal_checkpoint(TRUNCATE);")
    con.close()
    return tmp, dest


def extract(db_path):
    tmp, snap = snapshot_db(db_path)
    try:
        con = sqlite3.connect(f"file:{snap}?mode=ro", uri=True)
        con.row_factory = sqlite3.Row

        chats = {}
        for row in con.execute("""
            SELECT c.ROWID AS chat_rowid, c.chat_identifier, c.display_name,
                   c.style  -- 43 = group, 45 = 1:1
            FROM chat c
        """):
            participants = [
                r["id"] for r in con.execute("""
                    SELECT h.id FROM chat_handle_join chj
                    JOIN handle h ON h.ROWID = chj.handle_id
                    WHERE chj.chat_id = ? ORDER BY h.id
                """, (row["chat_rowid"],))
            ]
            chats[row["chat_rowid"]] = {
                "chat_identifier": row["chat_identifier"],
                "display_name": row["display_name"] or None,
                "is_group": row["style"] == 43,
                "participants": participants,
                "messages": [],
            }

        n_blob_decoded = 0
        for row in con.execute("""
            SELECT cmj.chat_id AS chat_rowid,
                   m.ROWID AS msg_rowid, m.guid, m.date, m.is_from_me,
                   m.text, m.attributedBody, m.associated_message_type,
                   m.cache_has_attachments, m.item_type,
                   h.id AS sender
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            ORDER BY m.date
        """):
            text = row["text"]
            if not text and row["attributedBody"]:
                text = decode_attributed_body(row["attributedBody"])
                if text:
                    n_blob_decoded += 1
            assoc = row["associated_message_type"] or 0
            msg = {
                "ts": apple_ns_to_iso(row["date"]),
                "from": "me" if row["is_from_me"] else (row["sender"] or "unknown"),
                "text": text,
            }
            if assoc in TAPBACKS:
                msg["tapback"] = TAPBACKS[assoc]
            elif assoc >= 3000:
                msg["tapback_removed"] = True
            if row["cache_has_attachments"]:
                msg["has_attachment"] = True
            if row["item_type"]:  # group renames, member add/remove, etc.
                msg["system_event"] = True
            chat = chats.get(row["chat_rowid"])
            if chat is not None:
                chat["messages"].append(msg)

        con.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    out_chats = sorted(chats.values(), key=lambda c: len(c["messages"]), reverse=True)
    return {
        "extracted_at": datetime.now(tz=timezone.utc).isoformat(),
        "source": str(db_path),
        "stats": {
            "chats": len(out_chats),
            "messages": sum(len(c["messages"]) for c in out_chats),
            "text_recovered_from_attributedBody": n_blob_decoded,
        },
        "chats": out_chats,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("db", nargs="?",
                    default=str(Path.home() / "Library/Messages/chat.db"))
    ap.add_argument("-o", "--output", default="messages.json")
    args = ap.parse_args()

    db_path = Path(args.db).expanduser()
    if not db_path.exists():
        sys.exit(f"error: {db_path} not found")

    result = extract(db_path)
    Path(args.output).write_text(
        json.dumps(result, ensure_ascii=False, indent=2))
    s = result["stats"]
    print(f"{s['messages']} messages across {s['chats']} chats -> {args.output}"
          f" ({s['text_recovered_from_attributedBody']} texts recovered from attributedBody)")


if __name__ == "__main__":
    main()
