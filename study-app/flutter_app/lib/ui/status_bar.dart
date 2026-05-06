library;

/// StatusBar — 顶部/底部显示当前 agent 状态。
///
/// 状态对应 docs/ui-state-machine.md 的 6 状态:
///   empty/idle: "就绪"
///   loading:    "正在思考..." + spinner
///   streaming:  "接收中..." + spinner
///   toolExecuting: "执行工具..." + spinner
///   error:      "错误: ..." (红色)

import 'package:flutter/material.dart';

import '../agent/agent_state.dart';

class StatusBar extends StatelessWidget {
  final AgentSnapshot snapshot;
  const StatusBar({super.key, required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final (label, color, showSpinner) = _statusFor(snapshot);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: color.withValues(alpha: 0.1),
      child: Row(
        children: [
          if (showSpinner) ...[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            ),
            const SizedBox(width: 8),
          ] else ...[
            Icon(Icons.circle, color: color, size: 10),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (snapshot.iteration > 0)
            Text(
              'iter ${snapshot.iteration}',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
            ),
        ],
      ),
    );
  }

  (String, Color, bool) _statusFor(AgentSnapshot s) {
    return switch (s.phase) {
      AgentPhase.empty => ('就绪', Colors.grey.shade600, false),
      AgentPhase.idle => ('完成', Colors.green.shade700, false),
      AgentPhase.loading => ('正在思考...', Colors.blue.shade700, true),
      AgentPhase.streaming => ('接收中...', Colors.blue.shade700, true),
      AgentPhase.toolExecuting => ('执行工具...', Colors.orange.shade700, true),
      AgentPhase.error => ('错误: ${s.errorMessage ?? "未知"}', Colors.red.shade700, false),
    };
  }
}
