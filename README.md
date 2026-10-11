# feedback-kit

Shake-to-report for the apps, in two halves that share one contract:

- **`FeedbackKit`** (Swift package, iOS 17): shake the phone, a sheet opens over
  whatever is on screen, the user picks bug or idea, writes a note and optionally
  attaches a screenshot; the report goes to the app's server. Reports that can't be
  sent are queued on disk and retried on the next launch.
- **`feedback_kit`** (Python package in `python/`): a SQLite store, FastAPI routes the
  app mounts under its own prefix, and a review CLI.

Generalised from Riftbound's shake-to-report. The table is Riftbound's `feedback`
schema plus nullable `diagnostics` and `request_id` columns (added in place).
All four apps use this implementation, including Riftbound itself. Requests carry a
stable ID so a retry returns the original receipt; a successful response must contain
a valid receipt. Product identity, authentication and workflow hooks stay in each app.
Hooks may run again after a retry and must be idempotent; hook failure returns 503
while preserving the report.

## Swift: `FeedbackKit`

XcodeGen `project.yml`:

```yaml
packages:
  FeedbackKit:
    url: https://github.com/vixtah/feedback-kit
    exactVersion: 0.2.0
targets:
  MyApp:
    dependencies:
      - package: FeedbackKit
```

Attach the reporter once, at the root view:

```swift
import FeedbackKit

ContentView()
    .feedbackReporter(config: FeedbackConfig(
        appID: "taskmanager",
        baseURL: URL(string: "https://host/api")!,          // reports go to {baseURL}/feedback
        headers: { ["X-App-Token": Keychain.token ?? ""] },
        screen: { router.currentScreenName },               // e.g. "Today", "task 123"
        diagnostics: { NetworkLog.shared.lastMinutes(2) },  // optional, capped at 64 KB
        buildSHAInfoKey: "TaskManagerBuildSHA",             // Info.plist key with the git SHA
        reporter: { account.displayName }))                 // optional
```

- A shake anywhere opens the sheet: FeedbackKit overrides `UIWindow.motionEnded`
  and posts `Notification.Name.feedbackKitDeviceShaken`. Remove any
  `motionEnded` override of your own. Post the notification yourself to open the
  sheet from a button.
- The screenshot is the key window at 1.5× scale, sent as JPEG at quality 0.6.
- Unsent reports live in `Application Support/FeedbackKit/queue/*.json`, at most 20
  (the oldest is dropped). The modifier retries them when the root view appears, and
  again each time the sheet opens. Reports the server refuses (4xx other than
  401/403/408/429) are not queued. Authentication failures remain queued until sign-in is repaired.
- The pieces are public on their own: `FeedbackClient` (an actor; injectable
  `URLSession` and `FeedbackQueue`), `FeedbackPayload`, `FeedbackContext`,
  `FeedbackSheet`, and `FeedbackReporter.shared.present(config:)`.

Tests: `xcodebuild test -scheme FeedbackKit -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0'`.
They never touch the network (a stub `URLProtocol` answers).

## Python: `feedback_kit`

`pyproject.toml`:

```toml
[project]
dependencies = ["feedback-kit"]

[tool.uv.sources]
feedback-kit = { git = "https://github.com/vixtah/feedback-kit", tag = "v0.1.0", subdirectory = "python" }
```

Mount the routes:

```python
from fastapi import Header, HTTPException, Request
from feedback_kit import FeedbackStore, feedback_router

store = FeedbackStore("~/.local/share/myapp/app.db")

def submit_auth(x_app_token: str | None = Header(None)):
    if x_app_token != TOKEN:
        raise HTTPException(401)

def admin_auth(request: Request):
    if not is_owner(request):
        raise HTTPException(403)

app.include_router(feedback_router(
    store, submit_auth=submit_auth, admin_auth=admin_auth,
    on_new=forward_to_request_queue,                # optional; errors are logged, not raised
    reporter_from=lambda req: token_name(req.headers.get("x-app-token")),  # optional
), prefix="/api")
```

`submit_auth` and `admin_auth` are FastAPI dependencies. `on_new(report)`,
`reporter_from(request)` and `player_from(request)` may be sync (run in a thread) or
async. `player_from` fills the `player` column (Riftbound's account id).

Review from a shell:

```
python -m feedback_kit --db PATH list [--status open] [--limit 100]
python -m feedback_kit --db PATH show 12 [--screenshot-out /tmp/12.jpg]
python -m feedback_kit --db PATH status 12 done [--note "fixed in 4ecfbd1a"]
```

Tests: `cd python && uv run --with pytest --with httpx pytest -q`.

## The contract

`POST {prefix}/feedback` (`submit_auth`), JSON:

```json
{
  "kind": "bug",                      // "bug" | "idea"
  "text": "What happened…",           // 1–4000 characters, trimmed
  "context": {                        // string map, at most 30 keys kept
    "app": "taskmanager", "version": "1.4 (212)", "build": "4ecfbd1a",
    "ios": "26.0", "device": "iPhone17,1", "screen": "Today", "reporter": "vic"
  },
  "diagnostics": "…",                 // optional, at most 64 KB
  "screenshot": "/9j/4AAQ…"           // optional, base64 JPEG, at most 3 MB decoded
}
```

Answers `{"id": 12}`. 400 when `screenshot` isn't base64, 413 when it is over 3 MB,
422 for anything else invalid.

Admin routes (`admin_auth`):

| Route | Answer |
|---|---|
| `GET /feedback?status=&limit=` | newest first; `status` one of `open`, `planned`, `done`, `wontfix`; `limit` 1–500 (100) |
| `GET /feedback/{id}` | one report, with `diagnostics` |
| `GET /feedback/{id}/screenshot` | `image/jpeg`, 404 when none |
| `POST /feedback/{id}/status` `{status, note?}` | the updated report; a missing `note` keeps the old one |

A report: `{id, created_at, player, reporter, kind, text, context, has_screenshot,
has_diagnostics, status, note, updated_at}`, plus `diagnostics` on `GET /feedback/{id}`.
