"""Shake-to-report bug reports and ideas: SQLite store, FastAPI routes and a review CLI."""

from feedback_kit.routes import FeedbackIn, FeedbackStatusIn, feedback_router
from feedback_kit.store import (
    KINDS,
    MAX_SCREENSHOT,
    STATUSES,
    FeedbackStore,
    ScreenshotTooLarge,
)

__version__ = "0.2.1"

__all__ = [
    "KINDS",
    "MAX_SCREENSHOT",
    "STATUSES",
    "FeedbackIn",
    "FeedbackStatusIn",
    "FeedbackStore",
    "ScreenshotTooLarge",
    "feedback_router",
]
