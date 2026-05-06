"""
ReAct loop 核心实现 — 对应 docs/concepts/react-loop.zh.md 第 4 节的伪代码。

设计原则:
  1. 内核保持精炼。所有"工程化"(retry / fallback / compaction / streaming bridge)
     都不在这里 —— 这层只负责"调模型 → 看 stop reason → 执行工具 → 把结果回喂"。
  2. 不直接 print。通过 on_event callback 把内部事件吐出去,等价于 OpenClaw 里
     pi-agent-core 通过 onPartialReply / onBlockReply 回调上报事件的设计。
  3. tool 失败不抛到外面,而是包成 result 字符串喂给模型 —— 这是 ReAct 的精髓:
     模型自己读到错误后会改策略(换路径、降级、问用户)。

OpenAI vs Anthropic 协议差异(重要,容易混淆):
  - 文档里说"tool_result 是 user 角色"指的是 Anthropic 协议
    (assistant message 里有 tool_use block,user message 里有 tool_result block)。
  - OpenAI 协议是单独的 role="tool" 消息(本文件用的就是这套),概念上等价 ——
    都代表"外部世界回喂给模型的输入",只是 schema 不同。
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Callable

from openai import OpenAI


@dataclass
class Tool:
    name: str
    description: str
    parameters: dict[str, Any]            # JSON Schema
    run: Callable[[dict[str, Any]], str]  # 同步,返回字符串(demo 简化)


@dataclass
class ReActConfig:
    model: str = "gpt-4o-mini"
    max_iters: int = 25
    parallel_tool_calls: bool = True
    temperature: float = 0.0
    #: 为 True 时由 on_event 发出 api_request / api_response,便于记录原始 wire 数据
    log_raw_api: bool = False


EventKind = str  # "iteration_start" | "api_request" | "api_response" | "assistant_message" | ...
OnEvent = Callable[[EventKind, dict[str, Any]], None]


def _json_safe(obj: Any) -> Any:
    """把 messages 里的 SDK 对象转成可 JSON 序列化的结构,便于 raw 日志。"""
    if hasattr(obj, "model_dump") and callable(obj.model_dump):
        return obj.model_dump()
    if isinstance(obj, dict):
        return {k: _json_safe(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_json_safe(x) for x in obj]
    return obj


def _to_openai_tool_spec(tool: Tool) -> dict[str, Any]:
    return {
        "type": "function",
        "function": {
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.parameters,
        },
    }


def react_loop(
    client: OpenAI,
    tools: list[Tool],
    user_prompt: str,
    *,
    system_prompt: str | None = None,
    config: ReActConfig | None = None,
    on_event: OnEvent | None = None,
) -> str:
    """跑一次 ReAct loop,返回最终 assistant text。"""
    cfg = config or ReActConfig()
    emit: OnEvent = on_event or (lambda *_: None)
    tools_by_name = {t.name: t for t in tools}
    tool_specs = [_to_openai_tool_spec(t) for t in tools]

    messages: list[Any] = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    messages.append({"role": "user", "content": user_prompt})

    for i in range(cfg.max_iters):
        emit("iteration_start", {"i": i, "history_len": len(messages)})

        if cfg.log_raw_api:
            emit("api_request", {
                "iteration": i,
                "model": cfg.model,
                "messages": _json_safe(messages),
                "tools": tool_specs,
                "temperature": cfg.temperature,
                "parallel_tool_calls": cfg.parallel_tool_calls,
            })

        resp = client.chat.completions.create(
            model=cfg.model,
            messages=messages,
            tools=tool_specs,
            parallel_tool_calls=cfg.parallel_tool_calls,
            temperature=cfg.temperature,
        )

        if cfg.log_raw_api:
            emit("api_response", {
                "iteration": i,
                "completion": resp.model_dump(),
            })

        choice = resp.choices[0]
        msg = choice.message
        finish_reason = choice.finish_reason

        # 把模型返回的 assistant message 直接 append 进 history。
        # 这里直接用 SDK 返回的对象 —— OpenAI SDK 在下一轮调用时会自动
        # 把它序列化成正确的 wire format。手动转 dict 容易丢字段(尤其是
        # tool_calls),让 SDK 自己处理最稳。
        messages.append(msg)
        emit("assistant_message", {
            "finish_reason": finish_reason,
            "text": msg.content,
            "tool_calls": [
                {"id": tc.id, "name": tc.function.name, "arguments": tc.function.arguments}
                for tc in (msg.tool_calls or [])
            ],
        })

        # 终止:模型不再调工具,给出最终答案
        if finish_reason == "stop" or not msg.tool_calls:
            emit("finish", {"text": msg.content or ""})
            return msg.content or ""

        # 还有 tool calls,要执行
        if finish_reason == "tool_calls":
            for tc in msg.tool_calls:
                tool = tools_by_name.get(tc.function.name)
                emit("tool_call", {
                    "id": tc.id,
                    "name": tc.function.name,
                    "arguments_raw": tc.function.arguments,
                })

                if tool is None:
                    result = f"ERROR: tool {tc.function.name!r} not found"
                else:
                    try:
                        args = json.loads(tc.function.arguments or "{}")
                    except json.JSONDecodeError as e:
                        # 模型偶尔 emit malformed JSON args(对应 OpenClaw
                        # 里的 attempt.tool-call-argument-repair.ts)。这里
                        # 简单返回错误,真实生产应该尝试修复。
                        result = f"ERROR: malformed JSON args: {e}; raw={tc.function.arguments!r}"
                    else:
                        try:
                            result = tool.run(args)
                        except Exception as e:
                            result = f"ERROR: {type(e).__name__}: {e}"

                # OpenAI 协议的 tool result 消息(role="tool" + tool_call_id 配对)
                messages.append({
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": result,
                })
                emit("tool_result", {"id": tc.id, "result": result})
            continue

        # length / content_filter 等其他终止原因 —— demo 不处理
        raise RuntimeError(f"unexpected finish_reason: {finish_reason}")

    raise RuntimeError(f"exceeded max iterations ({cfg.max_iters})")
