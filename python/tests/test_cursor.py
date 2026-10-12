from fastapi import FastAPI
from fastapi.testclient import TestClient

from feedback_kit import FeedbackStore, feedback_router


def test_delivery_cursor_survives_new_inserts_and_status_changes(tmp_path):
    store = FeedbackStore(tmp_path / "reports.db")
    ids = [store.add(kind="bug",text=f"report {i}") for i in range(5)]
    app = FastAPI()
    app.include_router(feedback_router(store, submit_auth=lambda:None, admin_auth=lambda:None))
    client = TestClient(app)
    first = client.get('/feedback?after=0&limit=2').json()
    assert [r['id'] for r in first] == ids[:2]
    store.set_status(ids[2], "done")
    added = store.add(kind="bug",text="new concurrent report")
    second = client.get(f'/feedback?after={ids[1]}&limit=500').json()
    assert [r['id'] for r in second] == [*ids[2:],added]
    assert client.get('/feedback?after=0&status=open').status_code == 422
    assert client.get('/feedback?after=-1').status_code == 422
    assert [r['id'] for r in client.get('/feedback?limit=2').json()] == [added,ids[-1]]
