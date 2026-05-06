# UI 状态机文档

> 精读设计文档中的 UI 状态机定义，理解 Flutter UI 如何跟踪 agent 的运行状态。

## 6 个状态

```
┌──────────┐
│  empty    │ ← 初始状态（没有对话）
└─────┬────┘
      │ 用户输入 prompt
┌─────▼────┐
│  loading  │ ← 正在调用 LLM（等待第一轮响应）
└─────┬────┘
      │ 收到 assistant message
┌─────▼──────┐
│  streaming │ ← 正在接收 LLM 的文本输出
└─────┬──────┘
      │ finish_reason 判断
      ├─ "stop" → 直接跳到 idle
      ├─ "tool_calls" → tool_executing
      └─ "length"/"content_filter" → error
┌─────▼──────────┐
│  tool_executing │ ← 正在执行工具（bash/list_dir/read_file）
└─────┬──────────┘
      │ 工具结果返回，继续 ReAct loop
      │ → 回到 loading（再次调 LLM）
┌─────▼────┐
│  idle     │ ← 对话完成（模型给出最终答案）
└──────────┘
┌──────────┐
│  error    │ ← 异常终止（API 错误 / max_iters 耗尽）
└──────────┘
```

## 状态转换规则

| 当前状态 | 事件 | 目标状态 | 说明 |
|---|---|---|---|
| empty | 用户提交 prompt | loading | 开始 ReAct loop |
| loading | 收到 assistant message（有文本） | streaming | 模型正在输出文本 |
| loading | 收到 assistant message（有 tool_calls） | tool_executing | 模型决定调工具 |
| loading | HTTP 错误 | error | API 调用失败 |
| streaming | finish_reason=stop | idle | 模型完成回答 |
| streaming | finish_reason=tool_calls | tool_executing | 模型要调工具 |
| streaming | finish_reason=length | error | 输出被截断 |
| streaming | finish_reason=content_filter | error | 内容被过滤 |
| tool_executing | 工具完成 + continue | loading | 下一轮 ReAct |
| tool_executing | 工具出错（回喂模型） | loading | 错误回喂，继续循环 |
| idle | 用户提交新 prompt | loading | 新对话 |
| error | 用户重试 | loading | 重新开始 |

## StreamController 管理

所有状态通过一个 `StreamController<AgentState>` 管理:

```dart
class AgentBloc {
  final StreamController<AgentState> _stateCtrl = StreamController<AgentState>.broadcast();

  Stream<AgentState> get stateStream => _stateCtrl.stream;
  AgentState _current = AgentState.empty;

  void _emit(AgentState newState) {
    _current = newState;
    _stateCtrl.add(newState);
  }
}
```

为什么只用 StreamController，不用 ChangeNotifier？

- autoplan 决策 #10: StreamController 天然支持异步事件流
- Flutter 的 StreamBuilder 直接订阅 StreamController
- 不需要双轨同步（ChangeNotifier 是同步的，StreamController 是异步的）
- 避免状态不一致（两套机制同时维护同一个状态）

## ToolCallCard 可视化规格

每个工具调用在 UI 上显示为一个 "ToolCallCard":

```
┌─────────────────────────────────────────┐
│ 🔧 list_dir(".")                        │  ← 工具名 + 参数摘要
│ ─────────────────────────────────────── │
│ ▶ 正在执行...                            │  ← 执行状态（tool_executing）
│                                         │
│ 或:                                      │
│                                         │
│ ✓ file  README.md                       │  ← 工具结果（完成后）
│ ✓ file  package.json                    │
│ ✓ dir   src/                            │
│ ... [truncated, 3 more entries]         │
└─────────────────────────────────────────┘
```

Card 的状态:
- **等待中**: 灰色边框，显示 "▶ 正在执行..."
- **完成**: 绿色边框，显示工具结果（截断显示）
- **错误**: 红色边框，显示 ERROR 信息

## 事件 → 状态映射

reactLoop 的 OnEvent 回调驱动状态转换:

```dart
void handleEvent(EventKind kind, Map<String, dynamic> payload) {
  switch (kind) {
    case iterationStart:
      _emit(AgentState.loading);
    case assistantMessage:
      if (payload['tool_calls'] != null) {
        _emit(AgentState.tool_executing);
      } else {
        _emit(AgentState.streaming);
      }
    case toolCall:
      // 在 UI 上创建 ToolCallCard
    case toolResult:
      // 更新 ToolCallCard 的结果
    case finish:
      _emit(AgentState.idle);
    case error:
      _emit(AgentState.error);
  }
}
```

## 对应 OpenClaw 的 UI 状态

OpenClaw 的 UI 状态更复杂（有 streaming bridge、partial reply、block reply 等），
但核心概念相同:
- 等待 → 思考 → 行动 → 结果 → 完成
- 本引擎简化为 6 个状态，覆盖了 ReAct 的所有阶段

Phase 3（思考过程可视化）会在这个状态机上扩展:
- 每个状态的持续时间
- 思考链（reasoning chain）的逐步展示
- 工具调用的时间线和依赖关系