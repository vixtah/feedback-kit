"""FastAPI routes for shake-to-report; the app mounts the router under its own prefix."""

from __future__ import annotations

import asyncio
import base64
import binascii
import inspect
import logging
from collections.abc import Callable
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field

from feedback_kit.store import MAX_SCREENSHOT, STATUSES, FeedbackStore

log = logging.getLogger(__name__)

MAX_TEXT = 4000
MAX_DIAGNOSTICS = 64 * 1024


class FeedbackIn(BaseModel):
    kind: Literal["bug", "idea"]
    text: str = Field(min_length=1, max_length=MAX_TEXT)
    context: dict[str, str] = Field(default_factory=dict)
    diagnostics: str | None = Field(default=None, max_length=MAX_DIAGNOSTICS)
    screenshot: str | None = None  # base64 JPEG


class FeedbackStatusIn(BaseModel):
    status: Literal[STATUSES]  # type: ignore[valid-type]
    note: str | None = None


async def _call(fn: Callable, *args) -> Any:
    """Run a sync hook off the event loop, or await an async one."""
    if inspect.iscoroutinefunction(fn):
        return await fn(*args)
    result = await asyncio.to_thread(fn, *args)
    return await result if inspect.isawaitable(result) else result


def feedback_router(store: FeedbackStore, *, submit_auth: Callable, admin_auth: Callable,
                    on_new: Callable[[dict], Any] | None = None,
                    reporter_from: Callable[[Request], str | None] | None = None,
                    player_from: Callable[[Request], str | None] | None = None) -> APIRouter:
    """The feedback routes over ``store``.

    ``submit_auth`` guards ``POST /feedback``; ``admin_auth`` guards reading reports and
    changing their status. Both are FastAPI dependencies (raise ``HTTPException`` to
    refuse). ``reporter_from(request)`` / ``player_from(request)`` fill the report's
    ``reporter`` / ``player`` columns (sync or async). ``on_new(report)`` runs after each
    insert with the stored report (as ``GET /feedback/{id}`` answers it); its exceptions
    are logged, never raised.
    """
    router = APIRouter()
    admin = [Depends(admin_auth)]

    @router.post("/feedback", dependencies=[Depends(submit_auth)])
    async def send_feedback(body: FeedbackIn, request: Request):
        text = body.text.strip()
        if not text:
            raise HTTPException(422, "text is empty")
        shot = None
        if body.screenshot:
            try:
                shot = base64.b64decode(body.screenshot, validate=True)
            except (binascii.Error, ValueError) as e:
                raise HTTPException(400, "screenshot must be base64") from e
            if len(shot) > MAX_SCREENSHOT:
                raise HTTPException(413, "screenshot too large")
        reporter = await _call(reporter_from, request) if reporter_from else None
        player = await _call(player_from, request) if player_from else None
        item_id = await asyncio.to_thread(
            store.add, kind=body.kind, text=text, context=body.context,
            screenshot=shot, diagnostics=body.diagnostics, player=player, reporter=reporter)
        log.info("feedback #%s (%s) from %s", item_id, body.kind, reporter or player or "?")
        if on_new is not None:
            try:
                await _call(on_new, await asyncio.to_thread(store.get, item_id))
            except Exception:  # noqa: BLE001 (a forwarding hook never loses the report)
                log.exception("feedback on_new hook failed for #%s", item_id)
        return {"id": item_id}

    @router.get("/feedback", dependencies=admin)
    async def list_feedback(status: Literal[STATUSES] | None = None,  # type: ignore[valid-type]
                            limit: int = Query(100, ge=1, le=500)):
        return await asyncio.to_thread(store.list, status, limit)

    @router.get("/feedback/{item_id}", dependencies=admin)
    async def get_feedback(item_id: int):
        item = await asyncio.to_thread(store.get, item_id)
        if item is None:
            raise HTTPException(404, "no such report")
        return item

    @router.get("/feedback/{item_id}/screenshot", dependencies=admin)
    async def feedback_screenshot(item_id: int):
        shot = await asyncio.to_thread(store.screenshot, item_id)
        if not shot:
            raise HTTPException(404, "no screenshot")
        return Response(shot, media_type="image/jpeg")

    @router.post("/feedback/{item_id}/status", dependencies=admin)
    async def set_feedback_status(item_id: int, body: FeedbackStatusIn):
        if not await asyncio.to_thread(store.set_status, item_id, body.status, body.note):
            raise HTTPException(404, "no such report")
        return await asyncio.to_thread(store.get, item_id)

    return router
