"""SQLite storage for shake-to-report bug reports and ideas.

The ``feedback`` table is Riftbound's schema plus a nullable ``diagnostics`` column,
added in place when an existing table lacks it, so an app's live database can be
pointed at :class:`FeedbackStore` as is.
"""

from __future__ import annotations

import json
import sqlite3
from contextlib import closing, contextmanager
from datetime import UTC, datetime
from pathlib import Path

STATUSES = ("open", "planned", "done", "wontfix")
KINDS = ("bug", "idea")
MAX_SCREENSHOT = 3 << 20  # bytes (decoded JPEG)
MAX_CONTEXT_KEYS = 30

_DDL = (
    "CREATE TABLE IF NOT EXISTS feedback (id INTEGER PRIMARY KEY AUTOINCREMENT, "
    "created_at TEXT NOT NULL, player TEXT, reporter TEXT, kind TEXT NOT NULL, text TEXT NOT NULL, "
    "context TEXT NOT NULL DEFAULT '{}', screenshot BLOB, status TEXT NOT NULL DEFAULT 'open', "
    "note TEXT, updated_at TEXT NOT NULL, diagnostics TEXT)"
)

_COLS = ("id, created_at, player, reporter, kind, text, context, screenshot IS NOT NULL, "
         "status, note, updated_at, diagnostics IS NOT NULL")


class ScreenshotTooLarge(ValueError):
    """The screenshot is over :data:`MAX_SCREENSHOT` bytes."""


def _now() -> str:
    return datetime.now(UTC).isoformat()


def _row(r) -> dict:
    return {"id": r[0], "created_at": r[1], "player": r[2], "reporter": r[3], "kind": r[4],
            "text": r[5], "context": json.loads(r[6]), "has_screenshot": bool(r[7]),
            "status": r[8], "note": r[9], "updated_at": r[10], "has_diagnostics": bool(r[11])}


class FeedbackStore:
    def __init__(self, db_path: str | Path, *, connection_factory=None):
        self.db_path = Path(db_path)
        self._connection_factory = connection_factory
        if connection_factory is None:
            self.db_path.parent.mkdir(parents=True, exist_ok=True)
        with self._db() as conn:
            conn.execute(_DDL)
            cols = {r[1] for r in conn.execute("PRAGMA table_info(feedback)")}
            for column in ("diagnostics", "request_id"):
                if column not in cols:
                    conn.execute(f"ALTER TABLE feedback ADD COLUMN {column} TEXT")
            conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS feedback_request_id "
                         "ON feedback(request_id) WHERE request_id IS NOT NULL")

    @contextmanager
    def _db(self):
        """A connection that commits (or rolls back) and closes at the end of a ``with``."""
        if self._connection_factory is not None:
            with self._connection_factory() as conn:
                yield conn
        else:
            with closing(sqlite3.connect(self.db_path, timeout=30)) as conn, conn:
                yield conn

    def add(self, *, kind: str, text: str, context: dict | None = None,
            screenshot: bytes | None = None, diagnostics: str | None = None,
            player: str | None = None, reporter: str | None = None,
            request_id: str | None = None) -> int:
        if kind not in KINDS:
            raise ValueError(f"kind must be one of {KINDS}")
        if screenshot is not None and len(screenshot) > MAX_SCREENSHOT:
            raise ScreenshotTooLarge(f"screenshot over {MAX_SCREENSHOT} bytes")
        context = dict(list((context or {}).items())[:MAX_CONTEXT_KEYS])
        stamp = _now()
        with self._db() as conn:
            if request_id:
                existing = conn.execute("SELECT id FROM feedback WHERE request_id=?",
                                        (request_id,)).fetchone()
                if existing:
                    return existing[0]
            cur = conn.execute(
                "INSERT OR IGNORE INTO feedback(created_at, player, reporter, kind, text, context, "
                "screenshot, updated_at, diagnostics, request_id) VALUES (?,?,?,?,?,?,?,?,?,?)",
                (stamp, player, reporter, kind, text, json.dumps(context), screenshot, stamp,
                 diagnostics, request_id))
            if cur.rowcount == 0:
                return conn.execute("SELECT id FROM feedback WHERE request_id=?",
                                        (request_id,)).fetchone()[0]
            return cur.lastrowid

    def list(self, status: str | None = None, limit: int = 100) -> list[dict]:
        """Reports newest first, optionally one status; no screenshot or diagnostics bodies."""
        where, args = ("WHERE status=?", [status]) if status else ("", [])
        with self._db() as conn:
            rows = conn.execute(f"SELECT {_COLS} FROM feedback {where} ORDER BY id DESC LIMIT ?",
                                [*args, limit]).fetchall()
        return [_row(r) for r in rows]

    def get(self, item_id: int) -> dict | None:
        """One report, with its diagnostics text (``None`` when it sent none)."""
        with self._db() as conn:
            r = conn.execute(f"SELECT {_COLS}, diagnostics FROM feedback WHERE id=?",
                             (item_id,)).fetchone()
        return _row(r) | {"diagnostics": r[12]} if r else None

    def since(self, after: int, limit: int = 100) -> list[dict]:
        """Stable oldest-first delivery cursor, independent of mutable report status.

        No diagnostics or screenshots are included. The consumer advances its cursor
        only after durably processing the page, so concurrent inserts cannot hide rows.
        """
        with self._db() as conn:
            rows = conn.execute(f"SELECT {_COLS} FROM feedback WHERE id>? ORDER BY id LIMIT ?",
                                (after, limit)).fetchall()
        return [_row(r) for r in rows]

    def screenshot(self, item_id: int) -> bytes | None:
        with self._db() as conn:
            r = conn.execute("SELECT screenshot FROM feedback WHERE id=?", (item_id,)).fetchone()
        return r[0] if r else None

    def set_status(self, item_id: int, status: str, note: str | None = None) -> bool:
        """Set the status (and the note, when given); False when there is no such report."""
        if status not in STATUSES:
            raise ValueError(f"status must be one of {STATUSES}")
        with self._db() as conn:
            return conn.execute(
                "UPDATE feedback SET status=?, note=COALESCE(?, note), updated_at=? WHERE id=?",
                (status, note, _now(), item_id)).rowcount > 0
