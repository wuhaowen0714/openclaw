# ReAct Loop 详细走读

> 精读 `lib/core/react_loop.dart` 的每一行，理解 ReAct 范式在 Dart 中的实现。

## 什么是 ReAct？

ReAct = Reasoning + Acting（Yao et al. 2022）。agent 不是一次性给出答案，而是:
1. **思考**（Reasoning）— 分析问题，决定下一步
2. **行动**（Acting）— 调用工具获取信息
3. **观察**（Observation）— 看工具返回的结果
4. 重复 1-3 直到有足够信息给出最终答案

这就是 `reactLoop()` 函数做的事。

## 代码走读

### 1. 初始化（第 37-46 行）

```dart
final cfg = config ?? const ReActConfig();
final emit = onEvent ?? ((_, __) {});
final toolsByName = {for (final t in tools) t.name: t};
final toolSpecs = [for (final t in tools) t.toToolSpec()];

final messages = <Map<String, dynamic>>[];
if (systemPrompt != null) {
  messages.add({'role': 'system', 'content': systemPrompt});
}
messages.add({'role': 'user', 'content': userPrompt});
```

关键决策:
- `messages` 用 Map 而非 SDK 对象 — 方便手动操作（append tool result 等）
- `systemPrompt` 可选 — 对应 OpenClaw 的 systemPromptOverride
- `toolSpecs` 预先转换 — 对应 OpenClaw 的 materializeBundleMcpToolsForRun

### 2. 主循环（第 48-92 行）

```dart
for (var i = 0; i < cfg.max_iters; i++) {
  emit(iterationStart, {'i': i, 'history_len': messages.length});
  ...
}
```

`max_iters` 是兜底 — 对应 OpenClaw 的 `MAX_RUN_LOOP_ITERATIONS`。
防止 agent 无限循环（模型可能一直调工具不给出答案）。

### 3. 调模型（第 50-68 行）

```dart
final resp = await client.chatCompletion(
  model: cfg.model,
  messages: messages,
  tools: toolSpecs,
  ...
);
```

对应 Python demo 的 `client.chat.completions.create()`。
也对应 OpenClaw 的 `activeSession.prompt()` — 被 await 一行带过。

### 4. 处理 finish_reason（第 70-78 行）

```dart
if (finishReason == 'stop' || msg.toolCalls == null || msg.toolCalls!.isEmpty) {
  emit(finish, {'text': msg.content ?? ''});
  return msg.content ?? '';
}
```

`finish_reason == "stop"` = 模型决定不再调工具，给出最终答案。
这是正常的退出路径。

### 5. 执行工具（第 80-98 行）

```dart
if (finishReason == 'tool_calls') {
  for (final tc in msg.toolCalls!) {
    final tool = toolsByName[tc.function.name];
    ...
    result = await tool.run(args);
    ...
    messages.add({
      'role': 'tool',
      'tool_call_id': tc.id,
      'content': result,
    });
  }
  continue;
}
```

关键设计:
- **错误回喂模型** — tool error 不抛到外面，而是变成 `content: "ERROR: ..."` 让模型看到
- **OpenAI 协议** — tool result 是 `role: "tool"` 消息（不是 Anthropic 协议的 user message + tool_result block）
- **串行执行** — `parallelToolCalls=True` 时模型可能一次发多个 tool_use，但引擎逐个执行

### 6. 其他 finish_reason（第 100-105 行）

```dart
emit(error, {...});
return 'ERROR: unexpected finish_reason: $finishReason';
```

`length` / `content_filter` 等异常终止 — 不抛异常（Python demo 会抛 RuntimeError），
而是返回错误字符串。这样 UI 可以显示错误而不是崩溃。

### 7. max_iters 耗尽（第 107-109 行）

```dart
throw StateError('exceeded max iterations (${cfg.max_iters})');
```

这是唯一抛异常的地方 — 对应 Python demo 的 `RuntimeError`。
因为如果 max_iters 耗尽，说明 agent 有问题，不应该静默返回。

## Messages 演化示例

假设用户给任务 "看看当前目录是什么项目"，messages 会这样演化:

```
[0] system: "You are a coding agent..." (system prompt)
[1] user: "看看当前目录是什么项目"
[2] assistant: {tool_calls: [{name: "list_dir", args: {"path": "."}}]}  ← 第 1 轮
[3] tool: {tool_call_id: "...", content: "file\tREADME.md\nfile\tpackage.json\n..."}  ← 工具结果
[4] assistant: {tool_calls: [{name: "read_file", args: {"path": "README.md"}}]}  ← 第 2 轮
[5] tool: {tool_call_id: "...", content: "# OpenClaw\n..."}  ← 工具结果
[6] assistant: "This appears to be the OpenClaw project..."  ← 最终答案（finish_reason: stop）
```

每轮加 2 条消息: assistant（带 tool_calls）+ tool result。
最终 1 条: assistant（纯文本，finish_reason: stop）。

## 与 OpenClaw 的双层 loop 对照

OpenClaw 的 loop 是双层的:

```
外层 (run.ts):    while (true) {                   ← retry/fallback
  内层 (attempt):    activeSession.prompt(...)      ← ReAct loop 本体
}
```

本引擎只实现内层。外层的 retry/fallback/compaction 不在这里。
理解这个分层 = 理解 "50 行内核 vs 6000 行工程化" 的边界在哪。