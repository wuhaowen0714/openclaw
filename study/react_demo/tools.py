"""
Demo 用的工具集合:list_dir / read_file / bash。

这些工具有意写得简陋 —— 真实 agent(比如 OpenClaw)的工具会做大量沙箱、
超时、权限校验、结果截断、二进制/编码处理等。这里只为了演示 ReAct loop
本身的形状,不要照抄到生产环境。

每个 tool 都做了:
  - 简单的路径越界防护(防止 ../../etc/passwd 之类)
  - 输出截断到 8000 字符(模拟 OpenClaw 的 tool-result-truncation)
  - 错误以字符串返回,不抛异常(让模型自己看到错误并改策略)
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from .core import Tool

_MAX_OUTPUT = 8000


def _truncate(s: str) -> str:
    if len(s) <= _MAX_OUTPUT:
        return s
    return s[:_MAX_OUTPUT] + f"\n... [truncated {len(s) - _MAX_OUTPUT} chars]"


def _resolve_safe(base: Path, rel: str) -> Path | str:
    """Resolve rel under base, refusing escapes. Returns Path on success, error string on failure."""
    target = (base / rel).resolve()
    if target != base and base not in target.parents:
        return f"ERROR: path {rel!r} escapes sandbox {base}"
    return target


def make_list_dir_tool(root: str | None = None) -> Tool:
    base = Path(root or os.getcwd()).resolve()

    def run(args: dict) -> str:
        rel = args.get("path", ".")
        target = _resolve_safe(base, rel)
        if isinstance(target, str):
            return target
        if not target.exists():
            return f"ERROR: not found: {rel}"
        if not target.is_dir():
            return f"ERROR: not a directory: {rel}"
        items = []
        for entry in sorted(target.iterdir()):
            kind = "dir " if entry.is_dir() else "file"
            items.append(f"{kind}\t{entry.name}")
        return _truncate("\n".join(items)) if items else "(empty)"

    return Tool(
        name="list_dir",
        description="List entries in a directory under the sandbox root. "
                    "Returns one line per entry as 'file|dir <TAB> name'.",
        parameters={
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "directory path relative to sandbox root; defaults to '.'",
                },
            },
            "required": [],
        },
        run=run,
    )


def make_read_file_tool(root: str | None = None) -> Tool:
    base = Path(root or os.getcwd()).resolve()

    def run(args: dict) -> str:
        rel = args.get("path")
        if not rel:
            return "ERROR: missing 'path'"
        target = _resolve_safe(base, rel)
        if isinstance(target, str):
            return target
        try:
            data = target.read_text(encoding="utf-8", errors="replace")
        except FileNotFoundError:
            return f"ERROR: file not found: {rel}"
        except IsADirectoryError:
            return f"ERROR: is a directory, use list_dir: {rel}"
        except Exception as e:
            return f"ERROR: {type(e).__name__}: {e}"
        return _truncate(data)

    return Tool(
        name="read_file",
        description="Read a UTF-8 text file under the sandbox root. "
                    "Output is truncated past 8000 chars.",
        parameters={
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "file path relative to sandbox root",
                },
            },
            "required": ["path"],
        },
        run=run,
    )


def make_bash_tool(cwd: str | None = None, timeout: int = 30) -> Tool:
    workdir = Path(cwd or os.getcwd()).resolve()

    def run(args: dict) -> str:
        cmd = args.get("cmd", "")
        if not cmd:
            return "ERROR: missing 'cmd'"
        try:
            r = subprocess.run(
                cmd, shell=True, cwd=str(workdir),
                capture_output=True, text=True, timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            return f"ERROR: command timed out after {timeout}s"
        out = r.stdout
        if r.stderr:
            out += f"\n[stderr]\n{r.stderr}"
        out += f"\n[exit={r.returncode}]"
        return _truncate(out)

    return Tool(
        name="bash",
        description="Run a shell command in the sandbox working directory. "
                    "Returns stdout, stderr, and exit code. Use sparingly — "
                    "prefer list_dir/read_file when those work.",
        parameters={
            "type": "object",
            "properties": {
                "cmd": {"type": "string", "description": "shell command line"},
            },
            "required": ["cmd"],
        },
        run=run,
    )
