"""
入口:跑一个 ReAct demo,展示 messages 演化与 tool 调用。

用法:
    cd study
    pip install -r requirements.txt
    export OPENAI_API_KEY=sk-...

    # 默认任务:总结当前目录是个什么项目
    python -m react_demo.main

    # 自定义任务 + 沙箱根
    python -m react_demo.main --task "find all Python files and count lines" --root .

    # verbose:把每一轮 messages 演化都打印;原始 API request/response 写入日志文件
    python -m react_demo.main --verbose
    python -m react_demo.main --verbose --log-file /tmp/react_raw.jsonl

    # 换模型 / 调上限
    python -m react_demo.main --model gpt-4o --max-iters 30

环境变量:
    OPENAI_API_KEY   必填
    OPENAI_BASE_URL  可选(用于代理 / 兼容 endpoint)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, TextIO

from openai import OpenAI

from .core import ReActConfig, react_loop
from .tools import make_bash_tool, make_list_dir_tool, make_read_file_tool

SYSTEM_PROMPT = """\
You are a coding agent that can inspect a local sandbox file tree.

Tools available:
  - list_dir(path): list entries in a directory (path relative to sandbox root)
  - read_file(path): read a UTF-8 text file
  - bash(cmd): run a shell command in the sandbox; prefer the structured tools first

Process:
  1. Briefly state your reasoning, then call ONE OR A FEW tools.
  2. After receiving tool results, decide if you have enough info.
  3. When you have enough info, give the final answer in plain text WITHOUT
     calling any tool. That ends the conversation.

Robustness rules:
  - If a tool returns ERROR, try a different approach (different path, different
    tool, or admit you cannot proceed). Do NOT call the same tool with the same
    args twice in a row.
  - Keep your final answer concise and grounded in what you actually saw.
"""


def make_event_logger(verbose: bool, log_fh: TextIO | None = None):
    """打印 ReAct 内部事件 — 教学场景下让你看到 loop 在做什么.

    verbose + log_fh:将 core 发出的 api_request / api_response(原始 input/output)写入文件。
    """

    def emit(kind: str, payload: dict[str, Any]) -> None:
        if log_fh is not None and kind in ("api_request", "api_response"):
            log_fh.write(f"=== {kind} (iteration {payload.get('iteration', '?')}) ===\n")
            log_fh.write(json.dumps(payload, ensure_ascii=False, indent=2))
            log_fh.write("\n\n")
            log_fh.flush()

        # 默认模式:只打关键事件,简洁
        if not verbose:
            if kind == "tool_call":
                print(f"  → {payload['name']}({payload['arguments_raw']})", file=sys.stderr)
            elif kind == "tool_result":
                preview = payload["result"].splitlines()[0][:120] if payload["result"] else ""
                print(f"  ← {preview}", file=sys.stderr)
            return

        # verbose 模式:每轮都吐细节
        if kind == "iteration_start":
            print(f"\n=== iteration {payload['i']}  (history len: {payload['history_len']}) ===",
                  file=sys.stderr)
        elif kind == "assistant_message":
            print(f"  assistant [{payload['finish_reason']}]:", file=sys.stderr)
            if payload["text"]:
                preview = payload["text"][:300].replace("\n", "\n    ")
                print(f"    text: {preview}", file=sys.stderr)
            for tc in payload["tool_calls"]:
                print(f"    tool_use: {tc['name']}({tc['arguments']})  id={tc['id'][:12]}",
                      file=sys.stderr)
        elif kind == "tool_result":
            preview = payload["result"][:300].replace("\n", " | ")
            print(f"  tool_result[{payload['id'][:12]}]: {preview}", file=sys.stderr)
        elif kind == "finish":
            print("\n=== finished ===", file=sys.stderr)

    return emit


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--task",
        default="List the top-level files in the current directory and tell me "
                "what kind of project this is in 2-3 sentences.",
    )
    parser.add_argument("--root", default=os.getcwd(),
                        help="filesystem root the agent can see (sandbox)")
    parser.add_argument("--model", default="GLM-5.1")
    parser.add_argument("--max-iters", type=int, default=15)
    parser.add_argument("--verbose", action="store_true",
                        help="print full message evolution per iteration")
    parser.add_argument(
        "--log-file",
        default=None,
        metavar="PATH",
        help="verbose 时把每轮 API 原始 request/response 写入该文件(默认: react_demo_verbose.log)",
    )
    args = parser.parse_args()

    if not os.environ.get("OPENAI_API_KEY"):
        print("ERROR: set OPENAI_API_KEY first", file=sys.stderr)
        return 1

    client = OpenAI()  # honors OPENAI_API_KEY and OPENAI_BASE_URL

    tools = [
        make_list_dir_tool(args.root),
        make_read_file_tool(args.root),
        make_bash_tool(args.root),
    ]

    print(f"task:  {args.task}")
    print(f"root:  {args.root}")
    print(f"model: {args.model}")
    print(f"tools: {', '.join(t.name for t in tools)}")
    log_path: str | None = None
    if args.verbose:
        log_path = args.log_file or "react_demo_verbose.log"
        print(f"verbose raw API log: {log_path}", flush=True)
    print("---", flush=True)

    log_fh = open(log_path, "w", encoding="utf-8") if log_path else None
    try:
        final = react_loop(
            client=client,
            tools=tools,
            user_prompt=args.task,
            system_prompt=SYSTEM_PROMPT,
            config=ReActConfig(
                model=args.model,
                max_iters=args.max_iters,
                log_raw_api=args.verbose,
            ),
            on_event=make_event_logger(args.verbose, log_fh=log_fh),
        )
    except RuntimeError as e:
        print(f"\nFAILED: {e}", file=sys.stderr)
        return 2
    else:
        print("---")
        print("FINAL ANSWER:")
        print(final)
        return 0
    finally:
        if log_fh is not None:
            log_fh.close()



if __name__ == "__main__":
    raise SystemExit(main())
