# System Prompt 文档

> 精读 `lib/system_prompt/system_prompt.dart`，理解 prompt 分层组装的设计。

## OpenClaw 的 system prompt 是什么？

OpenClaw 的 system prompt 不是单个静态文本，而是动态组装的。
核心来自 `src/agents/system-prompt.ts` 的 `buildAgentSystemPrompt()`。

关键特点:
- 多 section 组合（Tooling / Tool Call Style / Execution Bias / Safety / Workspace / Runtime）
- 缓存边界（stable prefix + dynamic suffix）
- Provider contribution（插件可注入额外 prompt 片段）
- 子 prompt（bootstrap, heartbeat, subagent）

## 本引擎的 system prompt 结构

参考 OpenClaw 的结构，做适当简化（只有 3 个基础工具）:

```
┌─────────────────────────────────┐
│ stable prefix（缓存友好）        │
│                                 │
│ 身份声明                        │
│ "You are a coding agent..."     │
│                                 │
│ ## Tooling                      │
│ - list_dir(path): ...           │
│ - read_file(path): ...          │
│ - bash(cmd): ...                │
│                                 │
│ ## Tool Call Style              │
│ "do not narrate routine..."     │
│                                 │
│ ## Execution Bias               │
│ "act in this turn..."           │
│                                 │
│ ## Safety                       │
│ "no independent goals..."       │
│                                 │
│ ## Robustness rules             │
│ "if ERROR, try different..."    │
├─────────────────────────────────┤ ← cache boundary
│ dynamic suffix（每轮注入）       │
│                                 │
│ ## Workspace                    │
│ "Your working directory is: ..." │
│                                 │
│ ## Runtime                      │
│ "Model: GLM-5.1..."            │
└─────────────────────────────────┘
```

## 分层设计的好处

为什么要分 stable prefix 和 dynamic suffix？

1. **缓存友好**: stable prefix 在多轮对话中不变，LLM API 可以缓存这部分，
   减少 token 计费和延迟。OpenClaw 用 `<!-- OPENCLAW_CACHE_BOUNDARY -->` 做分隔。
2. **动态注入**: workspace path 和 runtime info 每轮可能不同（换目录、换模型），
   放在 dynamic suffix 里不影响缓存。
3. **扩展性**: 未来加 provider contribution（插件注入额外 prompt 片段），
   放在 dynamic suffix 末尾，不影响 stable prefix 缓存。

## 与 Python demo 的 SYSTEM_PROMPT 对照

Python demo 的 SYSTEM_PROMPT 是这个结构的简化版:

```python
SYSTEM_PROMPT = """\
You are a coding agent that can inspect a local sandbox file tree.

Tools available:
  - list_dir(path): ...
  - read_file(path): ...
  - bash(cmd): ...

Process:
  1. Briefly state your reasoning, then call ONE OR A FEW tools.
  2. After receiving tool results, decide if you have enough info.
  3. When you have enough info, give the final answer...

Robustness rules:
  - If a tool returns ERROR, try a different approach...
"""
```

可以看到 Python demo 有:
- 身份声明 ✓
- ## Tooling ✓
- ## Robustness rules ✓
- 但没有: Tool Call Style, Execution Bias, Safety, Workspace, Runtime, 分层

Dart 版应该更接近 OpenClaw 的完整结构，按需裁剪到只有 3 个工具的场景。

## 如何使用

```dart
final systemPrompt = buildSystemPrompt(
  toolNames: ['list_dir', 'read_file', 'bash'],
  workspaceDir: '/path/to/sandbox',
  model: 'GLM-5.1',
);
```

- `buildStablePrefix(toolNames)` — 只依赖工具列表（不变时缓存）
- `buildDynamicSuffix(workspaceDir, model)` — 每轮注入（不缓存）
- `buildSystemPrompt()` — 拼接两者

## 未来的扩展方向

1. **Provider contribution**: 插件注入额外 prompt 片段到 dynamic suffix 末尾
2. **Bootstrap prompt**: 从 BOOTSTRAW.md 文件加载项目特定指令
3. **Heartbeat prompt**: 定期注入 heartbeat 指令
4. **Subagent prompt**: 子 agent 用独立的、更简洁的 system prompt