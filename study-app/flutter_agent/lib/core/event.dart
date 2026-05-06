/// 事件系统 — 对应 OpenClaw 的多层事件上报机制。
///
/// OpenClaw 用 onPartialReply / onBlockReply / onBlockReplyFlush 回调上报事件。
/// 本引擎用通用 OnEvent 回调，概念上等价 —— 都是把 loop 内部状态暴露给外部。
///
/// EventKind 完整列表（7 种 + 1 种新增 error）:
///   - iteration_start: 每轮开始，附带 iteration 编号和 history 长度
///   - api_request: 发给模型的原始请求（verbose 时记录）
///   - api_response: 模型返回的原始响应（verbose 时记录）
///   - assistant_message: 模型回复的摘要（finish_reason + text + tool_calls）
///   - tool_call: 工具被调用（id + name + arguments）
///   - tool_result: 工具执行结果（id + result）
///   - finish: 循环结束（text）
///   - error: 异常终止（length/content_filter/超时等）
///
/// 缓存友好的分层设计（对应 OpenClaw 的 cache boundary）:
///   - iteration_start/tool_call/tool_result/finish 是核心事件，每轮都发
///   - api_request/api_response 是 verbose 事件，只在 logRawApi=True 时发
typedef EventKind = String;

typedef OnEvent = void Function(EventKind kind, Map<String, dynamic> payload);

const EventKind iterationStart = 'iteration_start';
const EventKind apiRequest = 'api_request';
const EventKind apiResponse = 'api_response';
const EventKind assistantMessage = 'assistant_message';
const EventKind toolCall = 'tool_call';
const EventKind toolResult = 'tool_result';
const EventKind finish = 'finish';
const EventKind error = 'error';