#!/usr/bin/env python3
"""Minimal stdio MCP adapter for the existing guest-local Chromium CDP endpoint.

No TCP listener, third-party packages or direct host network access.
Run this inside the same Linux VM as Chromium.
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

CDP = "http://127.0.0.1:9222"
MAX_MESSAGE = 1024 * 1024

TOOLS = [
    {"name": "browser_tabs", "description": "List open Chromium page tabs.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"name": "browser_new_tab", "description": "Open a URL in a new Chromium tab.",
     "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}},
                     "required": ["url"], "additionalProperties": False}},
    {"name": "browser_activate_tab", "description": "Activate an existing tab by ID.",
     "inputSchema": {"type": "object", "properties": {"tabId": {"type": "string"}},
                     "required": ["tabId"], "additionalProperties": False}},
    {"name": "browser_close_tab", "description": "Close a tab by ID.",
     "inputSchema": {"type": "object", "properties": {"tabId": {"type": "string"}},
                     "required": ["tabId"], "additionalProperties": False}},
]


def cdp(path, method="GET"):
    request = urllib.request.Request(CDP + path, method=method)
    with urllib.request.urlopen(request, timeout=5) as response:
        data = response.read(MAX_MESSAGE + 1)
        if len(data) > MAX_MESSAGE:
            raise ValueError("CDP response too large")
        return json.loads(data) if data else {}


def tabs():
    return [
        {"id": tab.get("id"), "title": tab.get("title"), "url": tab.get("url")}
        for tab in cdp("/json/list") if tab.get("type") == "page"
    ]


def call(name, args):
    if not isinstance(args, dict):
        raise ValueError("arguments must be an object")
    if name == "browser_tabs":
        return tabs()
    if name == "browser_new_tab":
        url = args.get("url")
        if not isinstance(url, str) or not url or len(url) > 4096:
            raise ValueError("url must be a nonempty string up to 4096 characters")
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise ValueError("only absolute http/https URLs are accepted")
        return cdp("/json/new?" + urllib.parse.quote(url, safe=""), "PUT")
    if name in ("browser_activate_tab", "browser_close_tab"):
        tab_id = args.get("tabId")
        if not isinstance(tab_id, str) or not tab_id or len(tab_id) > 128:
            raise ValueError("invalid tab ID")
        if tab_id not in {tab["id"] for tab in tabs()}:
            raise ValueError("tab not found")
        operation = "activate" if name == "browser_activate_tab" else "close"
        return cdp("/json/" + operation + "/" + urllib.parse.quote(tab_id, safe=""))
    raise ValueError("unknown tool")


def respond(payload):
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(
        b"Content-Length: " + str(len(raw)).encode("ascii") + b"\r\n\r\n" + raw
    )
    sys.stdout.buffer.flush()


def serve():
    stream = sys.stdin.buffer
    while True:
        headers = {}
        while True:
            line = stream.readline(8192)
            if not line:
                return
            if line in (b"\r\n", b"\n"):
                break
            if b":" not in line:
                return
            key, value = line.split(b":", 1)
            headers[key.strip().lower()] = value.strip()
        try:
            size = int(headers.get(b"content-length", b"0"))
        except ValueError:
            return
        if size <= 0 or size > MAX_MESSAGE:
            return
        body = stream.read(size)
        if len(body) != size:
            return
        try:
            request = json.loads(body)
            if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
                continue
            ident = request.get("id")
            method = request.get("method")
            if ident is None:
                continue  # Notifications do not receive a response.
            if method == "initialize":
                result = {"protocolVersion": "2024-11-05",
                          "capabilities": {"tools": {}},
                          "serverInfo": {"name": "agent-vm-browser", "version": "0.1.0"}}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                params = request.get("params") or {}
                try:
                    value = call(params.get("name"), params.get("arguments") or {})
                    result = {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}]}
                except (ValueError, urllib.error.URLError, OSError) as exc:
                    result = {"isError": True, "content": [{"type": "text", "text": str(exc)}]}
            else:
                respond({"jsonrpc": "2.0", "id": ident,
                         "error": {"code": -32601, "message": "Method not found"}})
                continue
            respond({"jsonrpc": "2.0", "id": ident, "result": result})
        except (ValueError, TypeError, KeyError):
            continue


if __name__ == "__main__":
    serve()
