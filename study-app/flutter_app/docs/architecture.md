# FlutterAgent UI 架构

## 双项目架构

参考 OpenClaw 的 pi-agent-core vs apps/desktop 分层设计：

```
study-app/
├── flutter_agent/         # 纯 Dart 引擎包（无 Flutter 依赖）
│   └── lib/
│       ├── core/          # ReAct loop, event, tool 定义
│       ├── llm/           # OpenAI-compatible API client
│       ├── tools/         # bash, list_dir, read_file
│       └── system_prompt/ # 模型系统提示
└── flutter_app/           # Flutter 桌面 UI app
    └── lib/
        ├── agent/         # AgentController + AgentState（状态层）
        ├── ui/            # ChatScreen + 子 widgets（展示层）
        └── main.dart      # 入口 + bootstrap
```

flutter_app 通过 pubspec.yaml 的 path dependency 引用 flutter_agent：

```yaml
dependencies:
  flutter_agent:
    path: ../flutter_agent
```

## 层间边界

| 层 | 职责 | 不做什么 |
|---|---|---|
| flutter_agent (engine) | ReAct loop、LLM 调用、工具执行、事件回调 | 不依赖 Flutter，不管理 UI 状态 |
| agent/ (状态层) | 包装 reactLoop → Stream<AgentSnapshot>，翻译引擎事件到 UI 状态 | 不直接渲染 widget |
| ui/ (展示层) | StreamBuilder 订阅状态流，渲染 widget | 不直接调用 reactLoop 或 LLM client |

关键设计：**单轨状态流**（autoplan 决策 #10）。不使用 ChangeNotifier + StreamController 双轨；所有状态变化通过一个 `StreamController<AgentSnapshot>.broadcast()` 推送，UI 通过 StreamBuilder 订阅。

## AgentController 事件翻译

reactLoop 的 `onEvent(EventKind, payload)` 回调被 `_handleEvent` 翻译成 AgentSnapshot 更新：

| 事件 | 翻译 | snapshot 变化 |
|---|---|---|
| iterationStart | AgentPhase.loading | iteration=i |
| assistantMessage(text) | AgentPhase.streaming | +AssistantMessage |
| assistantMessage(tool_calls) | AgentPhase.toolExecuting | +ToolCallEntry(pending) |
| toolResult | 状态不变 | ToolCallEntry.status → done/error |
| finish | AgentPhase.idle | — |
| error | AgentPhase.error | errorMessage=message |

注意：引擎的 `AssistantMessage`（openai_client.dart wire-format 类）跟 UI 的 `AssistantMessage`（agent_state.dart 展示类）同名。通过 `import ... hide AssistantMessage` 解决冲突。

## macOS sandbox

学习项目关闭 sandbox（`com.apple.security.app-sandbox = false`），原因：

1. bash 工具需要 `Process.start`，sandbox 禁止任意子进程
2. list_dir/read_file 需要访问 `~/`，sandbox 限制文件访问到容器内
3. LLM API 需要出站网络

生产/App Store 发布需要重新开启 sandbox + 配套 entitlements。