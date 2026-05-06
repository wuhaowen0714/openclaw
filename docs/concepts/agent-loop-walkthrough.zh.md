---
summary: "Agent loop 教学走读(中文,个人学习笔记 — 非发布文档)"
title: "Agent loop walkthrough (中文)"
---

> 本文件是个人学习用的中文走读,**不是仓库正式发布的文档**。仓库 i18n 规则要求外语文档放在独立的 `openclaw/docs` 发布仓,英文是 source of truth。本仓正式参考文档见 `docs/concepts/agent-loop.md`(英文,reference 风格)。本文走的是 tutorial / 代码逐层剖析风格。
>
> 所有引用都是仓库根相对路径 + 行号,例如 `src/agents/pi-embedded-runner/run.ts:1032`,可以直接打开跳转。

## 0. 这份文档想回答什么

读完之后,你应该能在脑子里回放这个故事:

> 用户在 Telegram 发一句"列出 src 然后读 README.md" → OpenClaw 是怎么从这条消息走到"调模型 → 模型决定调 bash → 跑 bash → 把输出回喂模型 → 模型决定再读文件 → 跑读文件 → 模型生成最终回复 → 流式发回 Telegram"这条完整链路的。

文档中所有 file:line 引用都是验证过的(在写文档时直接读了源码确认)。文件偶尔会更新,但函数名相对稳定 —— 找不到行号就 `grep -n '函数名'` 就行。

---

## 1. 大图:三层抽象

OpenClaw 把 agent loop 拆成三层,每层只管自己那一层的事:

```
┌─────────────────────────────────────────────────────────┐
│  Layer 1  CLI / Channel 入口                            │
│  src/agents/agent-command.ts                            │
│  - agentCommand()             :1323   CLI/本地受信任    │
│  - agentCommandFromIngress()  :1343   网络入口必须显式  │
│  - agentCommandInternal()     :441    真正干活          │
│  - deliverAgentCommandResult():1282   把回复送回 channel │
└──────────────────────────┬──────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│  Layer 2  Model fallback / 重试包装                      │
│  src/agents/model-fallback.ts                           │
│  - runWithModelFallback()                               │
│    在多个 provider/model 之间做兜底,例如主 model 出错   │
│    就自动切到备选 model 重跑                              │
└──────────────────────────┬──────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│  Layer 3  Embedded runner(真正的 agent loop)            │
│  src/agents/pi-embedded-runner/                         │
│  - run.ts:336   runEmbeddedPiAgent()    持有 while 循环  │
│  - run.ts:1032  while (true) { ... }    主循环本体       │
│  - run/attempt.ts:627   runEmbeddedAttempt()            │
│      = "一次尝试" — 一次模型对话往返                      │
└─────────────────────────────────────────────────────────┘
```

**记住一个区分**:
- **run loop**(`run.ts:1032`)= 重试/失败转移层。一次 turn 失败了在这里换 profile/换 model 重跑。
- **attempt**(`attempt.ts:627`)= 一次具体的模型调用过程。装 prompt → 调模型 → 流式收 → 工具调用都在 pi-agent-core 内部循环。

实际上"agent → 模型 → 工具 → 模型 → ..."这个最常见意义上的"loop"**不在 OpenClaw 的代码里**,而是在依赖 `@mariozechner/pi-coding-agent` 内部。OpenClaw 的 while 循环主要负责**重试与失败恢复**。

这是一个反直觉但很重要的事实 —— 后面会展开。

---

## 2. 入口:`agentCommand`

打开 `src/agents/agent-command.ts:1323`:

```ts
export async function agentCommand(
  opts: AgentCommandOpts,
  runtime: RuntimeEnv = defaultRuntime,
  deps?: CliDeps,
) {
  return await agentCommandInternal(
    {
      ...opts,
      senderIsOwner: opts.senderIsOwner ?? true,
      allowModelOverride: opts.allowModelOverride ?? true,
    },
    runtime,
    deps,
  );
}
```

这是一个**信任语义**的薄壳:
- `agentCommand` —— 给 CLI / 本地用的。默认 `senderIsOwner: true`(完全信任)。
- `agentCommandFromIngress`(`:1343`)—— 给 HTTP/WebSocket ingress 用的。必须**显式**传 `senderIsOwner` 和 `allowModelOverride`,否则抛错。这样网络入口不会"意外"继承本地的信任默认值。

这一层不做实际工作,只做信任边界声明。

下面就进入 `agentCommandInternal`(`:441`),它做的事按顺序大致是:

1. 解析 model + thinking/verbose/trace 默认值
2. 加载 skills snapshot
3. 调用 `runWithModelFallback`(`:973` 处使用)套一层兜底
4. 兜底里面调 `runEmbeddedPiAgent`(进入 Layer 3)
5. 拿到 payloads 后调 `deliverAgentCommandResult`(`:1282`)送回 channel

---

## 3. 核心 while 循环:`run.ts:1032`

这是整个 agent loop 最关键的一段。打开 `src/agents/pi-embedded-runner/run.ts`:

```ts
// :782
const MAX_RUN_LOOP_ITERATIONS = resolveMaxRunRetryIterations(profileCandidates.length);

// :1032
while (true) {
  if (runLoopIterations >= MAX_RUN_LOOP_ITERATIONS) {
    // 重试上限耗尽,返回错误
    return handleRetryLimitExhaustion({ ... });
  }
  runLoopIterations += 1;

  // 1. 组装 prompt(可能附加 retry instruction)
  const basePrompt = nextAttemptPromptOverride ?? params.prompt;
  const promptAdditions = [
    ackExecutionFastPathInstruction,
    planningOnlyRetryInstruction,
    reasoningOnlyRetryInstruction,
    emptyResponseRetryInstruction,
    compactionContinuationRetryInstruction,
  ].filter(Boolean);
  const prompt = promptAdditions.length > 0
    ? `${basePrompt}\n\n${promptAdditions.join("\n\n")}`
    : basePrompt;

  // 2. 跑一次 attempt(进入 attempt.ts:627)
  const rawAttempt = await runEmbeddedAttemptWithBackend({ ... });

  // 3. 看 attempt 结果决定 continue / return
  if (preflightRecovery?.handled)               continue;  // ~:1405
  if (authRetryPending)                          continue;  // ~:1849
  if (decision.action === "rotate_profile")      continue;  // ~:1971
  if (assistantFailoverOutcome.action === "retry") continue; // ~:2182
  if (nextPlanningOnlyRetryInstruction && ...)   continue;  // ~:2434
  // ... 还有很多 continue 分支

  // 4. 正常成功:返回 payloads
  return { payloads, meta: { durationMs, agentMeta, ... } };
}
```

### 它是什么样的循环

**它不是"模型 → 工具 → 模型"的 loop**。

那个最经典意义上的 ReAct loop —— 模型调工具、拿结果再调模型 —— **由 `pi-agent-core` 的 `activeSession.prompt()` 在内部完成**(就是说那是一个被 await 的"长任务",自带循环)。

OpenClaw 的 `while (true)` 的真正作用:

| 条件 | 触发动作 |
|---|---|
| auth 失败 | 旋转 auth profile,重试 |
| 模型空响应 | 注入"empty response retry"指令,重试 |
| 模型只输出 reasoning 没回复 | 注入"reasoning only"指令,重试 |
| 上下文 overflow | 触发 compaction,然后重试 |
| Provider 5xx / 网络抖动 | failover 到下一个 model,重试 |
| 超时压缩失败 | 走 timeout-compaction 路径,重试 |

所以记住:**OpenClaw 的 while 循环 = 重试与失败恢复编排器**。`pi-agent-core` 内部的"模型 ↔ 工具"循环才是 ReAct 主体。

---

## 4. 一次 attempt 的解剖:`attempt.ts:627`

`runEmbeddedAttempt` 是 3663 行的庞然大物,但骨架可以归纳为 6 个阶段:

```
runEmbeddedAttempt(params)  attempt.ts:627
│
├─ stage 1  workspace 准备
│    fs.mkdir(resolvedWorkspace, { recursive: true })          attempt.ts:679
│
├─ stage 2  Session 加载(从磁盘恢复 transcript)
│    sessionManager = guardSessionManager(
│      SessionManager.open(params.sessionFile), { ... })       attempt.ts:1393
│
├─ stage 3  Tool 注册
│    customTools = MCP tools + LSP tools + client tools 合并
│    createEmbeddedAgentSessionWithResourceLoader({ ... })     attempt.ts:1619
│
├─ stage 4  System prompt 装配
│    base prompt + skills + bootstrap context + 钩子注入       attempt.ts:1800-2000
│
├─ stage 5  调模型(进入 pi-agent-core 内部循环)
│    await abortable(activeSession.prompt(promptForModel))     attempt.ts:3015
│    // 或带图片版本
│    await abortable(activeSession.prompt(
│      promptForModel, { images: imageResult.images }))        attempt.ts:3027
│
└─ stage 6  收尾:flush 流式回复 + 持久化 + 返回 payloads
     await params.onBlockReplyFlush?.()                        attempt.ts:3093
     // SessionManager 持久化 transcript
     return { payloads, meta }
```

### 关键洞察:模型调用是一行

```ts
// attempt.ts:3015
await abortable(activeSession.prompt(promptForModel));
```

就这一行。"模型给出文本 → 解析 tool call → 执行 tool → 把 tool 结果回喂模型 → 再给文本 → ..." 这个循环,**全部隐藏在 `activeSession.prompt()` 这个 await 里面**。

OpenClaw 在外面通过 callback 收事件:
- `params.onPartialReply` —— 模型 token-by-token 流式输出
- `params.onBlockReply` —— 完整的 block(一段 reasoning / 一段 text / 一段 tool call)
- `params.onBlockReplyFlush` —— attempt 结束前 flush 缓冲(`:3093`)

这些 callback 把 pi-agent-core 的事件桥接到 OpenClaw 的 **`assistant` / `tool` / `lifecycle`** 三种 stream 上,最终通过 channel(Telegram / Discord / CLI / etc.)送给用户。

---

## 5. 工具执行的真相

工具调用**不在 OpenClaw 主代码里执行**。OpenClaw 只负责:

1. **声明可用工具**(`attempt.ts:1550-1615` 附近):
   - MCP 工具:`materializeBundleMcpToolsForRun()`
   - LSP 工具:`createBundleLspToolRuntime()`
   - 客户端工具:`buildClientToolsFromRegistrations()`
   - bash / file 等核心工具:打包在 pi-agent-core 内部

2. **创建带这些工具的 session**:
   ```ts
   // attempt.ts:1619
   const createdSession = await createEmbeddedAgentSessionWithResourceLoader({
     createAgentSession: async (options) => await createAgentSession(options),
     options: {
       cwd, tools: sessionToolAllowlist,
       customTools: allCustomTools,
       ...
     }
   });
   ```

3. **调 `session.prompt()` 后,pi-agent-core 自己**:
   - 解析模型响应里的 tool call
   - 路由到对应工具实现
   - 执行
   - 把结果作为 user message 加进 transcript
   - 继续调模型直到不再有 tool call

也就是说,你在 OpenClaw 看到的 `before_tool_call` / `after_tool_call` 这些 plugin hook(参考 `docs/concepts/agent-loop.md` 中的 hooks 列表),其实是 pi-agent-core 在执行工具的 callback 回调点上,OpenClaw 拦截下来跑 plugin。

---

## 6. 历史 / Transcript

**数据载体**:`SessionManager`(来自 `@mariozechner/pi-coding-agent`),持有 `AgentMessage[]`。

**生命周期**:

```
attempt 开始
    ↓
SessionManager.open(params.sessionFile)    attempt.ts:1393
    ↓
session.messages 里恢复出之前所有轮次
    ↓
activeSession.prompt(newPrompt)            attempt.ts:3015
    ├── 加 user message
    ├── 调模型 → 加 assistant message(可能带 tool call)
    ├── 执行 tool → 加 user message(role=tool result)
    ├── 调模型 → ...
    └── 直到模型不再有 tool call
    ↓
SessionManager 把 messages flush 到磁盘
    ↓
attempt 返回
```

文件位置:`params.sessionFile` —— 由 `agentCommandInternal` 那一层根据 `sessionId` / `sessionKey` 计算,通常落在 OpenClaw 的 session 目录。

**写锁**:OpenClaw 在 `runEmbeddedPiAgent` 这层加了 **session write lock**(参见 `docs/concepts/agent-loop.md:51-57`),防止两个 run 同时写同一个 transcript 互相覆盖。

---

## 7. 退出条件

`while (true)` 在以下情况退出(全部以 `return` 形式,不是 `break`):

| 退出方式 | 位置 | 含义 |
|---|---|---|
| **正常成功** | `run.ts` 多个 return 点(如 `:2530`, `:2691`) | attempt 产出非空 payloads,无 retry 标志 |
| **重试上限耗尽** | `run.ts:1033-1065` | `runLoopIterations >= MAX_RUN_LOOP_ITERATIONS` |
| **致命模型错误** | `run.ts` 类似 `:1829-1925`、`:2507-2559` | 例如 role ordering 错乱、图片过大、agentic 被严格拒绝 |
| **超时未恢复** | `run.ts:2292-2342` | `timedOutDuringPrompt` 且没有可用的部分回复 |
| **外部 abort** | `params.abortSignal.aborted` 触发 onAbort | 上游(Gateway 超时 / 用户 `/stop`)取消 |
| **上下文 overflow 不可恢复** | `run.ts:1770-1827` | 已经压缩到底了还是塞不下 |

---

## 8. Compaction:把长对话浓缩

模型有 context window 限制。当 transcript 接近上限,需要"compaction"(压缩):用模型自己把旧消息总结成一段,替换掉那些旧消息,腾出空间。

OpenClaw 的 compaction 触发点有三处:

### 触发点 1:Preemptive(开口前预判)
```ts
// attempt.ts:2912-2991 附近
const preemptiveCompaction = shouldPreemptivelyCompactBeforePrompt({ ... });
if (preemptiveCompaction.shouldCompact) {
  promptError = PREEMPTIVE_OVERFLOW_ERROR_TEXT;
}
```
在调模型**之前**,如果估算这次 prompt 加上去会撑爆 window,就先压缩。

### 触发点 2:Timeout 恢复(超时后压缩重试)
```ts
// run.ts:1445-1535 附近
if (timedOut && !timedOutDuringCompaction && tokenUsedRatio > 0.65) {
  timeoutCompactResult = await contextEngine.compact({ ... });
}
```
这个挺有意思 —— 模型超时**经常**就是因为 prompt 太长在慢慢吞,所以超时后先压缩再重试。

### 触发点 3:Overflow 错误恢复(撞墙后压缩重试)
```ts
// run.ts:1609-1737 附近
if (isLikelyContextOverflowError(errorText)) {
  compactResult = await contextEngine.compact({ ... });
}
```
模型直接以 "context length exceeded" 拒绝,那就压缩了再重试。

### compaction 实际做什么

调用 `contextEngine.compact()`(在 `src/context-engine/`):
1. 用模型生成一段 summary,覆盖旧消息段
2. 重写 transcript 文件
3. 更新 SessionManager 内存中的 messages
4. 返回新的 token 数

详细见 `docs/concepts/compaction.md`。

---

## 9. 流式回复:从模型到 channel

```
                                                  
┌─────────────┐                                   
│   model     │   pi-agent-core 内部 stream        
│  (provider) │ ───── token / block deltas ──┐     
└─────────────┘                              │     
                                             ▼     
                  ┌──────────────────────────────┐ 
                  │ pi-agent-core session        │ 
                  │  - 解析 reasoning / text     │ 
                  │  - 解析 tool call            │ 
                  │  - 触发 callback             │ 
                  └──────────┬───────────────────┘ 
                             │                     
                             ▼                     
            params.onPartialReply  (token 增量)    
            params.onBlockReply    (完整 block)    
                             │                     
                             ▼                     
                  ┌──────────────────────────────┐ 
                  │ subscribeEmbeddedPiSession    │ 
                  │  - assistant 流              │ 
                  │  - tool 流                   │ 
                  │  - lifecycle 流              │ 
                  └──────────┬───────────────────┘ 
                             │                     
                             ▼                     
            agentCommandInternal:1282              
            deliverAgentCommandResult              
                             │                     
                             ▼                     
                  ┌──────────────────────────────┐ 
                  │ Channel:Telegram / Discord /  │
                  │ CLI / Slack / ...            │ 
                  └──────────────────────────────┘ 
```

OpenClaw 把流分成三类(详见 `docs/concepts/streaming.md`):
- **assistant** —— 模型给用户的文字
- **tool** —— 工具调用 start / update / end
- **lifecycle** —— start / end / error

注意:**OpenClaw 不发 token-delta channel 消息**(根 AGENTS.md 强调)。Channel 拿到的是按 block 切的 chunk(text_end 或 message_end 边界),保持最终回复的完整性。

---

## 10. 完整 trace:"列出 src 然后读 README.md"

把所有东西串起来,跟踪一条用户消息:

```
1. 用户在 Telegram 发: "list files in src then read README.md"

2. Telegram channel 把消息映射成 agentCommand 调用
   → src/channels/telegram/...
   → agentCommand({ body: "list files...", sessionId: "tg:user:..." })

3. agentCommand                              agent-command.ts:1323
   ↓ (默认 senderIsOwner=true)
   agentCommandInternal                      agent-command.ts:441
   ↓ 解析 model / skills / 等等
   runWithModelFallback                      agent-command.ts:973
   ↓ 套上 model 兜底
   runEmbeddedPiAgent                        run.ts:336

4. ── run loop iteration 1 ──                run.ts:1032
   prompt = "list files in src then read README.md"
   runEmbeddedAttemptWithBackend             run.ts:1131
   ↓
   runEmbeddedAttempt                        attempt.ts:627
     ├ workspace 准备                        :679
     ├ SessionManager.open(sessionFile)      :1393
     ├ tool 注册:bash / read_file / ...     :1619
     ├ system prompt 装配                    :1800+
     └ activeSession.prompt(prompt)          :3015
        │
        │ 进入 pi-agent-core 内部循环
        │
        ├─ 模型回复:"我先列出 src 目录"
        │   tool_call: { name: "bash", args: { cmd: "ls src" } }
        │   ─────► onBlockReply (assistant block)
        │   ─────► onBlockReply (tool block start)
        │
        ├─ 执行 bash("ls src")
        │   ─────► onBlockReply (tool block end + result)
        │   tool_result 回喂 session.messages
        │
        ├─ 模型再次被调用,看到 tool_result
        ├─ 模型回复:"现在读 README.md"
        │   tool_call: { name: "read_file", args: { path: "README.md" } }
        │
        ├─ 执行 read_file("README.md")
        │
        ├─ 模型再次被调用,看到内容
        ├─ 模型生成最终回复:"src 包含: ... README.md 主要讲: ..."
        │   ─────► onPartialReply (一个个 token 流)
        │   ─────► onBlockReply (完整 text block)
        │   没有更多 tool call → pi-agent-core 内部循环结束
        │
        └─ activeSession.prompt() resolve

   onBlockReplyFlush                          attempt.ts:3093
   ↓
   返回 { payloads: [{ text: "src 包含..." }], meta: {...} }

5. ── run loop 检查 ──                        run.ts ~:2150+
   payloads 非空,无 retry 指令 → 正常 return

6. agentCommandInternal 拿到 payloads
   ↓
   deliverAgentCommandResult                  agent-command.ts:1282
   ↓
   把 payloads 推给 Telegram channel
   ↓
   用户在 Telegram 看到回复
```

整条链最关键的两点:
- **OpenClaw 的 while 循环只跑了 1 次**(没遇到错误,不需要 retry)
- **pi-agent-core 内部却调了模型 3 次,执行了 2 次 tool**(在那一次 `activeSession.prompt()` 的 await 里完成)

这就是"agent loop"两层含义的差异。

---

## 11. 接下来读什么

按依赖顺序由浅入深:

1. **入口与信任边界** — `src/agents/agent-command.ts:1323-1365`
2. **delivery 层** — 找到 `loadDeliveryRuntime` 然后顺藤摸瓜
3. **fallback 包装** — `src/agents/model-fallback.ts`
4. **run loop** — `src/agents/pi-embedded-runner/run.ts:336` 起,先看到 `:1032` 的 while
5. **attempt 骨架** — `src/agents/pi-embedded-runner/run/attempt.ts:627`,先不看细节,只跟 6 个 stage 的轮廓
6. **stream 桥接** — `src/agents/pi-embedded-runner/` 里搜 `subscribeEmbeddedPiSession`
7. **compaction** — `src/agents/pi-embedded-runner/compact.ts` + `src/context-engine/`
8. **plugin hooks** — `docs/concepts/agent-loop.md` 列出的 `before_*` / `after_*` 是注入点

读代码的小贴士:

- **一个文件不要贪心读完**。`run.ts` 2879 行、`attempt.ts` 3663 行,逐字读会迷路。先 `grep -n` 找到相关函数,只读 50 行。
- **"why" 比 "what" 重要**。看到一段奇怪的 retry instruction(例如 `planningOnlyRetryInstruction`),先 `grep` 它的赋值点,理解什么场景下会被设上,而不是直接读它的字符串内容。
- **从测试反推**。`run.compaction-loop-guard.test.ts`、`run.timeout-triggered-compaction.test.ts` 这种文件名直接告诉你"这个分支处理什么场景"。
- **scoped AGENTS.md 是宝藏**。每个子目录的 `AGENTS.md` 都告诉你这层的 invariant。例如 `src/agents/pi-embedded-runner/run/CLAUDE.md` 是性能注意事项。

---

## 附:常用 grep 起手式

```bash
# 找入口
grep -n "export async function agentCommand" src/agents/agent-command.ts

# 找循环
grep -n "while (true)" src/agents/pi-embedded-runner/run.ts

# 找模型调用点
grep -n "activeSession.prompt" src/agents/pi-embedded-runner/run/attempt.ts

# 找重试触发
grep -n "continue;" src/agents/pi-embedded-runner/run.ts | head -20

# 找 compaction 触发
grep -n "contextEngine.compact\|shouldPreemptivelyCompactBeforePrompt" \
  src/agents/pi-embedded-runner/run/attempt.ts \
  src/agents/pi-embedded-runner/run.ts

# 找 stream 桥接
grep -rn "subscribeEmbeddedPiSession" src/agents/
```

---

**总结**:OpenClaw 的 agent loop 是一个**双层 loop**结构 —— 外层 OpenClaw 的 `while` 负责重试与失败恢复,内层 `pi-agent-core` 的 `session.prompt()` 负责真正的 ReAct(模型 ↔ 工具)。理解这个分层,是看懂 OpenClaw agent 代码的入门钥匙。
