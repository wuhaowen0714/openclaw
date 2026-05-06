# ReAct Demo (Python + OpenAI SDK)

可以跑的最小 ReAct loop。配套学习文档:

- `docs/concepts/react-loop.zh.md` — ReAct 范式讲解
- `docs/concepts/agent-loop-walkthrough.zh.md` — OpenClaw 双层 loop 走读

> 本目录是个人学习沙盒,不是 OpenClaw 仓库的功能代码。

---

## 快速开始

```bash
cd study
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export OPENAI_API_KEY=sk-...

# 默认任务:看看当前目录是什么项目
python -m react_demo.main

# 自定义任务
python -m react_demo.main \
    --task "find all Python files and count total lines" \
    --root .

# verbose:看每一轮 messages 演化
python -m react_demo.main --verbose

# 换模型
python -m react_demo.main --model gpt-4o
```

环境变量:
- `OPENAI_API_KEY` 必填
- `OPENAI_BASE_URL` 可选(走代理或兼容 endpoint 时)

---

## 文件结构

```
study/
├── react_demo/
│   ├── __init__.py
│   ├── core.py    # ReAct loop 核心(对应文档第 4 节伪 TS)
│   ├── tools.py   # list_dir / read_file / bash 三个工具
│   └── main.py    # CLI 入口、system prompt、事件 logger
├── requirements.txt
└── README.md
```

精读顺序:`core.py` → `tools.py` → `main.py`。

---

## 核心:`core.py` 的 `react_loop`

完整流程就这一个 `for` 循环:

```
for i in 0..max_iters:
    resp = openai.chat.completions.create(messages, tools=...)
    msg = resp.choices[0].message
    messages.append(msg)

    if finish_reason == "stop":
        return msg.content                    # 完成
    if finish_reason == "tool_calls":
        for tc in msg.tool_calls:
            result = run_tool(tc)
            messages.append({role: "tool", tool_call_id: tc.id, content: result})
        continue
```

去掉注释、错误处理、event hook,精确就是文档第 4 节那 50 行伪 TS 代码的 Python 翻译。

---

## 与 OpenClaw 的设计对应

每个设计选择在 OpenClaw 里都能找到对应:

| Demo | OpenClaw |
|---|---|
| `react_loop()` | pi-agent-core 的 `session.prompt()`(被 await 一行带过) |
| `on_event` callback | OpenClaw 的 `onPartialReply` / `onBlockReply` / `onBlockReplyFlush`(`attempt.ts:3093`) |
| `Tool` dataclass + `to_openai_tool_spec` | `customTools` + `materializeBundleMcpToolsForRun()`(`attempt.ts:1619`) |
| 把 tool error 包成 result(不抛) | OpenClaw 同样,通过 `is_error: true` 的 tool_result(`attempt.ts:1510` 附近) |
| `max_iters` 兜底 | `MAX_RUN_LOOP_ITERATIONS`(`run.ts:782`)+ pi-agent-core 内部上限 |
| `parallel_tool_calls=True` | OpenClaw 默认开,见 `extra-params.ts:327` |
| 路径越界防护 / 输出截断 | OpenClaw 的 sandbox + `tool-result-truncation.ts` |
| **没有的**:retry / model fallback / compaction / streaming bridge | OpenClaw 的 `run.ts:1032` 外层 while + `compact.ts` + `model-fallback.ts` 等 |

理解这张表 = 理解"50 行内核 vs 6000 行工程化"的边界在哪。

---

## 可观察性:看 ReAct 真的在做什么

不带 `--verbose` 的输出长这样:

```
task:  List the top-level files in the current directory and tell me what kind of project this is in 2-3 sentences.
root:  /Users/you/somewhere
model: gpt-4o-mini
tools: list_dir, read_file, bash
---
  → list_dir({"path":"."})
  ← file 	README.md
  → read_file({"path":"README.md"})
  ← # OpenClaw
---
FINAL ANSWER:
This appears to be the OpenClaw project — a coding agent framework written in TypeScript ...
```

带 `--verbose` 你会看到每一轮的 finish_reason、assistant 的推理 text、tool_use args、tool result preview,以及 messages history 长度的增长。这是学 ReAct 最直接的教学手段 —— 你不再是看抽象的概念,而是看 messages 数组真的长成什么样、每一步加了什么。

---

## 推荐练习路径

跟着学习文档第 9 节那 6 级走:

1. **Lv 1**:用 prompt-style(`Thought:` / `Action:` / `Observation:` 解析)再写一遍同一个 demo,体会现代 tool-calling 协议的优势。
2. **Lv 2**:本仓的 `core.py` 就是这一级的成品 —— 读懂它。
3. **Lv 3** 加保护:
   - 把"同一个 tool 同一组 args 连续 2 次"检测出来直接 return
   - 把 `subprocess` 的 `cmd` 加个黑名单(`rm -rf` / `:(){ :|:& };:` 等)
   - 用 `signal` / `AbortController` 等价物支持外部 abort
4. **Lv 4** 加 streaming:把 `client.chat.completions.create(..., stream=True)` 接上,token-by-token 打印。这一步最能感受 OpenClaw 为什么把 `onPartialReply` 做成那样。
5. **Lv 5** 加 compaction:messages 长度超阈值时,调一次 summarization prompt 把前 N 条压成一条。
6. **Lv 6** 回到 OpenClaw 源码,带着这套 mental model 读 `src/agents/pi-embedded-runner/run/attempt.ts`。

---

## 注意事项

- 这个 demo **没做严格的安全沙箱**。`bash` 工具能跑任意命令(虽然限定了 cwd),`read_file` 只做了简单的路径越界防护。在不可信任务上不要给它敏感目录的 root。
- OpenAI 协议的 tool result 是 `role: "tool"` 消息,Anthropic 协议是 user message + `tool_result` block。两者**等价**,只是 wire format 不同。学习文档第 3 节用的是 Anthropic 风格的例子,这里 demo 用的是 OpenAI 风格 —— 把这两份对照看,你就理解了 protocol 设计的共通点。
- `parallel_tool_calls=True` 时,模型可能在一条 assistant message 里 emit 多个 tool_use。本 demo 是**串行**执行它们的(简单 for 循环)。真正的并行需要 `asyncio` + `await asyncio.gather(...)`,作为练习题留给你。
