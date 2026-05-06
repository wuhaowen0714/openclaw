/// 工具定义 — 对应 OpenClaw 的 customTools 机制。
///
/// 每个工具有名字、描述、参数 JSON Schema，和一个 run 函数。
/// run 函数接收模型解析后的 Map 参数，返回字符串结果。
/// 错误也返回字符串（如 "ERROR: ..."），不抛异常 — 让模型自己看到错误并改策略。
///
/// OpenClaw 对应:
///   - customTools → Tool 定义
///   - materializeBundleMcpToolsForRun → toToolSpec() 转成 OpenAI tool schema
///   - is_error: true tool_result → 错误回喂模型（本引擎用 "ERROR:" 前缀）
class Tool {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  /// 同步或异步执行工具。接收模型返回的 JSON arguments 解析后的 Map。
  /// 返回字符串结果。错误用 "ERROR:" 前缀，不抛异常。
  final Future<String> Function(Map<String, dynamic> args) run;

  const Tool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.run,
  });

  /// 转成 OpenAI function-calling tool spec 格式。
  /// 对应 OpenClaw 的 materializeBundleMcpToolsForRun — 把内部定义转成 wire format。
  Map<String, dynamic> toToolSpec() {
    return {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': parameters,
      },
    };
  }
}