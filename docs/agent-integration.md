# Agent / MCP Integration Guide

This document is for an AI agent or an integration layer that connects to Shared Page. It describes the interface and the operational boundaries of a shared calendar. It is intentionally separate from the human-facing README.

## Shared-state model

Shared Page stores one calendar shared by a human participant and an AI agent. Treat both as distinct participants with equal dignity. The agent is not a person-shaped command runner, and the human is not an input field. The agent may read or mutate calendar state only when the integrating application has clear authorization in the current context.

Do not infer private relationship rules, identity claims, consent, or authorization from the existence of an MCP connection. The MCP connection supplies capability, not permission for every possible action.

The backend uses one SQLite file and one product time zone. The web service and the standalone MCP process may use the same database file. Do not point either process at a different database by accident.

## Available MCP tool

The server exposes one tool named `calendar` with six actions:

| Action | Purpose | Main fields |
|---|---|---|
| `list` | Read events and pending changes | `date`, `at`, `from`, `to`, `new_only`, `limit` |
| `see` | Read one day's page or one event's details | `date`, optional `event_id` |
| `create` | Add an event | `title`, `starts_at`, optional `ends_at`, `precision`, `event_type`, `description`, `metadata` |
| `update` | Modify an event or a note | `event_id` or `note_id`, changed fields |
| `delete` | Soft-delete an event or a note | `event_id` or `note_id` |
| `comment` | Add a note | `comment`, `date`, optional `event_id` |

Unknown actions return an error object. The legacy `get` alias is still accepted by the backend as a compatibility path, but new callers should use `see`.

## Read before mutate

Before creating, updating, or deleting state:

1. Read the relevant date or record when the current state affects the decision.
2. Preserve fields that are not being changed, including unknown metadata and existing placed items.
3. Confirm that the caller's current request authorizes the specific mutation.
4. For deletion, make sure the target ID and intended scope are unambiguous.
5. Report the result and any validation error to the integrating application.

Do not overwrite the complete `placed` list with a newly constructed list. The web placement API is a read-modify-write endpoint. Read the existing list, preserve it, append or modify only the intended item, then write the complete result back.

## Dates and times

- Use ISO 8601 values.
- The configured product time zone is `CALENDAR_TZ`; the default is `Asia/Shanghai`.
- A timestamp without an offset is interpreted in `CALENDAR_TZ`.
- `ends_at` is an exclusive end. An event lasting through August 16 uses an end on August 17 when represented as a day range.
- If `ends_at` is omitted, the backend defaults to one hour after the start.
- For an all-day event, use `precision: "day"` and a date or local midnight as appropriate.
- `event_type: "birthday"` and `"anniversary"` receive anniversary styling in the web client.
- `event_type: "period"` uses the span layout. Other event types are accepted as labels and do not automatically create a new visual style.
- Cross-month multi-day presentation is intentionally limited; split such events if month-grid rendering matters.

## `list` and pending changes

`list` returns the selected events plus `new_changes`. `new_changes` contains changes made by the human side that have not yet been delivered to the agent-side consumer.

When the MCP `list` call returns these changes, the MCP delivery is completed as part of that call. A separate REST integration using `/env` should instead read the environment text first and call `/env/seen` only after the text was successfully incorporated into the agent context.

Do not claim that a change was understood merely because the list call succeeded. The integrating application is responsible for deciding whether the returned content was actually presented to the agent.

## `see`: text and page image

`see` without `event_id` returns:

- database-exact text for the requested date, including events and notes;
- the latest successfully uploaded PNG rendering of the web day page, when one exists;
- information about the render time and changes made after that render when applicable.

The image is a snapshot, not a live view. It can be absent, stale, or older than the database. The web client uploads the page after a changed day is left through web navigation; browser crashes, network loss, and browser-close events are not reliable upload triggers.

`see` with `event_id` returns that event's details rather than the page image flow.

A note may contain an `event_id` in the backend. The current web client lays notes out by date and does not display that binding visually.

## Notes

- `comment` creates a note using the `comment` field. The integrating application should call it only for an explicit note request or an already authorized scheduled workflow; do not turn every chat turn into a note.
- A `date` without an `event_id` anchors the note to the whole day.
- An `event_id` attaches the note to an event in the data model.
- In the web client, choosing “贴一张便签” creates the note immediately with the starter body `写点什么` and enters editing. Blur saves the edited body; the `×` control soft-deletes the note.
- `update` with `note_id` can change the note text through `comment` or `body`, and can set `liked: true` or `liked: false`.
- `delete` with `note_id` soft-deletes the note.
- The paper layout is about two lines, roughly 18 CJK characters. Keep short paper-facing notes concise; the database can still hold the complete text.

## Provenance

`source_message_id` is an optional caller-supplied field for tracing where an event came from. The backend does not enforce idempotency from that field alone; callers should implement their own deduplication if retries are possible.

Recurring dates created by `server/seeder.py` use `source: seed` and a stable ID derived from the date, type, and year. The seed file is an explicit configuration of dates, not a chat-to-calendar extraction process.

## Web-only additions

The MCP six-action tool does not manage web placements. The fork adds these REST routes for the browser client:

- `GET/PUT /api/v1/calendar/placed/{date}` for sticker and photo layout data;
- `POST /api/v1/calendar/photos` for browser-uploaded JPEG photo data;
- `GET /media/photos/{name}` for photo media;
- `POST/GET /api/v1/calendar/pages/{date}/render` for page PNG snapshots.

The placement endpoint replaces the complete list for a date. Use read-modify-write and preserve concurrent data as far as the API design permits.

## Authorization and transport

The web REST routes can be protected by `CALENDAR_TOKEN`. When configured, send:

```text
X-Calendar-Token: <token>
```

The standalone MCP server does not validate `CALENDAR_TOKEN`. Its streamable HTTP transport defaults to `127.0.0.1:8788`; keep that binding local unless a separately authenticated reverse proxy or tunnel is in front of it.

Static web assets and the health endpoint are not the same as calendar-data authorization. Do not describe the shared token as a complete multi-user security system. Review the exposure of `/media/photos/{name}` separately before public deployment.

## Neutral language requirement

Use neutral, explicit terms such as `human participant`, `AI agent`, `caller`, `authorized request`, `event`, and `note`. Do not encode a project's private household vocabulary, personal identities, or relationship assumptions into generic integration behavior. Do not call the agent a subordinate and do not call the human an owner of every possible action merely because the protocol is connected.

## Minimal stdio configuration

```json
{
  "mcpServers": {
    "calendar": {
      "command": "/absolute/path/server/.venv/bin/python",
      "args": ["/absolute/path/server/mcp_server.py"],
      "env": {
        "CALENDAR_DB": "/absolute/path/server/data/calendar.db",
        "CALENDAR_TZ": "Asia/Shanghai"
      }
    }
  }
}
```

On Windows, use the venv interpreter at:

```text
C:\absolute\path\server\.venv\Scripts\python.exe
```

The application does not load `.env` automatically. Pass required variables in the MCP client's `env` block or export them before starting the process.

## Minimal HTTP start

```bash
python mcp_server.py --http --host 127.0.0.1 --port 8788
```

The endpoint is `/mcp`. Do not bind this process to `0.0.0.0` on an untrusted network or expose it directly to the public internet.
