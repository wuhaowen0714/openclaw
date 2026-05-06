# 快速开始

> 从零开始运行 FlutterAgent 的步骤。

## 前置条件

1. **Dart SDK** >= 3.0.0（Flutter 自动包含）
2. **API Key**: 设置 `OPENAI_API_KEY` 环境变量（支持 GLM 等兼容 endpoint）
3. **可选**: 设置 `OPENAI_BASE_URL` 指向兼容 endpoint（如 GLM 的 API 地址）

## 安装

```bash
cd study-app/flutter_agent
dart pub get
```

## Phase 0.5: GLM API 兼容性验证

在正式运行之前，先验证 GLM 的 OpenAI-compatible API 是否支持 tool_calls:

```bash
# 设置环境变量
export OPENAI_API_KEY="your-glm-api-key"
export OPENAI_BASE_URL="https://open.bigmodel.cn/api/paas/v4"  # GLM endpoint

# 运行验证脚本
dart run test/smoke_glm.dart
```

验证脚本会测试:
1. 带工具定义的请求 → 看模型是否返回 `finish_reason: "tool_calls"` + tool_use
2. 纯文本请求 → 看模型是否正常返回 `finish_reason: "stop"`

如果 GLM 不支持 tool_calls → 需要换模型（GPT-4o-mini / Claude Haiku）。
如果 GLM 不支持 SSE → Phase 3 先走非流式路径。

## CLI 运行

```bash
# 基本用法
dart run lib/cli/main.dart --task "看看当前目录是什么项目" --root /path/to/sandbox

# 指定模型
dart run lib/cli/main.dart --task "读一下 README.md" --model GLM-5.1 --root /path/to/sandbox

# 详细模式（打印每次 API 调用）
dart run lib/cli/main.dart --task "列出 src 目录的内容" --verbose --root /path/to/sandbox

# 自定义迭代上限
dart run lib/cli/main.dart --task "分析项目结构" --max-iters 10 --root /path/to/sandbox
```

## CLI 参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| --task | 无（必填） | 用户给 agent 的任务 |
| --root | 当前目录 | sandbox 目录（工具的根路径） |
| --model | GLM-5.1 | 使用的模型名 |
| --max-iters | 15 | ReAct 循环最大迭代次数 |
| --verbose | false | 打印详细的 API 调用日志 |

## 环境变量

| 变量 | 必填 | 说明 |
|---|---|---|
| OPENAI_API_KEY | 是 | API key（支持 GLM 等兼容 endpoint） |
| OPENAI_BASE_URL | 否 | 自定义 API endpoint（默认 OpenAI） |

## 输出示例

```
[iter 0] calling GLM-5.1...
[tool_call] list_dir(".")
[list_dir] dir  src
[list_dir] file README.md
[list_dir] file package.json
[iter 1] calling GLM-5.1...
[finish] This appears to be a Dart project called FlutterAgent...
```

## 常见问题

### API key 无效
```
ERROR: 401 Unauthorized — API key 无效。请设置 OPENAI_API_KEY 环境变量。
```
设置正确的 API key:
```bash
export OPENAI_API_KEY="your-key"
```

### 模型不支持 tool_calls
如果模型返回 `finish_reason: "stop"` 但没有调用工具，说明模型不支持 function-calling。
换用支持 tool_calls 的模型（GPT-4o-mini / Claude Haiku）。

### 路径越界
```
ERROR: path ../../etc/passwd escapes sandbox /path/to/sandbox
```
这是 resolveSafe 的安全防护 — 工具只能在 sandbox 目录内操作。

### max_iters 耗尽
```
StateError: exceeded max iterations (15)
```
Agent 在 15 轮内没有给出最终答案。增加 --max-iters 或简化任务。

## 下一步

- **Phase 2**: Flutter 桌面 UI（参考 ui-state-machine.md）
- **Phase 3**: 思考过程可视化（ToolCallCard + 时间线）
- **Phase 4**: Skill 插件系统（未来扩展）