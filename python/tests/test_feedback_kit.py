import base64
import sqlite3

import pytest
from fastapi import FastAPI, Header, HTTPException
from fastapi.testclient import TestClient
from feedback_kit import (
    MAX_SCREENSHOT,
    FeedbackStore,
    ScreenshotTooLarge,
    feedback_router,
)
from feedback_kit.cli import main as cli

JPEG = b"\xff\xd8\xff\xe0fake-jpeg"
RIFTBOUND_DDL = (
    "CREATE TABLE feedback (id INTEGER PRIMARY KEY AUTOINCREMENT, "
    "created_at TEXT NOT NULL, player TEXT, reporter TEXT, kind TEXT NOT NULL, text TEXT NOT NULL, "
    "context TEXT NOT NULL DEFAULT '{}', screenshot BLOB, status TEXT NOT NULL DEFAULT 'open', "
    "note TEXT, updated_at TEXT NOT NULL)"
)


@pytest.fixture
def store(tmp_path):
    return FeedbackStore(tmp_path / "fb.db")


def _submit_auth(x_app_token: str | None = Header(default=None)):
    if x_app_token != "app":
        raise HTTPException(401, "bad token")


def _admin_auth(x_admin: str | None = Header(default=None)):
    if x_admin != "yes":
        raise HTTPException(403, "admin only")


def _client(store, **kw):
    app = FastAPI()
    app.include_router(feedback_router(store, submit_auth=_submit_auth, admin_auth=_admin_auth,
                                       **kw), prefix="/api/x")
    return TestClient(app)


APP = {"X-App-Token": "app"}
ADMIN = {"X-Admin": "yes"}


# --- store -------------------------------------------------------------------


def test_store_roundtrip(store):
    a = store.add(kind="bug", text="it broke", context={"screen": "Today"}, screenshot=JPEG,
                  diagnostics="GET /x 500", reporter="vic")
    b = store.add(kind="idea", text="dark mode")
    assert [r["id"] for r in store.list()] == [b, a]
    item = store.get(a)
    assert item["context"] == {"screen": "Today"}
    assert item["has_screenshot"] and item["has_diagnostics"]
    assert item["diagnostics"] == "GET /x 500"
    assert item["status"] == "open" and item["reporter"] == "vic"
    assert store.get(b)["has_screenshot"] is False and store.get(b)["diagnostics"] is None
    assert "diagnostics" not in store.list()[0]
    assert store.screenshot(a) == JPEG and store.screenshot(b) is None
    assert store.get(999) is None and store.screenshot(999) is None


def test_store_status_and_filter(store):
    a = store.add(kind="bug", text="one")
    store.add(kind="bug", text="two")
    assert store.set_status(a, "planned", "next week")
    assert store.set_status(a, "done")  # note kept when not given
    item = store.get(a)
    assert (item["status"], item["note"]) == ("done", "next week")
    assert [r["id"] for r in store.list("done")] == [a]
    assert len(store.list(limit=1)) == 1
    assert not store.set_status(999, "done")
    with pytest.raises(ValueError):
        store.set_status(a, "closed")


def test_store_caps(store):
    with pytest.raises(ScreenshotTooLarge):
        store.add(kind="bug", text="x", screenshot=b"\0" * (MAX_SCREENSHOT + 1))
    with pytest.raises(ValueError):
        store.add(kind="rant", text="x")
    i = store.add(kind="bug", text="x", context={f"k{n}": "v" for n in range(40)})
    assert len(store.get(i)["context"]) == 30


def test_store_adds_diagnostics_to_riftbound_table(tmp_path):
    path = tmp_path / "game.db"
    with sqlite3.connect(path) as conn:
        conn.execute(RIFTBOUND_DDL)
        conn.execute("INSERT INTO feedback(created_at, kind, text, updated_at) "
                     "VALUES ('2026-10-01T00:00:00+00:00', 'bug', 'old report', 'now')")
    store = FeedbackStore(path)
    old = store.get(1)
    assert old["text"] == "old report" and old["diagnostics"] is None
    new = store.add(kind="idea", text="new", diagnostics="log")
    assert store.get(new)["diagnostics"] == "log"
    FeedbackStore(path)  # reopening an upgraded table is a no-op
    with sqlite3.connect(path) as conn:
        cols = [r[1] for r in conn.execute("PRAGMA table_info(feedback)")]
    assert cols.count("request_id") == 1 and cols.count("diagnostics") == 1


# --- routes ------------------------------------------------------------------


def test_submit_and_review(store):
    c = _client(store, reporter_from=lambda req: req.headers.get("x-user"))
    body = {"kind": "bug", "text": "  crash on Today  ", "context": {"screen": "Today"},
            "diagnostics": "line", "screenshot": base64.b64encode(JPEG).decode()}
    r = c.post("/api/x/feedback", json=body, headers=APP | {"X-User": "vic"})
    assert r.status_code == 200, r.text
    item_id = r.json()["id"]

    got = c.get(f"/api/x/feedback/{item_id}", headers=ADMIN).json()
    assert got["text"] == "crash on Today" and got["reporter"] == "vic"
    assert got["diagnostics"] == "line" and got["has_screenshot"]
    shot = c.get(f"/api/x/feedback/{item_id}/screenshot", headers=ADMIN)
    assert shot.content == JPEG and shot.headers["content-type"] == "image/jpeg"

    assert [i["id"] for i in c.get("/api/x/feedback?status=open", headers=ADMIN).json()] == [item_id]
    assert c.get("/api/x/feedback?status=done", headers=ADMIN).json() == []
    r = c.post(f"/api/x/feedback/{item_id}/status", json={"status": "done", "note": "fixed"},
               headers=ADMIN)
    assert r.json()["status"] == "done" and r.json()["note"] == "fixed"


def test_auth_dependencies(store):
    c = _client(store)
    body = {"kind": "idea", "text": "hi"}
    assert c.post("/api/x/feedback", json=body).status_code == 401
    item_id = c.post("/api/x/feedback", json=body, headers=APP).json()["id"]
    for path in ("/api/x/feedback", f"/api/x/feedback/{item_id}",
                 f"/api/x/feedback/{item_id}/screenshot"):
        assert c.get(path, headers=APP).status_code == 403, path
    r = c.post(f"/api/x/feedback/{item_id}/status", json={"status": "done"}, headers=APP)
    assert r.status_code == 403
    assert store.get(item_id)["status"] == "open"


def test_validation_and_404s(store):
    c = _client(store)
    post = lambda body: c.post("/api/x/feedback", json=body, headers=APP)
    assert post({"kind": "rant", "text": "x"}).status_code == 422
    assert post({"kind": "bug", "text": ""}).status_code == 422
    assert post({"kind": "bug", "text": "   "}).status_code == 422
    assert post({"kind": "bug", "text": "x" * 4001}).status_code == 422
    assert post({"kind": "bug", "text": "x", "diagnostics": "d" * (64 * 1024 + 1)}).status_code == 422
    assert post({"kind": "bug", "text": "x", "screenshot": "not base64!"}).status_code == 400
    assert c.get("/api/x/feedback/5", headers=ADMIN).status_code == 404
    assert c.get("/api/x/feedback/5/screenshot", headers=ADMIN).status_code == 404
    assert c.post("/api/x/feedback/5/status", json={"status": "done"},
                  headers=ADMIN).status_code == 404
    item_id = post({"kind": "bug", "text": "x"}).json()["id"]
    assert c.get(f"/api/x/feedback/{item_id}/screenshot", headers=ADMIN).status_code == 404
    assert c.post(f"/api/x/feedback/{item_id}/status", json={"status": "closed"},
                  headers=ADMIN).status_code == 422
    assert c.get("/api/x/feedback?status=closed", headers=ADMIN).status_code == 422


def test_screenshot_size_cap(store):
    c = _client(store)
    big = base64.b64encode(b"\0" * (MAX_SCREENSHOT + 1)).decode()
    r = c.post("/api/x/feedback", json={"kind": "bug", "text": "x", "screenshot": big}, headers=APP)
    assert r.status_code == 413
    assert store.list() == []
    ok = base64.b64encode(b"\0" * MAX_SCREENSHOT).decode()
    r = c.post("/api/x/feedback", json={"kind": "bug", "text": "x", "screenshot": ok}, headers=APP)
    assert r.status_code == 200


def test_on_new_gets_report_and_failures_are_logged(store, caplog):
    seen = []
    c = _client(store, on_new=seen.append, player_from=lambda req: "p1")
    r = c.post("/api/x/feedback", json={"kind": "idea", "text": "more decks"}, headers=APP)
    assert seen == [store.get(r.json()["id"])] and seen[0]["player"] == "p1"

    async def boom(report):
        raise RuntimeError("forwarding down")

    c = _client(store, on_new=boom)
    r = c.post("/api/x/feedback", json={"kind": "bug", "text": "still saved"}, headers=APP)
    assert r.status_code == 503 and store.list()[0]["text"] == "still saved"
    assert "on_new hook failed" in caplog.text


# --- CLI -----------------------------------------------------------------------


def test_cli(store, tmp_path, capsys):
    db = str(store.db_path)
    a = store.add(kind="bug", text="first line\nmore", screenshot=JPEG, diagnostics="diag",
                  reporter="vic")
    store.add(kind="idea", text="an idea")
    cli(["--db", db, "list"])
    out = capsys.readouterr().out
    assert f"#{a}" in out and "first line" in out and "[screenshot]" in out and "an idea" in out

    cli(["--db", db, "status", str(a), "done", "--note", "fixed in abc"])
    assert "done" in capsys.readouterr().out
    cli(["--db", db, "list", "--status", "open"])
    assert "first line" not in capsys.readouterr().out

    shot = tmp_path / "out" / "a.jpg"
    cli(["--db", db, "show", str(a), "--screenshot-out", str(shot)])
    out = capsys.readouterr().out
    assert "more" in out and "note: fixed in abc" in out and "diag" in out
    assert shot.read_bytes() == JPEG

    with pytest.raises(SystemExit):
        cli(["--db", db, "show", "999"])
    with pytest.raises(SystemExit):
        cli(["--db", db, "status", "999", "done"])
    with pytest.raises(SystemExit):
        cli(["--db", str(tmp_path / "missing.db"), "list"])


def test_retry_after_forwarding_failure_is_idempotent(store):
    calls = []
    def forward(report):
        calls.append(report["id"])
        if len(calls) == 1:
            raise RuntimeError("temporarily down")
    client = _client(store, on_new=forward)
    payload = {"kind": "bug", "text": "only once", "requestID": "stable-id"}
    assert client.post("/api/x/feedback", json=payload, headers=APP).status_code == 503
    result = client.post("/api/x/feedback", json=payload, headers=APP)
    assert result.status_code == 200
    assert calls == [result.json()["id"], result.json()["id"]]
    assert len(store.list()) == 1


def test_host_connection_factory_preserves_database_boundary(tmp_path):
    from contextlib import contextmanager
    calls = []
    conn = sqlite3.connect(":memory:")
    @contextmanager
    def owned_connection():
        calls.append(True)
        with conn:
            yield conn
    unused_path = tmp_path / "must-not-be-opened" / "app.db"
    store = FeedbackStore(unused_path, connection_factory=owned_connection)
    rid = store.add(kind="bug", text="guarded storage")
    assert store.get(rid)["text"] == "guarded storage"
    assert len(calls) == 3 and not unused_path.parent.exists()
    conn.close()
