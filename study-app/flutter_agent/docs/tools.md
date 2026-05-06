# 工具系统文档

> 精读 `lib/tools/` 目录，理解三个基础工具的实现和安全设计。

## 工具注册模式

每个工具是一个 `Tool` 对象，用 factory 函数创建:

```dart
final tools = [
  makeListDirTool(root: '/path/to/sandbox'),
  makeReadFileTool(root: '/path/to/sandbox'),
  makeBashTool(cwd: '/path/to/sandbox'),
];
```

`Tool` 包含:
- `name`: 工具名（模型用这个名字调工具）
- `description`: 描述（告诉模型什么时候该用）
- `parameters`: JSON Schema（定义参数格式）
- `run`: 执行函数（`Future<String> run(Map<String, dynamic> args)`）

`toToolSpec()` 把 Tool 转成 OpenAI function-calling wire format:
```json
{
  "type": "function",
  "function": {
    "name": "bash",
    "description": "Run a shell command...",
    "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}}}
  }
}
```

对应 OpenClaw: `customTools` → `materializeBundleMcpToolsForRun()`。

## 安全设计

### 路径越界防护（resolveSafe）

`list_dir` 和 `read_file` 用 `resolveSafe(base, rel)` 防止路径逃逸:

```dart
String resolveSafe(String base, String rel) {
  final target = p.normalize(p.join(base, rel));
  if (!target.startsWith('$normalizedBase/')) {
    return 'ERROR: path $rel escapes sandbox $normalizedBase';
  }
  return target;
}
```

防止 `../../etc/passwd` 之类。bash 工具不做路径防护（它可以跑任意命令）。

### 输出截断（truncate）

所有工具输出截断到 8000 字符，保留 head + tail:

```dart
String truncate(String s, int limit) {
  if (s.length <= limit) return s;
  final head = limit ~/ 2;
  final tail = limit - head;
  return '${s.substring(0, head)}\n... [truncated ...]\n${s.substring(s.length - tail)}';
}
```

为什么 head + tail？因为文件错误通常在尾部（如 stack trace），只截 head 模型看不到。

对应 OpenClaw: `tool-result-truncation.ts`。

### 错误回喂模型

所有错误返回字符串，不抛异常:

- 工具找不到 → `ERROR: tool 'xxx' not found`
- 参数格式错误 → `ERROR: malformed JSON args: ...`
- 工具执行异常 → `ERROR: ExceptionType: message`

这让模型自己看到错误并改策略 — 这是 ReAct 的精髓。

对应 OpenClaw: `is_error: true` 的 tool_result。

## bash 工具特殊设计

bash 是最危险也最强大的工具:

### 平台适配

```dart
final shellCmd = Platform.isWindows
    ? ['cmd', '/S', '/C', cmd]
    : ['sh', '-c', cmd];
```

不是 Python demo 的直接翻译（Python 用 `shell=True`）。

### 超时处理

```dart
Future.timeout(Duration(seconds: timeout), onTimeout: () {
  process.kill();  // 杀进程 — 防止僵尸进程泄漏
  return ['', 'ERROR: command timed out...', -1];
});
```

Python demo 的 `subprocess.run(timeout=30)` 在 Dart 中没有直接等价物，
需要 `Process.start` + `Future.timeout` + 手动 kill。

### 安全审计

```dart
print('[bash] $cmd');  // CLI 中打印即将执行的命令
```

Phase 2 会添加命令确认 UI。Phase 1 先 log 所有 bash 命令。

### 并发上限

bash 并发上限在 `reactLoop` 层面控制（暂未实现 Semaphore），
当前是串行执行所有 tool calls。

## 对应 OpenClaw 的工具系统

OpenClaw 的工具系统远比这复杂:
- 20+ 个工具（read, write, edit, grep, find, ls, exec, process, web_search, ...）
- plugin/skill system 动态注册
- MCP protocol 对接外部工具
- sandbox + 权限校验 + 结果截断 + 二进制编码处理

本引擎只有 3 个基础工具，对应 OpenClaw 的核心 subset。
理解这个简化版 = 理解工具系统的最小形状。