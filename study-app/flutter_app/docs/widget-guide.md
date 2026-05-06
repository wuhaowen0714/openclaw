# Widget 指南

## widget 树

```
MaterialApp
  └─ _Bootstrap（判断 API key）
      ├─ _MissingKeyScreen（缺 key 时）
      └─ ChatScreen（有 key 时）
          └─ Scaffold
              ├─ AppBar（workspace + model 信息）
              └─ StreamBuilder<AgentSnapshot>
                  ├─ StatusBar（状态 + spinner + iteration）
                  ├─ MessageList（ListView.builder）
                  │   ├─ UserMessage → _bubble(isUser: true)
                  │   ├─ AssistantMessage → _bubble(isUser: false)
                  │   └─ ToolCallEntry → ToolCallCard
                  └─ InputBox（TextField + 发送按钮）
```

## ChatScreen

主屏幕。`StreamBuilder<AgentSnapshot>` 订阅 controller.stream，将 running 状态传给 InputBox.enabled。

根据 `s.phase` 判断是否 running：
```dart
running = loading || streaming || toolExecuting
```

running 时禁用输入框，防止重复提交。submit() 本身也有 `_running` 保护。

## StatusBar

6 态显示：
- empty/idle: 圆点 + "就绪"/"完成"
- loading/streaming/toolExecuting: spinner + 对应文字
- error: 红色圆点 + 错误消息

`iteration > 0` 时右侧显示迭代次数。

## MessageList

StatefulWidget，持有 ScrollController。

新消息到达时 `didUpdateWidget` 触发自动滚动到底部（`animateTo(maxScrollExtent)`）。

空消息列表时显示占位提示："输入一个任务开始对话"。

Dart 3 pattern matching 做消息分发：
```dart
return switch (m) {
  UserMessage()    => _bubble(m.text, isUser: true),
  AssistantMessage() => _bubble(m.text, isUser: false),
  ToolCallEntry()  => ToolCallCard(entry: m),
};
```

## ToolCallCard

3 态 Card widget：

| status | 边框色 | 图标 | 附加 |
|---|---|---|---|
| pending | grey | spinner | "正在执行..." 文字 |
| done | green | ✓ check_circle | result 文本（截断 600 char） |
| error | red | ✗ error | ERROR result |

参数截断 80 char，result 截断 600 char（引擎层已经 trunc 到 8000 char）。

## InputBox

StatefulWidget，持有 TextEditingController + FocusNode。

Cmd/Ctrl+Enter 快捷键通过 Shortcuts/Actions 实现：
```dart
Shortcuts(
  shortcuts: {
    LogicalKeySet(meta, enter): _SendIntent(),
    LogicalKeySet(control, enter): _SendIntent(),
  },
  child: Actions(
    actions: { _SendIntent: CallbackAction(onInvoke: _submit) },
    child: TextField(...),
  ),
)
```

提交后清空内容 + 保持 focus（方便连续对话）。

## _Bootstrap

StatefulWidget，initState 中：
1. 读 `OPENAI_API_KEY` 环境变量
2. 有 key → 构造 AgentController → ChatScreen
3. 无 key → _MissingKeyScreen

dispose 中关闭 controller 的 StreamController。

## _MissingKeyScreen

缺 API key 的引导页。显示环境变量设置说明 + 重新启动指令。