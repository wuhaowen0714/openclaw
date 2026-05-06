# FlutterAgent 架构总览

> 本文档是 FlutterAgent 的架构全景，帮助理解整体设计和各模块之间的关系。
> 精读顺序: 本文档 → react-loop.md → tools.md → llm-client.md → system-prompt.md

## 一句话概括

FlutterAgent 是一个本地 ReAct agent 框架，基于 OpenClaw 的设计模式，
用 Dart 实现引擎核心，Flutter 实现桌面 UI，目标让用户看到 agent 的思考过程。

## 核心循环（ReAct Loop）

整个引擎就是一个 for 循环:

```
for i in 0..max_iters:
    resp = openai.chat.completions.create(messages, tools=...)
    msg = resp.choices[0].message
    messages.append(msg)

    if finish_reason == "stop":
        return msg.content                    # 完成
    if finish_reason == "tool_calls":
        for tc in msg.tool_calls:
            result = run_tool(tc)
            messages.append({role: "tool", tool_call_id: tc.id, content: result})
        continue
```

去掉注释、错误处理、event hook，这就是 ReAct 的全部。
OpenClaw 的 6000 行工程化代码（retry, fallback, compaction, streaming bridge）都包装在这个循环外面。

## 模块依赖图

```
                    ┌─────────────────┐
                    │   CLI / Flutter  │  ← 用户交互层
                    │     UI 入口       │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │   reactLoop()    │  ← 核心循环（core/react_loop.dart）
                    │   ReAct 引擎     │
                    └────┬───┬───┬────┘
                         │   │   │
            ┌────────────┘   │   └──────────┐
            │                │              │
   ┌────────▼─────┐  ┌──────▼──────┐  ┌────▼─────┐
   │   OpenAI     │  │  Tool 执行  │  │  System   │
   │   Client     │  │  bash/list  │  │  Prompt   │
   │   (LLM 调用) │  │  _dir/read  │  │  组装     │
   └──────────────┘  └─────────────┘  └──────────┘
            │                │
            │         ┌──────▼──────┐
            │         │  helpers    │
            │         │  (sandbox/  │
            │         │   truncate) │
            │         └─────────────┘
            │
   ┌────────▼──────┐
   │  openai_dart  │  ← 第三方 SDK（不手写 HTTP）
   │  SDK           │
   └───────────────┘
```

## 与 OpenClaw 的设计对应

| FlutterAgent 模块 | OpenClaw 对应 | 说明 |
|---|---|---|
| `reactLoop()` | pi-agent-core 的 `session.prompt()` | ReAct loop 核心 |
| `OnEvent` 通用回调 | `onPartialReply` / `onBlockReply` | 事件上报机制 |
| `Tool` + `toToolSpec()` | `customTools` → JSON Schema | 工具注册+序列化 |
| 错误回喂模型 | `is_error: true` tool_result | 模型看到错误后改策略 |
| `max_iters` | `MAX_RUN_LOOP_ITERATIONS` | 迭代上限兜底 |
| `Process.start('sh', ['-c', cmd])` | sandbox bash | 本地命令执行 |
| `buildSystemPrompt()` | `buildAgentSystemPrompt()` | system prompt 分层组装 |
| stable prefix + dynamic suffix | cache boundary | 缓存友好的 prompt 分层 |
| truncate(head+tail) | `tool-result-truncation.ts` | 输出截断 |

## 没有的（OpenClaw 有，本引擎不实现）

- retry / model fallback（OpenClaw 的 `run.ts:1032` 外层 while）
- compaction（`compact.ts` — messages 超长时压成摘要）
- streaming bridge（Phase 3 实现，当前只支持非流式）
- plugin/skill system（Phase 4 未来扩展）
- 多模型支持（当前只用 GLM）

## 实现阶段

| Phase | 内容 | 状态 |
|---|---|---|
| 0.5 | GLM API 兼容性验证 | 待做 |
| 1 | Dart 引擎核心 | 已完成（代码） |
| 2 | Flutter 桌面 UI | 待做 |
| 3 | 思考过程可视化 | 待做 |
| 4 | Skill 插件系统 | 未来扩展 |

## 文件结构

```
study-app/flutter_agent/
├── lib/
│   ├── core/
│   │   ├── tool.dart          # Tool 数据类
│   │   ├── react_config.dart  # ReActConfig 配置类
│   │   ├── react_loop.dart    # reactLoop() 核心函数
│   │   └── event.dart         # EventKind / OnEvent 回调定义
│   ├── tools/
│   │   ├── bash.dart          # bash 工具（Process.start）
│   │   ├── list_dir.dart      # list_dir 工具
│   │   ├── read_file.dart     # read_file 工具
│   │   └── helpers.dart       # sandbox + truncate 辅助函数
│   ├── llm/
│   │   ├── openai_client.dart # OpenAI-compatible API 客户端
│   ├── system_prompt/
│   │   ├── system_prompt.dart # system prompt 分层组装
│   ├── cli/
│   │   └── main.dart          # CLI 入口
├── test/
│   ├── react_loop_test.dart   # ReAct loop 单元测试（待写）
│   ├── tools_test.dart        # 工具执行测试（待写）
├── docs/
│   ├── architecture.md        # ← 你正在读的
│   ├── react-loop.md          # ReAct loop 详细走读
│   ├── tools.md               # 工具系统文档
│   ├── llm-client.md          # LLM 客户端文档
│   ├── system-prompt.md       # System prompt 文档
│   ├── ui-state-machine.md    # UI 状态机文档
│   └── getting-started.md     # 快速开始
├── pubspec.yaml
└── README.md                   # 项目 README（待写）
```