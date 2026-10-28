#!/usr/bin/env python3
"""Verify that the declared MCP capability is actually reachable and correctly bounded.

Checks, per server in agents/environment/mcp-manifest.json:

1. The server starts or answers and completes an MCP initialize handshake.
2. Every tool this repository routes is present.
3. Every write-capable tool that the server-side guard must drop is absent.

This never uses an AWS credential. AWS configuration is redirected to a nonexistent
path so the customer credential broker cannot be invoked from a readiness check.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import urllib.error
import urllib.request
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import https_fetch  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "agents/environment/mcp-manifest.json"
PROTOCOL_VERSION = "2025-06-18"
CLIENT_INFO = {"name": "tiket-readiness", "version": "1"}


class Unverified(RuntimeError):
    """The check could not be completed; distinct from a boundary violation."""


def credential_free_env() -> dict[str, str]:
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("AWS_")
    }
    missing = str(ROOT / ".nonexistent-aws-config")
    env["AWS_CONFIG_FILE"] = missing
    env["AWS_SHARED_CREDENTIALS_FILE"] = missing
    env["AWS_EC2_METADATA_DISABLED"] = "true"
    return env


def stdio_tools(server: dict) -> list[str]:
    command = [server["command"], *server["args"]]
    try:
        proc = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=credential_free_env(),
        )
    except FileNotFoundError as exc:
        raise Unverified(f"{server['command']} is not installed") from exc

    def send(payload: dict) -> None:
        assert proc.stdin is not None
        proc.stdin.write(json.dumps(payload) + "\n")
        proc.stdin.flush()

    def read(message_id: int) -> dict:
        assert proc.stdout is not None
        while True:
            line = proc.stdout.readline()
            if not line:
                assert proc.stderr is not None
                detail = proc.stderr.read().strip().splitlines()
                tail = detail[-1] if detail else "no output"
                raise Unverified(f"server exited before responding ({tail})")
            message = json.loads(line)
            if message.get("id") == message_id:
                return message

    try:
        send(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": CLIENT_INFO,
                },
            }
        )
        read(1)
        send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        result = read(2)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()

    return [tool["name"] for tool in result.get("result", {}).get("tools", [])]


def http_post(url: str, payload: dict, session: str | None) -> tuple[dict | None, str | None]:
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        # Some hosted endpoints reject the default urllib agent string.
        "User-Agent": "tiket-readiness/1 (+repository MCP boundary check)",
    }
    if session:
        headers["mcp-session-id"] = session
    request = urllib.request.Request(
        url, data=json.dumps(payload).encode("utf-8"), headers=headers, method="POST"
    )
    try:
        with https_fetch.urlopen(request, timeout=60) as response:
            body = response.read().decode("utf-8")
            new_session = response.headers.get("mcp-session-id")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise Unverified(f"cannot reach {url}: {exc}") from exc

    message = None
    for line in body.splitlines():
        line = line[len("data: "):] if line.startswith("data: ") else line
        line = line.strip()
        if not line.startswith("{"):
            continue
        candidate = json.loads(line)
        if candidate.get("id") == payload.get("id"):
            message = candidate
    return message, new_session


def http_tools(server: dict) -> list[str]:
    url = server["url"]
    _, session = http_post(
        url,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": CLIENT_INFO,
            },
        },
        None,
    )
    http_post(url, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}, session)
    listed, _ = http_post(url, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, session)
    if listed is None:
        raise Unverified("server did not return a tools/list result")
    return [tool["name"] for tool in listed.get("result", {}).get("tools", [])]


def check_server(server: dict) -> tuple[str, list[str]]:
    """Return (status, messages) where status is pass, fail, or unverified."""
    try:
        discovered = stdio_tools(server) if server["transport"] == "stdio" else http_tools(server)
    except Unverified as exc:
        return "unverified", [f"{server['id']}: {exc}"]

    messages: list[str] = []
    status = "pass"

    missing = [tool for tool in server["allowed_tools"] if tool not in discovered]
    if missing:
        status = "fail"
        messages.append(f"{server['id']}: routed tools missing: {', '.join(missing)}")

    must_be_dropped = server.get("evidence", {}).get("dropped_by_read_only", [])
    leaked = [tool for tool in must_be_dropped if tool in discovered]
    if leaked:
        status = "fail"
        messages.append(
            f"{server['id']}: server-side guard did not drop write-capable tools: "
            f"{', '.join(leaked)}"
        )

    host_denied = [
        tool
        for tool in server["blocked_tools"]
        if tool in discovered and tool not in must_be_dropped
    ]
    if host_denied:
        messages.append(
            f"{server['id']}: present at the server and blocked by host config only: "
            f"{', '.join(host_denied)}"
        )

    unexpected = [
        tool
        for tool in discovered
        if tool not in server["allowed_tools"] and tool not in server["blocked_tools"]
    ]
    if unexpected:
        status = "fail"
        messages.append(
            f"{server['id']}: undeclared tool present; classify it in the manifest before use: "
            f"{', '.join(unexpected)}"
        )

    if status == "pass":
        messages.insert(
            0,
            f"{server['id']}: {len(server['allowed_tools'])} routed tools available, "
            f"{len(discovered)} discovered",
        )
    return status, messages


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", help="check only this server id")
    args = parser.parse_args()

    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"mcp readiness: FAIL ({exc})")
        return 1

    servers = manifest["servers"]
    if args.server:
        servers = [server for server in servers if server["id"] == args.server]
        if not servers:
            print(f"mcp readiness: FAIL (unknown server: {args.server})")
            return 1

    statuses: dict[str, str] = {}
    for server in servers:
        status, messages = check_server(server)
        statuses[server["id"]] = status
        for message in messages:
            print(f"- {message}")

    if "fail" in statuses.values():
        print("mcp readiness: FAIL")
        return 1
    if "unverified" in statuses.values():
        print("mcp readiness: UNVERIFIED (prerequisite missing or endpoint unreachable)")
        print("- install uv with: brew install uv")
        print("- a transient network failure is not a configuration error; retry before concluding")
        return 2
    print(f"mcp readiness: PASS ({len(statuses)} servers)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
