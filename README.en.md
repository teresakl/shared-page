# Shared Page — a paper-like calendar shared with an AI

[中文说明](README.md) · [Agent / MCP integration](docs/agent-integration.md)

> **Start here: this is a web-first fork.**
>
> This repository is forked from [KKarsyline/shared-page](https://github.com/KKarsyline/shared-page). The upstream project is centered on an iOS client. This version keeps the backend and MCP calendar interface, and adds a web client for desktop browsers and phones on the same trusted LAN.
>
> The comparison below comes first so the upstream features, the features kept here, and the web additions are easy to distinguish.

## This version compared with upstream

| Capability | Upstream | This version |
|---|---|---|
| FastAPI + SQLite backend | Yes | Kept |
| MCP `calendar` tool and six actions | Yes | Kept |
| `list` / `see` / `create` / `update` / `delete` / `comment` | Yes | Kept |
| Birthday, anniversary, and holiday seeding | Yes | Kept, including `rail` configuration |
| iOS client | Yes | Not included here |
| Native client push | Yes (through the iOS client) | Not provided here |
| iOS home-screen widget | Yes | Not included here |
| Vision cutout and reusable sticker baking | Yes | Not included here |
| Sticker thumbnails in the month grid | Yes | Not included here |
| Local web client | No | Added |
| Desktop and trusted-LAN phone access | No | Added |
| Web month/day views, events, notes, stickers, and polaroids | No | Added |
| Web sticker drag, delete, rotate, scale, and z-order control | No | Added |
| Photo upload, sticker/photo placement storage, and page rendering | No | Added |
| `done`, `keyword`, `pin`, annual-date rail, and stale-page notice | No | Added |
| `seed_demo.py` and `seeds.example.json` | No | Added |

For the native iOS client, home-screen widget, or the upstream Xcode workflow, use the [upstream repository](https://github.com/KKarsyline/shared-page). This repository documents and supports the web client.

## What it is

Shared Page is a paper-like shared calendar. A human participant and an AI agent can read and maintain the events, notes, and page records in one calendar.

The web client handles the paper-like reading and editing experience. Through MCP, an integrating agent can:

- read events in a date range;
- inspect a day's text and its latest rendered page image;
- create, update, or delete events;
- place notes on a day and update their likes.

The web client and MCP server use the same SQLite database. The default setup stores data on the machine where the service runs and does not require an account system.

![The web month and day views](https://github.com/teresakl/shared-page/raw/main/docs/preview.png)

_The screenshot shows the current web client with example month/day data, an event, a note, and paper elements._

## Quick start

### Environment

- Python 3.10 or newer; Python 3.12 is recommended.
- Runtime dependencies are listed in `server/requirements.txt`.
- `tzdata` is already included for Windows IANA time-zone data; it does not need a separate installation.

### macOS / Linux / Git Bash

```bash
cd server
python -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m uvicorn web_app:app --host 127.0.0.1 --port 8787
```

### Windows PowerShell

```powershell
cd server
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m uvicorn web_app:app --host 127.0.0.1 --port 8787
```

Open <http://127.0.0.1:8787> in a browser.

With `server/` as the working directory, the default data layout is:

```text
server/data/calendar.db
server/data/pages/*.png
server/data/placed/*.json
server/data/photos/*.jpg
```

The database, page-image directory, and time zone can be changed with environment variables:

```text
CALENDAR_DB=./data/calendar.db
CALENDAR_PAGES_DIR=./data/pages
CALENDAR_TZ=Asia/Shanghai
```

`.env.example` is a template. The application does not load `.env` automatically; export the variables in the shell or pass them through the environment that starts the process.

### Phone access

When the computer and phone are on the same trusted LAN, listen on all interfaces:

```bash
.venv/bin/python -m uvicorn web_app:app --host 0.0.0.0 --port 8787
```

Then open the computer's LAN address on the phone, for example `http://192.168.x.x:8787`.

### Health check

```text
GET http://127.0.0.1:8787/api/v1/calendar/ping
```

## Web client

### Month and day views

- Month view shows dates, event keywords, today state, the annual-date rail, and unseen-change notices.
- Day view shows the hourly timeline, all-day events, multi-day spans, notes, stickers, and polaroids.
- Events can have a short keyword and can be marked done. A completed event stays on the timeline with a strike-through.
- Events can be marked as priority for month-grid display when a day is crowded.
- `birthday` and `anniversary` events use the anniversary style; `period` events use the span style.
- Up to three pinned birthdays or anniversaries appear in the annual rail.

The default labels are `USER` and `ASSISTANT`; environment variables can change them. Seeded dates use the USER-side paper color and keep `source: seed` in the data as their provenance marker.

### Notes

In day view, you can place a note on the current date. A note is a short reminder on that day's paper, not an automatic copy of every chat turn. The intended workflow is to put formal plans in events and create a note only after an explicit request or through an already authorized scheduled workflow.

The web client creates a note immediately with the starter text `写点什么` and enters editing. The text is saved on blur; `×` means remove the note. MCP `comment` creates a note when the integrating application has that explicit request. Notes can be edited, liked, or removed. MCP also supports attaching a note to an event, while the web client lays notes out by date and does not show that binding separately.

A paper note is designed for about two lines, roughly 18 CJK characters. Longer text can be split across notes; the complete text remains in the database.

### Stickers and polaroids

- Stickers can be dragged, deleted, rotated, scaled, and brought to the front.
- The current web sticker tray contains a halftone cat, vintage camera, coffee cup, ticket, and red heart.
- A local photo is uploaded as JPEG and placed in a polaroid frame.
- Sticker and photo positions are saved in the layout for that date.

### Page rendering

After a changed day is left through web navigation, the page is rendered to PNG. MCP `see` can read the latest successful image together with the database text.

A page image is a snapshot rather than a live view. A date that has never rendered successfully still returns its text through `see`.

### Stale-page notice

If the same calendar is changed from another browser, phone, or agent, the open page asks you to refresh before continuing to edit an old view.

## MCP integration

The complete English interface guide is [`docs/agent-integration.md`](docs/agent-integration.md). The MCP server has two transports:

```bash
cd server
.venv/bin/python mcp_server.py
.venv/bin/python mcp_server.py --http --host 127.0.0.1 --port 8788
```

On Windows, replace `.venv/bin/python` with `.venv\Scripts\python.exe`.

The six actions are:

```text
list · see · create · update · delete · comment
```

The MCP server and web service share one SQLite file through `CALENDAR_DB`. The MCP HTTP endpoint is `/mcp` and listens on `127.0.0.1:8788` by default.

If `CALENDAR_TOKEN` is set, protected web-data routes use:

```text
X-Calendar-Token: <your token>
```

## Optional modules

### Seed annual dates

`server/seeder.py` can seed birthdays, anniversaries, and holidays by Gregorian month and day:

```json
[
  {"month_day": "03-15", "type": "birthday", "title": "Birthday"},
  {"month_day": "06-01", "type": "anniversary", "title": "Anniversary", "rail": true},
  {"month_day": "12-25", "type": "holiday", "title": "Holiday"}
]
```

Set `CALENDAR_SEED_FILE` to the JSON file and `CALENDAR_SEED_YEARS` to the number of years. Running the seeder repeatedly does not create duplicate seed events.

For demo data, use a separate database:

```bash
cd server
CALENDAR_DB=./data/demo-calendar.db .venv/bin/python seed_demo.py
```

## Tests

```bash
cd server
python -m unittest discover -s tests -t .
```

The tests exercise local code only; they do not need network access or a model service. Install the dependencies from `server/requirements.txt` first.

## Data and license

Back up these together:

- the SQLite file at `CALENDAR_DB`;
- the page-image directory at `CALENDAR_PAGES_DIR`;
- `placed/` and `photos/` beside the SQLite file.

The code is licensed under the MIT License. The original copyright notice and license terms are in [`LICENSE`](LICENSE). The web frontend, web adapter, and related fixes use the same MIT license; asset-specific licenses and attributions are in [`licenses/`](licenses/).

- Upstream: <https://github.com/KKarsyline/shared-page>
- This repository: <https://github.com/teresakl/shared-page>
