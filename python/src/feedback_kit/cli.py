"""Review shake-to-report bug reports and ideas.

    python -m feedback_kit --db PATH list [--status open] [--limit 100]
    python -m feedback_kit --db PATH show 12 [--screenshot-out /tmp/12.jpg]
    python -m feedback_kit --db PATH status 12 done [--note "fixed in 4ecfbd1a"]

Statuses: open, planned, done, wontfix.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from feedback_kit.store import STATUSES, FeedbackStore


def _line(item: dict) -> str:
    who = item["reporter"] or (item["player"] or "?")[:8]
    first = (item["text"].splitlines() or [""])[0][:90]
    shot = " [screenshot]" if item["has_screenshot"] else ""
    return (f"#{item['id']:<4} {item['kind']:<4} {item['status']:<8} "
            f"{item['created_at'][:16]}  {who:<10} {first}{shot}")


def _show(store: FeedbackStore, item_id: int, screenshot_out: str | None) -> None:
    item = store.get(item_id)
    if item is None:
        raise SystemExit(f"no report #{item_id}")
    print(_line(item))
    print()
    print(item["text"])
    print()
    print(json.dumps(item["context"], indent=2))
    if item["note"]:
        print(f"\nnote: {item['note']}")
    if item["diagnostics"]:
        print(f"\ndiagnostics:\n{item['diagnostics']}")
    if screenshot_out:
        shot = store.screenshot(item_id)
        if not shot:
            print("\nno screenshot")
        else:
            path = Path(screenshot_out)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(shot)
            print(f"\nscreenshot: {path}")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="feedback_kit", description=__doc__.splitlines()[0])
    parser.add_argument("--db", required=True, help="the SQLite database holding `feedback`")
    sub = parser.add_subparsers(dest="cmd", required=True)
    list_ = sub.add_parser("list", help="reports, newest first")
    list_.add_argument("--status", choices=STATUSES, help="only this status (default: all)")
    list_.add_argument("--limit", type=int, default=100)
    show = sub.add_parser("show", help="one report in full")
    show.add_argument("id", type=int)
    show.add_argument("--screenshot-out", metavar="PATH", help="write its screenshot here")
    status = sub.add_parser("status", help="set a report's status")
    status.add_argument("id", type=int)
    status.add_argument("status", choices=STATUSES)
    status.add_argument("--note")
    args = parser.parse_args(argv)

    if not Path(args.db).exists():
        raise SystemExit(f"no database at {args.db}")
    store = FeedbackStore(args.db)
    if args.cmd == "list":
        items = store.list(args.status, args.limit)
        print("\n".join(_line(i) for i in items) or "no reports")
    elif args.cmd == "show":
        _show(store, args.id, args.screenshot_out)
    else:
        if not store.set_status(args.id, args.status, args.note):
            raise SystemExit(f"no report #{args.id}")
        print(_line(store.get(args.id)))
