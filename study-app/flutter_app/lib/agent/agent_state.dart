library;

/// AgentSnapshot — UI 订阅的不可变状态快照。
///
/// 6 个 AgentPhase 对应 docs/ui-state-machine.md 里画的状态机:
///   empty → loading → streaming → tool_executing → idle / error
///
/// 每次 reactLoop 的事件回调都会产生新的 snapshot，UI 通过 StreamBuilder
/// 订阅整体 stream，避免双轨同步（autoplan 决策 #10）。

enum AgentPhase {
  empty,
  loading,
  streaming,
  toolExecuting,
  idle,
  error,
}

/// 一条聊天消息的基类。UI 侧的展示模型，跟 react_loop 内部 messages
/// 不是同一个东西（后者是 wire format）。
sealed class ChatMessage {
  const ChatMessage();
}

class UserMessage extends ChatMessage {
  final String text;
  const UserMessage(this.text);
}

class AssistantMessage extends ChatMessage {
  final String text;
  const AssistantMessage(this.text);
}

/// 工具调用条目 — 对应 ToolCallCard widget 的 3 种状态:
///   pending: 正在执行（灰色边框）
///   done:    完成（绿色边框）+ result 文本
///   error:   错误（红色边框）+ ERROR result
class ToolCallEntry extends ChatMessage {
  final String id;
  final String name;
  final String argumentsRaw;
  final ToolCallStatus status;
  final String? result;

  const ToolCallEntry({
    required this.id,
    required this.name,
    required this.argumentsRaw,
    required this.status,
    this.result,
  });

  ToolCallEntry copyWith({ToolCallStatus? status, String? result}) {
    return ToolCallEntry(
      id: id,
      name: name,
      argumentsRaw: argumentsRaw,
      status: status ?? this.status,
      result: result ?? this.result,
    );
  }
}

enum ToolCallStatus { pending, done, error }

/// UI 订阅的整体快照。每次状态变化都产生新的不可变实例。
class AgentSnapshot {
  final AgentPhase phase;
  final List<ChatMessage> messages;
  final String? errorMessage;
  final int iteration;

  const AgentSnapshot({
    required this.phase,
    required this.messages,
    this.errorMessage,
    this.iteration = 0,
  });

  static const empty = AgentSnapshot(phase: AgentPhase.empty, messages: []);

  AgentSnapshot copyWith({
    AgentPhase? phase,
    List<ChatMessage>? messages,
    String? errorMessage,
    int? iteration,
  }) {
    return AgentSnapshot(
      phase: phase ?? this.phase,
      messages: messages ?? this.messages,
      errorMessage: errorMessage,
      iteration: iteration ?? this.iteration,
    );
  }
}
