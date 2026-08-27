"""独立 MCP 入口 —— AI 伴侣读写日历的那条路。

暴露一个 tool：`calendar`（schema 跟上游网关逐字同源，description 里的称呼
换成了 "your partner"）。`see` 动作返回 text + image 内容块 —— 那张 image
是网页端渲染上传的整页图（贴纸、照片、手写排版原样）。

两种跑法：

  stdio（默认，Claude Desktop / Claude Code 的 mcpServers 直接指过来）:
      CALENDAR_DB=./data/calendar.db python mcp_server.py

  streamable-http（远程 agent 用 URL 接）:
      python mcp_server.py --http --host 127.0.0.1 --port 8788
      # 或环境变量 MCP_TRANSPORT=http / MCP_HOST / MCP_PORT
      # 端点是 http://<host>:<port>/mcp

跟 REST 服务共用同一个 SQLite 文件（CALENDAR_DB），两个进程可以同时开着
（库是 WAL 模式）。

写给接 MCP SDK 的人：这里用的是 mcp>=2.0 的 lowlevel API（构造函数收
on_list_tools / on_call_tool 回调）；1.x 的装饰器写法在 2.0 里已经没有了。
"""

from __future__ import annotations

import argparse
import logging
import os
from typing import Any, Optional

import anyio
import mcp.types as types
from mcp.server.lowlevel import Server

import config
from calendar_core import Storage, execute_calendar_tool

logger = logging.getLogger(__name__)

# ============================================================
# tool 定义 —— 从上游网关 RESIDENT_TOOLS 原样搬来（8/2 定位确认与 api 模式逐字同源），
# description 里对用户的称呼统一成 "your partner"、时区跟着 CALENDAR_TZ 走
# ============================================================

CALENDAR_TOOL: dict = {
    "type": "function",
    "function": {
        "name": "calendar",
        "description": (
            "Read or manage a shared calendar for an authorized human participant and AI agent. "
            "Treat both as distinct participants with equal dignity. Pending changes authored by the "
            "human participant are returned first with NEW; query by local date, exact time, or an ISO "
            "range. Create, update, delete, and comment are mutations and require clear authorization "
            "from the integrating application. Times without an offset are interpreted as "
            + config.CALENDAR_TZ + "; a missing end defaults to one hour. action=see returns one event's "
            "details when event_id is provided; otherwise it returns one day's latest available page "
            "image plus database-exact text (date defaults to today). update/delete also work on notes: "
            "pass note_id (cmt_…) to edit text through comment, set liked:true or liked:false, or "
            "soft-delete the note. Notes render on paper about two lines high; keep paper-facing "
            "comments within ~18 CJK chars."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["list", "see", "create", "update", "delete", "comment"],
                },
                "event_id": {"type": "string"},
                "note_id": {"type": "string", "description": "cmt_… id; makes update/delete act on a note"},
                "liked": {"type": "boolean", "description": "with note_id: true hearts the note, false takes it back"},
                "title": {"type": "string", "maxLength": 160},
                "description": {"type": "string", "maxLength": 2000},
                "starts_at": {"type": "string", "description": "ISO datetime or YYYY-MM-DD"},
                "ends_at": {"type": "string", "description": "ISO datetime, exclusive end (a multi-day event through Aug 16 needs ends_at Aug 17); omitted = one hour"},
                "precision": {
                    "type": "string",
                    "enum": ["minute", "hour", "segment", "day"],
                },
                "event_type": {"type": "string"},
                "metadata": {
                    "type": "object",
                    "description": "Optional JSON metadata, including web annotation fields such as rail, done, pin, and keyword",
                },
                "comment": {"type": "string", "maxLength": 2000},
                "date": {
                    "type": "string",
                    "description": (
                        config.CALENDAR_TZ + " date, YYYY-MM-DD. Filters list; with action=comment "
                        "and no event_id it pins the note to that whole day instead of an event."
                    ),
                },
                "at": {"type": "string", "description": "Events active at this ISO datetime"},
                "from": {"type": "string", "description": "Range start, inclusive"},
                "to": {"type": "string", "description": "Range end, exclusive"},
                "new_only": {"type": "boolean"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 500},
            },
            "required": ["action"],
        },
    },
}

_storage: Optional[Storage] = None


async def _get_storage() -> Storage:
    global _storage
    if _storage is None:
        storage = Storage(config.CALENDAR_DB)
        await storage.connect()
        _storage = storage
    return _storage


def _to_blocks(blocks: list[dict[str, Any]]) -> list[types.ContentBlock]:
    """calendar_core 的 as_mcp_content 出的是 dict，翻成 SDK 的内容块类型"""
    out: list[types.ContentBlock] = []
    for block in blocks:
        if block.get("type") == "image":
            out.append(types.ImageContent(
                type="image",
                data=str(block.get("data") or ""),
                mime_type=str(block.get("mimeType") or "image/png"),
            ))
        else:
            out.append(types.TextContent(type="text", text=str(block.get("text") or "")))
    return out


async def on_list_tools(ctx, params) -> types.ListToolsResult:
    fn = CALENDAR_TOOL["function"]
    return types.ListToolsResult(tools=[
        types.Tool(
            name=fn["name"],
            description=fn["description"],
            input_schema=fn["parameters"],
        )
    ])


async def on_call_tool(ctx, params: types.CallToolRequestParams) -> types.CallToolResult:
    if params.name != "calendar":
        return types.CallToolResult(
            content=[types.TextContent(type="text", text=f"unknown tool: {params.name}")],
            is_error=True,
        )
    storage = await _get_storage()
    result = await execute_calendar_tool(
        storage, dict(params.arguments or {}))
    if hasattr(result, "as_mcp_content"):
        return types.CallToolResult(content=_to_blocks(result.as_mcp_content()))
    return types.CallToolResult(content=[types.TextContent(type="text", text=str(result))])


server: Server = Server(
    "couple-calendar",
    on_list_tools=on_list_tools,
    on_call_tool=on_call_tool,
)


# ============================================================
# 两种 transport
# ============================================================


async def _run_stdio() -> None:
    from mcp.server.stdio import stdio_server
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream, write_stream, server.create_initialization_options())


def _run_http(host: str, port: int) -> None:
    import uvicorn

    # stateless + json：curl 也能直接打，远程 agent 不用维护 session
    starlette_app = server.streamable_http_app(
        streamable_http_path="/mcp",
        json_response=True,
        stateless_http=True,
        host=host,
    )
    uvicorn.run(starlette_app, host=host, port=port)


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    parser = argparse.ArgumentParser(description="couple-calendar MCP server")
    parser.add_argument("--http", action="store_true",
                        help="serve streamable-http instead of stdio")
    parser.add_argument("--host", default=os.environ.get("MCP_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int,
                        default=int(os.environ.get("MCP_PORT", "8788")))
    args = parser.parse_args()

    transport = os.environ.get("MCP_TRANSPORT", "").strip().lower()
    use_http = args.http or transport in {"http", "streamable-http", "streamable_http"}

    if use_http:
        _run_http(args.host, args.port)
    else:
        anyio.run(_run_stdio)


if __name__ == "__main__":
    main()
