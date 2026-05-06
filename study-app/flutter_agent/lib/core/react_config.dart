/// ReAct loop 配置 — 对应 OpenClaw 的运行参数。
///
/// 设计决策对照:
///   - model: 默认 GLM-5.1（你已走通的 OpenAI-compatible endpoint）
///   - max_iters: 15（对应 OpenClaw 的 MAX_RUN_LOOP_ITERATIONS 兜底）
///   - parallelToolCalls: true（OpenClaw 默认开，见 extra-params.ts:327）
///     但本引擎串行执行（简单 for 循环），真正并行需要 asyncio.gather
///   - temperature: 0.0（agent 场景用低温度，减少随机性）
///   - logRawApi: false（verbose 时打开，记录原始 wire 数据）
///   - truncationLimit: 8000（对应 OpenClaw 的 tool-result-truncation）
///   - bashTimeout: 30s（shell 命令超时）
class ReActConfig {
  final String model;
  final int max_iters;
  final bool parallelToolCalls;
  final double temperature;
  final bool logRawApi;
  final int truncationLimit;
  final int bashTimeout;

  const ReActConfig({
    this.model = 'GLM-5.1',
    this.max_iters = 15,
    this.parallelToolCalls = true,
    this.temperature = 0.0,
    this.logRawApi = false,
    this.truncationLimit = 8000,
    this.bashTimeout = 30,
  });
}