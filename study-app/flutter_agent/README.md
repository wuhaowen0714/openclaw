# FlutterAgent

基于 OpenClaw 设计模式的本地 ReAct agent 框架，Dart 引擎 + Flutter 桌面 UI。

## 快速开始

```bash
cd study-app/flutter_agent
dart pub get
export OPENAI_API_KEY="your-key"
dart run lib/cli/main.dart --task "看看当前目录" --root /path/to/sandbox
```

## 测试

```bash
dart test test/react_loop_test.dart    # 单元测试（18 个）
dart run test/smoke_glm.dart           # GLM API 兼容性验证（Phase 0.5）
```

## 架构

```
reactLoop() → OpenAI Client → Tool 执行 → System Prompt 组装
     ↑                                              ↓
     └────────── 观察 → 思考 → 行动 ─────────────────┘
```

核心就是一个 for 循环 — 调模型、执行工具、观察结果、重复直到完成。
OpenClaw 的 6000 行工程化代码（retry, fallback, compaction）都包装在这个循环外面。

## 模块

| 模块 | 文件 | 说明 |
|---|---|---|
| ReAct 引擎 | `lib/core/react_loop.dart` | 核心循环 |
| 工具系统 | `lib/tools/bash.dart`, `list_dir.dart`, `read_file.dart` | 3 个基础工具 |
| LLM 客户端 | `lib/llm/openai_client.dart` | openai_dart SDK 包装 |
| System Prompt | `lib/system_prompt/system_prompt.dart` | 分层组装（stable + dynamic） |
| CLI 入口 | `lib/cli/main.dart` | 命令行运行 |

## 开发文档

- [architecture.md](docs/architecture.md) — 架构全景
- [react-loop.md](docs/react-loop.md) — ReAct loop 走读
- [tools.md](docs/tools.md) — 工具系统 + 安全设计
- [llm-client.md](docs/llm-client.md) — LLM 客户端设计
- [system-prompt.md](docs/system-prompt.md) — System prompt 分层
- [ui-state-machine.md](docs/ui-state-machine.md) — UI 状态机
- [getting-started.md](docs/getting-started.md) — 快速开始

## 实现阶段

| Phase | 内容 | 状态 |
|---|---|---|
| 0.5 | GLM API 兼容性验证 | 有 smoke test 脚本 |
| 1 | Dart 引擎核心 + 单元测试 | 已完成 |
| 2 | Flutter 桌面 UI | 待做 |
| 3 | 思考过程可视化 | 待做 |
| 4 | Skill 插件系统 | 未来扩展 |

## 与 OpenClaw 的设计对应

| FlutterAgent | OpenClaw | 说明 |
|---|---|---|
| reactLoop() | session.prompt() | ReAct loop 核心 |
| OnEvent 回调 | onPartialReply/onBlockReply | 事件上报 |
| Tool + toToolSpec() | customTools → JSON Schema | 工具注册 |
| 错误回喂模型 | is_error: true tool_result | 模型看到错误后改策略 |
| buildSystemPrompt() | buildAgentSystemPrompt() | 分层组装 |
| stable prefix + dynamic suffix | cache boundary | 缓存友好分层 |
| truncate(head+tail) | tool-result-truncation.ts | 输出截断 |

## License

学习项目，仅供学习 OpenClaw 设计模式使用。