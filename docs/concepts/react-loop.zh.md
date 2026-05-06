---
summary: "ReAct loop 教学(中文,个人学习笔记 — 非发布文档)"
title: "ReAct loop walkthrough (中文)"
---

> 本文件是个人学习用的中文 ReAct 走读,**不是仓库正式发布的文档**。仓库 i18n 规则要求外语文档放在独立的 `openclaw/docs` 发布仓,英文是 source of truth。
>
> 配套阅读:
> - `docs/concepts/agent-loop-walkthrough.zh.md` —— OpenClaw 双层 loop 走读(外层重试 + 内层 ReAct)
> - `docs/concepts/agent-loop.md` —— OpenClaw agent loop 英文 reference

## 0. 你应该带着哪些问题来读

读完之后能回答:

1. ReAct 是什么?为什么是 agent 的事实标准?
2. 经典论文风格的 ReAct(`Thought:` / `Action:` / `Observation:`)和现代 tool-calling 风格(JSON tool_use)有什么区别?**为什么后者赢了?**
3. 一次 ReAct 循环里,消息序列(`messages`)长什么样?谁加了什么 message,什么时候加?
4. 怎么用 50 行代码徒手写一个最小可用的 ReAct loop?
5. ReAct 在哪些场景会失败?怎么缓解?
6. ReAct vs Plan-and-Execute vs Reflexion 各自适合什么?
7. OpenClaw / pi-agent-core 用的是哪种实现?能找到具体哪几行?

---

## 1. ReAct 是什么

**ReAct = Reasoning + Acting**。

来源论文:**ReAct: Synergizing Reasoning and Acting in Language Models**(Yao et al., 2022,Princeton + Google)。

核心想法只有一句:

> 不要让模型一口气想完所有步骤再行动,也不要让它无脑地一次行动一次,而是让它**交替**地"思考一步、行动一步、观察结果、再思考一步"。

伪代码:

```
loop:
    thought = LLM("基于历史,我下一步该想什么?")
    if thought says "done":
        return final_answer
    action = LLM("基于这个想法,我该用哪个工具,参数是什么?")
    observation = run_tool(action)
    history.append(thought, action, observation)
```

### 为什么这是个突破

在 ReAct 之前有两条路线,各有缺陷:

| 路线 | 做法 | 缺陷 |
|---|---|---|
| **Chain-of-Thought (CoT)** | 让模型把推理写成一长段文本 | 全靠模型脑补,**没有外部信息**。一旦事实记错,推理整条链都歪。 |
| **纯 Action(无推理)** | 让模型直接挑工具调用 | 没有"想一下再做"的步骤,容易**乱选工具**,也不会规划多步。 |

ReAct 把两者合一:**推理引导行动,行动反哺推理**。

模型在每一步都能:
- 用工具结果**纠正**自己之前的判断(自己 Google 一下发现 wiki 写错了)
- 用推理**指导**下一次工具调用(我刚刚 ls 了,看到有 README.md,接下来读它)

这种"互相反哺"是 ReAct 的灵魂。

---

## 2. 两种实现风格:Prompt-style vs Tool-calling

ReAct 论文里给的是 **prompt-style**(文本风格),但今天工业界几乎都是 **tool-calling style**(JSON 风格)。理解这个演化对学 agent 很关键。

### 2.1 Prompt-style ReAct(2022 论文风格)

让模型按固定文本格式产出,你写正则解析:

```
Question: 北京到上海的高铁要多久?

Thought: 我需要搜一下高铁时刻
Action: web_search[北京 上海 高铁 时长]
Observation: 北京南到上海虹桥,G 字头列车约 4h18m–5h30m

Thought: 这个范围给定了。我还需要确认是不是直达。
Action: web_search[北京上海高铁 直达]
Observation: G1/G3/G5 等是直达,中间不停或仅停少数大站

Thought: 信息够了
Action: finish[直达高铁约 4 小时 18 分,普通车次最长约 5 小时半]
```

**实现 = 一个解析循环**:

```js
while (true) {
  const reply = await llm(prompt + "\n" + history.join("\n"));
  history.push(reply);
  const action = parseAction(reply);  // 抓 "Action: xxx[args]"
  if (action.name === "finish") return action.args;
  const obs = await runTool(action);
  history.push("Observation: " + obs);
}
```

**优点**:不依赖模型的 native tool calling,任何 LLM 都能跑(包括早期开源模型)。
**缺点**:
- 解析脆弱(模型偶尔忘记格式、加多余空格、用中文冒号 →  正则崩)
- 无并行(一次只能 1 个 Action)
- token 浪费(`Thought:` `Action:` `Observation:` 这些前缀都是 token)
- 无类型安全(`Action: search[北京 上海]` 参数靠空格分,模型一边带逗号一边带分号你就完了)

### 2.2 Tool-calling style ReAct(现代主流)

模型 native 输出 **结构化** 的 tool 调用:

```jsonc
// Assistant 消息(由 LLM 产出)
{
  "role": "assistant",
  "content": [
    { "type": "text", "text": "我需要搜一下高铁时刻" },          // 推理
    { "type": "tool_use",                                          // 行动
      "id": "toolu_01ABC",
      "name": "web_search",
      "input": { "query": "北京 上海 高铁 时长" } }
  ],
  "stop_reason": "tool_use"   // ← 关键:模型告诉 runtime "我要工具结果"
}
```

Runtime 看到 `stop_reason === "tool_use"`,执行工具,把结果以 user message 形式回喂:

```jsonc
// Tool result 消息(由 runtime 加进 history)
{
  "role": "user",
  "content": [
    { "type": "tool_result",
      "tool_use_id": "toolu_01ABC",
      "content": "北京南到上海虹桥,G 字头列车约 4h18m..." }
  ]
}
```

然后继续调模型,直到模型这一次的 `stop_reason === "end_turn"`(没有更多 tool call)。

**优点**:
- 解析完全交给 SDK,你不写正则
- 支持**并行 tool call**(模型一次 emit 多个 tool_use block)
- 类型安全(JSON Schema 定义 input,模型验证)
- token 高效(没有 `Thought:` 前缀,推理就是普通 text block)

**这就是 OpenClaw / pi-agent-core 用的风格**。看 `src/agents/pi-embedded-runner/run.ts:2748-2752`:

```ts
const stopReason = attempt.clientToolCalls
  ? "tool_calls"
  : attempt.yieldDetected
    ? "end_turn"
    : (sessionLastAssistant?.stopReason as string | undefined);
```

`"tool_calls"` / `"end_turn"` 就是 OpenAI/Anthropic SDK 的标准 stop reason。再看 `src/agents/pi-embedded-runner/types.ts:147-154`:

```ts
/** Stop reason for the agent run (e.g., "completed", "tool_calls"). */
stopReason?: string;
/** Pending tool calls when stopReason is "tool_calls". */
pendingToolCalls?: Array<{
  id: string;
  name: string;
  arguments: string;
}>;
```

跟主流 tool-calling 接口完全对齐。

### 2.3 一句话对比

| 维度 | Prompt-style | Tool-calling |
|---|---|---|
| 解析 | 自己写正则 | SDK 给结构化 JSON |
| 并行 | 不支持 | 原生支持 |
| 失败模式 | 格式崩 | input schema 验证错误 |
| 适用模型 | 任何 LLM | 支持 function calling 的 LLM |
| 主流程度 | 教学/复古 | **生产标准** |

---

## 3. 一次循环里 messages 的进化

这是 ReAct 最值得手画一遍的部分。我用一个具体例子拉满:

> 用户问:"列出 src 目录,然后告诉我 README 大致写了什么"

### 第 0 步:初始 messages

```jsonc
[
  { "role": "system", "content": "你是一个 coding agent,有 bash 和 read_file 工具..." },
  { "role": "user", "content": "列出 src 目录,然后告诉我 README 大致写了什么" }
]
```

### 第 1 次模型调用 → assistant 想 + 调 tool

```jsonc
{
  "role": "assistant",
  "content": [
    { "type": "text", "text": "好的,先列出 src" },
    { "type": "tool_use", "id": "t1", "name": "bash", "input": { "cmd": "ls src" } }
  ],
  "stop_reason": "tool_use"
}
```

Runtime 把它 append 进 messages,同时**因为 stop_reason 是 tool_use,不返回给用户,继续 loop**。

### 第 1 次 tool 执行 → tool_result 消息

```jsonc
{
  "role": "user",
  "content": [
    { "type": "tool_result", "tool_use_id": "t1",
      "content": "agents\nchannels\ngateway\nplugins\n..." }
  ]
}
```

### 第 2 次模型调用 → assistant 推理 + 调下一个 tool

```jsonc
{
  "role": "assistant",
  "content": [
    { "type": "text", "text": "src 内容看到了。现在读 README" },
    { "type": "tool_use", "id": "t2", "name": "read_file", "input": { "path": "README.md" } }
  ],
  "stop_reason": "tool_use"
}
```

### 第 2 次 tool 执行 → tool_result 消息

```jsonc
{
  "role": "user",
  "content": [
    { "type": "tool_result", "tool_use_id": "t2",
      "content": "# OpenClaw\n\nOpenClaw is a coding agent ..." }
  ]
}
```

### 第 3 次模型调用 → assistant 给出最终答案,无 tool call

```jsonc
{
  "role": "assistant",
  "content": [
    { "type": "text",
      "text": "src 目录包含 agents、channels、gateway、plugins 等子模块。\nREADME 大致介绍 OpenClaw 是一个 coding agent..." }
  ],
  "stop_reason": "end_turn"   // ← 关键:没有 tool_use,loop 结束
}
```

Runtime 看到 `stop_reason === "end_turn"`,跳出 loop,把这条 assistant 消息的 text 内容返回给用户。

### messages 最终长这样

```
[system, user, assistant#1(tool_use), user(tool_result#1),
                assistant#2(tool_use), user(tool_result#2),
                assistant#3(end_turn)]
```

**重点观察**:

1. tool 结果**放在 user 消息里**(role 是 user)。这是 OpenAI/Anthropic 协议的设计 —— 把 "外部世界给的输入" 都归到 user 角色。
2. 每个 tool_use 有 `id`,tool_result 用 `tool_use_id` 引用,**配对要严格**。任何一对没对上(常见 bug 来源),provider 就报错。看 `src/agents/pi-embedded-runner/run/attempt.tool-call-normalization.ts` 里大量代码就是在处理各种 provider 对 id 命名风格不一(`toolUseId` vs `toolCallId` vs `tool_use_id` vs `tool_call_id`)。
3. **assistant 的"思考"和"调用"在同一条消息里**(同一个 content 数组)。这一点比 prompt-style 更紧凑。

---

## 4. 用 50 行写一个最小 ReAct loop

下面是一个能跑的最小 ReAct(伪 TS,基于 Anthropic SDK 风格的 message 协议):

```ts
type ToolDef = {
  name: string;
  description: string;
  input_schema: object;
  run: (input: any) => Promise<string>;
};

async function reactLoop(
  llm: (messages: Message[]) => Promise<AssistantMessage>,
  tools: ToolDef[],
  userPrompt: string,
  opts: { maxIters?: number } = {},
) {
  const maxIters = opts.maxIters ?? 25;
  const messages: Message[] = [
    { role: "user", content: userPrompt },
  ];

  for (let i = 0; i < maxIters; i++) {
    const assistant = await llm(messages);   // 调模型
    messages.push(assistant);

    if (assistant.stop_reason === "end_turn") {
      return assistant.content
        .filter(b => b.type === "text")
        .map(b => b.text).join("");
    }

    if (assistant.stop_reason === "tool_use") {
      // 找出所有 tool_use blocks(可能并行)
      const toolUses = assistant.content.filter(b => b.type === "tool_use");

      // 并行执行每个 tool
      const toolResults = await Promise.all(toolUses.map(async tu => {
        const tool = tools.find(t => t.name === tu.name);
        if (!tool) {
          return { type: "tool_result", tool_use_id: tu.id,
                   content: `tool ${tu.name} not found`, is_error: true };
        }
        try {
          const out = await tool.run(tu.input);
          return { type: "tool_result", tool_use_id: tu.id, content: out };
        } catch (e) {
          return { type: "tool_result", tool_use_id: tu.id,
                   content: String(e), is_error: true };
        }
      }));

      // tool_result 永远以 user role 回喂
      messages.push({ role: "user", content: toolResults });
      continue;
    }

    throw new Error(`unexpected stop_reason: ${assistant.stop_reason}`);
  }

  throw new Error(`exceeded max iterations (${maxIters})`);
}
```

把这 ~50 行真理解透,你就理解了 ReAct 的所有本质。剩下的所有复杂代码(包括 OpenClaw 那 6000+ 行)都是在围绕这个核心做工程化:错误恢复、并发安全、流式回复、上下文压缩、超时取消、多 provider 兼容、token 计费、安全沙箱……

---

## 5. ReAct 在 OpenClaw / pi-agent-core 里是怎么实现的

### 5.1 OpenClaw 的角色

OpenClaw **不直接实现 ReAct loop**,它依赖 `@mariozechner/pi-agent-core`(在 `package.json` 看到 `"@mariozechner/pi-agent-core": "0.73.0"`)。

OpenClaw 给 pi-agent-core 的输入(简化):

```ts
// src/agents/pi-embedded-runner/run/attempt.ts:1619
const createdSession = await createEmbeddedAgentSessionWithResourceLoader({
  createAgentSession: async (options) => await createAgentSession(options),
  options: {
    cwd,
    tools: sessionToolAllowlist,        // 工具白名单
    customTools: allCustomTools,         // MCP / LSP / client 工具
    // ... model, system prompt, history, ...
  }
});
```

然后:

```ts
// attempt.ts:3015
await abortable(activeSession.prompt(promptForModel));
```

**这一行 `await` 里 pi-agent-core 跑了完整的 ReAct loop**:

```
活动 session 拿到 user prompt
  → 调模型
  → 看 stop_reason
    - end_turn  → 返回
    - tool_use  → 执行工具(走 pi-agent-core 的 tool dispatcher)
                → 把 tool_result 推进 messages
                → 回到"调模型"那一步
  → 重复直到 end_turn 或 max iter
```

OpenClaw 通过 callback 拿到中间事件:
- `params.onPartialReply` —— assistant 的每个 token
- `params.onBlockReply` —— assistant 完成一个 content block(text / tool_use / reasoning)
- `params.onBlockReplyFlush`(`attempt.ts:3093`)—— attempt 结束前 flush 缓冲

OpenClaw 把这些 callback 桥接到自己的 `assistant` / `tool` / `lifecycle` 流(参见 `docs/concepts/streaming.md`)送给 channel。

### 5.2 OpenClaw 在 ReAct loop 之外加了什么

这是真正能体现"这是个生产 agent"的地方。OpenClaw 在 pi-agent-core 的"裸 ReAct"外面套了:

| 层 | 作用 | 代码 |
|---|---|---|
| **Tool call normalization** | 修复不同 provider tool_use_id / arguments 编码差异 | `attempt.tool-call-normalization.ts` |
| **Tool call argument repair** | xAI / OpenRouter 等返回的 malformed args 修复 | `attempt.tool-call-argument-repair.ts` |
| **Tool result truncation** | tool 输出过大时截断保护 token budget | `tool-result-truncation.ts` |
| **History image prune** | 旧轮次的图片丢弃,降低 token | `run/history-image-prune.ts` |
| **Compaction** | context 满了用 LLM 把旧 messages 总结 | `compact.ts` |
| **Auth profile rotation** | API key 失效自动换下一个 | `run/auth-controller.ts` |
| **Model fallback** | 主 model 不行就换 model 再 ReAct 一遍 | `model-fallback.ts` |
| **Plugin hooks** | `before_tool_call` / `after_tool_call` 等拦截点 | 散落 |
| **Streaming bridge** | pi-agent-core 事件 → OpenClaw stream | `subscribeEmbeddedPiSession` |

理解一个 agent 项目,这些"外围层"才是真正的工程难点 —— ReAct 本身只是 50 行内核。

---

## 6. ReAct 的关键设计决策

### 6.1 串行 vs 并行 tool call

**串行**(经典):一次只 emit 一个 tool_use,等 result 回来再下一个。
**并行**(Anthropic Claude 3+ / GPT-4-1106+):同一条 assistant 消息可以 emit 多个 tool_use,runtime 并行执行后用一条 user 消息回喂多个 tool_result。

OpenClaw `parallel_tool_calls=true` 是默认开的(见 `src/agents/pi-embedded-runner/extra-params.ts:327`)。

**何时该关并行**:工具之间有依赖(读了 ls 才知道读哪个文件)。模型大多数时候自己会避免并行有依赖的工具,但你也可以在 prompt 里明确指示。

### 6.2 max iterations 的上限

防止模型陷入死循环(例如反复调同一个失败的工具)。

```ts
// run.ts:782
const MAX_RUN_LOOP_ITERATIONS = resolveMaxRunRetryIterations(profileCandidates.length);
```

注意这个**是外层 retry 的上限**,不是 ReAct 内层的工具调用上限。pi-agent-core 内部应该也有自己的 max iter(具体看依赖源码)。

### 6.3 什么时候是"想"什么时候是"做"

模型自己决定,不需要你强制。但好的 system prompt 会引导:

```
For each step, briefly explain your reasoning, then call the appropriate tool.
After receiving a tool result, decide whether you have enough info to answer
or need another tool call.
```

OpenClaw 把这类 prompt 工程的细节藏在 `system-prompt.ts` 和 skills 系统里。

### 6.4 tool 失败要不要让模型看到

**要**。这是 ReAct 的精髓 —— 模型自己读到 "permission denied / file not found" 后会调整策略(换路径、降级、问用户)。

OpenClaw 的做法:tool 抛错时把 error message 包成 `is_error: true` 的 `tool_result`(`attempt.ts:1510` 附近 `before_tool_call` hook 也是这套机制),让模型看到。

### 6.5 安全:tool 拦截点

任何能跑 bash 的 agent 都需要拦截点。OpenClaw 通过 plugin hook:

- `before_tool_call`:可以 `{ block: true }` 拒绝执行
- `after_tool_call`:可以改 result(脱敏)

参见 `docs/concepts/agent-loop.md` 的 plugin hooks 列表。

---

## 7. ReAct 的失败模式(要会识别)

### 7.1 死循环:反复调同一个失败工具

模型看到 tool error 不改策略,继续用同样参数调用。

**缓解**:
- max iter 强制中断
- 在 system prompt 里明示 "if a tool fails twice with similar args, try a different approach"
- OpenClaw 的 `post-compaction-loop-guard.ts` 是这类 guard 的例子

### 7.2 不可见状态漂移

工具改了外部世界状态(写了文件 / 启动了进程),但模型没记住。后面的轮次基于旧的世界模型推理。

**缓解**:
- 状态变更后强制 emit 一个 "current state" tool result
- 或在 system prompt 里要求 "before each action, briefly state your assumed state"

### 7.3 上下文爆炸

ReAct 的 messages 是单调增长的。每轮都加 assistant + tool_result,几十轮后就撑爆 window。

**缓解**:**Compaction**(参见 `agent-loop-walkthrough.zh.md` 第 8 节)。OpenClaw 用 LLM 把旧 messages 总结成一段,替换原始消息。

### 7.4 过度推理(over-thinking)

模型一直在 `text` block 里写思考,迟迟不出 `tool_use` 或最终答案。

**缓解**:
- 限制 reasoning token budget
- OpenClaw 有 `reasoningOnlyRetryInstruction`(`run.ts:1080`):检测到只输出 reasoning 没有真实 tool call/text 答案,注入 instruction 重试

### 7.5 过早 finish(under-thinking)

模型只调了 1 个工具就给最终答案,但其实信息不够。

**缓解**:
- system prompt 引导(列出"什么算 enough info")
- 给模型多步任务的 few-shot 例子
- 评测发现的 case 写进 prompt

---

## 8. ReAct 与其他 agent loop 范式

### 8.1 Plan-and-Execute

**做法**:模型先一口气产出完整 plan(步骤 1, 2, 3, ...),然后执行器逐步跑,每步可能再调模型。

**vs ReAct**:
- 优势:适合**长任务**(plan 给了"鸟瞰",不会 lose track)
- 劣势:**不适合不确定性高的任务**(plan 在第一步就定死,执行中发现错了不容易改)
- 实践中常常**混用**:plan 里的每个 step 内部跑 ReAct

### 8.2 Reflexion

**做法**:agent 完成任务后**自我评估**("我刚刚做对了吗?"),把反思写进下一次 episode 的 prompt 里。

**vs ReAct**:Reflexion 是**跨 episode** 的学习机制,ReAct 是**单 episode 内** 的执行机制。两者**正交**,可以叠加。

### 8.3 Tree-of-Thoughts

**做法**:每一步推理 fork 出多个候选,搜索树,再 back-track。

**vs ReAct**:成本高得多(搜索每个节点都要调模型)。一般用于推理深度极重的任务(数学竞赛、复杂规划)。日常 coding agent 用不到。

### 8.4 MRKL / ToolFormer

属于"会用工具的 LLM"的早期方案(2022 上半年)。ReAct 借鉴了它们的工具调用思想,加了"显式推理"和"循环结构"。今天它们基本被 ReAct + tool calling 取代。

### 8.5 一张图总结

```
                          单步             多步
                ┌─────────────┬───────────────────┐
   无显式推理   │    MRKL     │   纯 Action loop   │
                ├─────────────┼───────────────────┤
   有显式推理   │    CoT      │     ★ ReAct ★     │
                ├─────────────┼───────────────────┤
   多候选搜索   │  Best-of-N  │  Tree-of-Thoughts  │
                ├─────────────┼───────────────────┤
   跨任务学习   │   ICL +     │     Reflexion      │
                │ Few-shot    │  (ReAct + 反思)    │
                └─────────────┴───────────────────┘
```

ReAct 占据了"多步 + 有推理"这个甜蜜点 —— 这是绝大多数实用 agent 任务的形状。

---

## 9. 自己实现一遍,理解才会扎实

练习建议:

### Lv 1:复刻 ReAct 论文

挑一个简单任务(HotpotQA 单条问题),用 prompt-style ReAct 实现。强迫自己写 `Thought:` `Action:` 解析。

收获:理解为什么解析脆弱,理解为什么大家都换到 tool-calling。

### Lv 2:写第 4 节那个 50 行 loop

接 Anthropic / OpenAI SDK,实现一个能调 2 个工具(`bash` + `read_file`)的最小 agent。

收获:理解 messages 数组的演化、stop_reason 的意义、tool_use_id 配对。

### Lv 3:加上失败处理

- max iter
- tool error 包成 is_error
- abort signal
- 一次只允许 N 个并行 tool call

收获:理解工程化的"保命层"。

### Lv 4:加 streaming

把每个 token 流式打到终端。让用户看到 agent 边想边做。

收获:理解 OpenClaw 的 `onPartialReply` / `onBlockReply` 为什么这样设计。

### Lv 5:加 compaction

messages 长度超过阈值,调一次 summarize prompt 把前 N 条压缩成一条。

收获:理解 OpenClaw `compact.ts` 在解决什么问题。

### Lv 6:阅读 OpenClaw 真实代码

带着前 5 步的 mental model,去 `src/agents/pi-embedded-runner/run/attempt.ts` 找对应的工业化版本。看每一段在保护哪种失败模式。

---

## 10. 推荐阅读

### 论文 / 文章

- **ReAct 原论文** ([arxiv.org/abs/2210.03629](https://arxiv.org/abs/2210.03629)) —— 必读
- **Toolformer**(Schick et al., 2023)—— ReAct 的工具调用先驱
- **Reflexion**(Shinn et al., 2023)—— 反思机制
- **Tree-of-Thoughts**(Yao et al., 2023)—— 同一作者后续

### 代码

- **本仓 OpenClaw**:
  - `docs/concepts/agent-loop-walkthrough.zh.md` —— 配套的双层 loop 走读
  - `src/agents/pi-embedded-runner/run/attempt.ts:3015` —— 模型调用入口
  - `src/agents/pi-embedded-runner/run.ts:1032` —— 重试 loop
  - `src/agents/pi-embedded-runner/run/attempt.tool-call-normalization.ts` —— tool call 处理
- **官方 SDK 文档**:
  - Anthropic Tool Use:[docs.anthropic.com/en/docs/build-with-claude/tool-use](https://docs.anthropic.com/en/docs/build-with-claude/tool-use)
  - OpenAI Function Calling:[platform.openai.com/docs/guides/function-calling](https://platform.openai.com/docs/guides/function-calling)
- **简洁参考实现**:
  - LangChain 的 `AgentExecutor`(看一个版本就够,别陷进去)
  - smol-ai-developer / smol-agent —— 几百行的小 agent

### 怎么继续学 OpenClaw

1. 把 [agent-loop-walkthrough.zh.md](/concepts/agent-loop-walkthrough.zh) 第 11 节"接下来读什么"的清单走一遍
2. 在本地跑 `pnpm openclaw` 用一个简单任务,开 trace log,**亲眼看一次完整的事件流**
3. 选一个失败模式(比如让 agent 调一个不存在的工具),看 OpenClaw 怎么 graceful degradation

---

## 附:常见误解澄清

| 误解 | 纠正 |
|---|---|
| "ReAct 必须有 `Thought:` `Action:` 这种格式" | 那是论文实现细节,**不是 ReAct 的本质**。tool-calling 风格也是 ReAct。 |
| "ReAct 的循环是固定 N 步" | 不是,**模型自己决定何时停**(emit `end_turn` / 不再 emit tool_use)。max iter 只是兜底。 |
| "ReAct 的 tool_result 是 assistant 角色" | **错。tool_result 是 user 角色**(代表"外部世界给的输入")。 |
| "agent 框架那么复杂,ReAct 一定也很复杂" | 内核就 50 行。复杂的是**外围**:错误恢复、并发、流式、压缩、安全、多 provider。 |
| "并行 tool call 总是更好" | **不是**。工具有依赖时该串行。让模型自己判断,大多数时候会做对。 |
| "ReAct 已经过时,被 Plan-and-Execute / Reflexion 取代" | **没有**。ReAct 是执行单元,后两者是更上层的策略。它们正交。 |

---

**记住一件事就够**:ReAct 内核 = 一个 while 循环,反复"调模型 → 看 stop_reason → 执行工具 → 把结果回喂",直到模型说 done。所有其它东西都是为了让这个循环在真实世界里**不崩**。
