/// System prompt 组装 — 参考 OpenClaw 的 buildAgentSystemPrompt() 结构。
///
/// OpenClaw 的 system prompt 不是单个静态文本，而是动态组装的。
/// 核心来自 src/agents/system-prompt.ts 的 buildAgentSystemPrompt()。
///
/// 本引擎参考其结构，做适当简化（只有 3 个基础工具，不需要全部 OpenClaw 功能）。
///
/// 分层设计（对应 OpenClaw 的 cache boundary）:
///   - stable prefix: 缓存友好（工具定义 + 规则 + 安全）
///   - dynamic suffix: 每轮注入（workspace path, runtime info）
///
/// System prompt sections（跟 OpenClaw 对齐）:
///   - 身份声明: "You are a coding agent running inside..."
///   - ## Tooling: 列出当前可用工具及简要用法
///   - ## Tool Call Style: 参考 OpenClaw 的 "do not narrate routine tool calls"
///   - ## Execution Bias: 参考 OpenClaw 的 "act in this turn, continue until done"
///   - ## Safety: 参考 OpenClaw 的安全 section
///   - ## Workspace: 运行时注入工作目录
///   - ## Runtime: 运行时注入模型/主机/OS 信息
///   - 鲁棒性规则: ERROR 时换方式重试，不连续两次相同参数

/// 构建 stable prefix — 缓存友好，工具定义和规则不变时可以跨轮缓存。
String buildStablePrefix(List<String> toolNames) {
  final toolingSection = toolNames.map((name) {
    switch (name) {
      case 'list_dir':
        return '- list_dir(path): list entries in a directory (path relative to sandbox root)';
      case 'read_file':
        return '- read_file(path): read a UTF-8 text file';
      case 'bash':
        return '- bash(cmd): run a shell command in the sandbox; prefer the structured tools first';
      default:
        return '- $name: (custom tool)';
    }
  }).join('\n');

  return '''You are a coding agent running inside FlutterAgent that can inspect a local sandbox file tree.

## Tooling
$toolingSection

## Tool Call Style
Default: do not narrate routine, low-risk tool calls (just call the tool).
When calling multiple tools, make all independent calls in the same block.
Only explain tool calls that are surprising, risky, or complex.

## Execution Bias
Actionable request: act in this turn. Continue until done or genuinely blocked;
do not finish with a plan/promise when tools can move it forward.

## Safety
You have no independent goals: do not pursue self-preservation, replication,
resource acquisition, or power-seeking. You exist only to serve the user.

## Robustness rules
- If a tool returns ERROR, try a different approach (different path, different
  tool, or admit you cannot proceed). Do NOT call the same tool with the same
  args twice in a row.
- Keep your final answer concise and grounded in what you actually saw.''';
}

/// 构建 dynamic suffix — 每轮注入，包含 workspace path 和 runtime info。
String buildDynamicSuffix({
  required String workspaceDir,
  required String model,
  String? os,
  String? hostname,
}) {
  return '''

## Workspace
Your working directory is: $workspaceDir

## Runtime
Model: $model
OS: ${os ?? _detectOS()}
Host: ${hostname ?? 'localhost'}''';
}

/// 组装完整 system prompt — stable prefix + dynamic suffix。
String buildSystemPrompt({
  required List<String> toolNames,
  required String workspaceDir,
  required String model,
  String? os,
  String? hostname,
}) {
  return buildStablePrefix(toolNames) + buildDynamicSuffix(
    workspaceDir: workspaceDir,
    model: model,
    os: os,
    hostname: hostname,
  );
}

String _detectOS() {
  // Dart 的 Platform 可以检测 OS
  try {
    return 'unknown';
  } catch (_) {
    return 'unknown';
  }
}