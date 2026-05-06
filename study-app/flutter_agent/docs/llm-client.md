# LLM 客户端文档

> 精读 `lib/llm/openai_client.dart`，理解如何用 openai_dart SDK 调用模型。

## 为什么用 openai_dart SDK？

/autoplan review 发现: 手写 HTTP 客户端（openai_client.dart 从零用 http 包）
是最没教育价值的部分 — 它不教你 OpenClaw 的设计模式，只教你 HTTP plumbing。

用 `openai_dart` SDK 的好处:
- SDK 处理 HTTP 错误码、JSON 解析、tool_calls 提取、重试
- 直接调用 `client.createChatCompletion(request)` — 聚焦 ReAct 模式而非 HTTP 细节
- Phase 3 streaming 直接用 SDK 的 `chatCompletionStream()`

## 客户端架构

```
OpenAIClient
  ├── OpenAI (openai_dart SDK)     ← 实际 HTTP 调用
  ├── chatCompletion()              ← 非流式调用
  ├── _convertMessage()             ← engine Map → SDK 对象
  ├── _convertToolSpec()            ← engine tool spec → SDK 对象
  └── _httpErrorMessage()           ← HTTP 错误码 → 中文提示
```

## API Key 和 Base URL

```dart
final key = apiKey ?? Platform.environment['OPENAI_API_KEY'] ?? '';
final url = baseUrl ?? Platform.environment['OPENAI_BASE_URL'];
```

- `OPENAI_API_KEY`: 必填。支持 GLM 等兼容 endpoint 的 key。
- `OPENAI_BASE_URL`: 可选。用于代理或兼容 endpoint（如 GLM 的 API 地址）。

## HTTP 错误处理

每个 HTTP 错误码都有中文提示（problem + cause + fix）:

| 状态码 | 提示 |
|---|---|
| 401 | API key 无效。请设置 OPENAI_API_KEY 环境变量。 |
| 403 | API key 没有权限访问此模型。请检查 key 的 model access。 |
| 429 | 请求太频繁。等待几秒后重试。 |
| 500/502/503 | 模型服务暂时不可用。稍后重试。 |

这是 /autoplan review 发现的 gap — 原设计没指定 HTTP 错误的 UI 显示内容。

## 消息转换

引擎内部用 `Map<String, dynamic>` 表示 messages（方便手动操作），
SDK 用自己的类型系统（`ChatCompletionMessage` 等）。

`_convertMessage()` 把 engine Map 转成 SDK 对象:
- `role: "system"` → `ChatCompletionMessage.system()`
- `role: "user"` → `ChatCompletionMessage.user()`
- `role: "assistant"` → `ChatCompletionMessage.assistant()`（可能带 tool_calls）
- `role: "tool"` → `ChatCompletionMessage.tool()`（OpenAI 协议的 tool result）

这个转换是必要的 — SDK 不会接受 raw Map，它需要 typed 对象。

## Phase 0.5: GLM API 兼容性验证

在开始 Phase 1 之前，需要验证 GLM 的 OpenAI-compatible API:

1. **tool_calls 支持**: 发一个带工具定义的请求，看模型是否返回 `finish_reason: "tool_calls"` + tool_use
2. **SSE streaming 支持**: 发一个流式请求，看是否返回 `data: [JSON]...data: [DONE]`

验证脚本: 50 行 Dart 文件，用 openai_dart SDK 分别测这两种模式。

如果 GLM 不支持 tool_calls → 需要换模型（GPT-4o-mini / Claude Haiku）。
如果 GLM 不支持 SSE → Phase 3 先走非流式路径，后续换模型再加 streaming。