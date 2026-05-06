# Agent 状态机

## 6 个 AgentPhase

```
empty ──→ loading ──→ streaming ──→ idle
              │            │
              ↓            ↓
         toolExecuting ──→ loading（下一轮）
              │
              ↓
           error
```

| Phase | 含义 | UI 表现 |
|---|---|---|
| empty | 初始状态，未开始对话 | StatusBar "就绪"，空消息列表 |
| loading | 模型正在思考（等待 API 响应） | StatusBar "正在思考..." + spinner，输入框禁用 |
| streaming | 模型返回文本（无 tool_calls） | StatusBar "接收中..." + spinner |
| toolExecuting | 模型返回 tool_calls，正在执行工具 | StatusBar "执行工具..." + spinner，ToolCallCard pending |
| idle | 一轮对话结束 | StatusBar "完成"，输入框可用 |
| error | API 错误 / max_iters 耗尽 / 异常 | StatusBar "错误: ..."（红色） |

## 状态流转示例

**纯文本对话（无工具调用）：**
```
submit("你好") → empty→loading → loading→streaming(+AssistantMessage) → streaming→idle
```

**带工具调用：**
```
submit("看看当前目录") → empty→loading
  → loading→toolExecuting(+ToolCallEntry pending)
  → toolResult → ToolCallEntry done → toolExecuting→loading（iteration 2）
  → loading→streaming(+AssistantMessage "这是一个xxx项目")
  → streaming→idle
```

**错误场景：**
```
submit("xxx") → empty→loading → loading→error("API key invalid")
```

## ChatMessage 类型

UI 展示模型（不是引擎 wire-format）：

| 类型 | 来源 | UI widget |
|---|---|---|
| UserMessage | 用户输入 | 右对齐蓝色气泡 |
| AssistantMessage | 模型文本输出 | 左对齐灰色气泡 |
| ToolCallEntry | 模型 tool_calls | ToolCallCard（3态可视化） |

ToolCallEntry 有 3 种 ToolCallStatus：
- pending: 灰色边框 + spinner + "正在执行..."
- done: 绿色边框 + ✓ + result 文本
- error: 红色边框 + ✗ + ERROR result

## AgentSnapshot

不可变快照，每次事件产生新实例：

```dart
class AgentSnapshot {
  final AgentPhase phase;
  final List<ChatMessage> messages;
  final String? errorMessage;
  final int iteration;
}
```

UI 通过 `StreamBuilder<AgentSnapshot>` 订阅 `controller.stream`，每次 snapshot 变化重建整个 Column（StatusBar + MessageList + InputBox）。成本可控因为消息列表只增不变。