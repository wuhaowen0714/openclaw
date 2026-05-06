library;

/// ToolCallCard — 工具调用的 3 态可视化（pending / done / error）。
///
/// 视觉规格对应 docs/ui-state-machine.md:
///   pending: 灰色边框 + 旋转 spinner + "正在执行..."
///   done:    绿色边框 + ✓ + result 文本（截断）
///   error:   红色边框 + ✗ + ERROR result

import 'package:flutter/material.dart';

import '../agent/agent_state.dart';

class ToolCallCard extends StatelessWidget {
  final ToolCallEntry entry;
  const ToolCallCard({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final (border, icon, iconColor) = switch (entry.status) {
      ToolCallStatus.pending => (Colors.grey.shade400, Icons.sync, Colors.grey.shade600),
      ToolCallStatus.done => (Colors.green.shade400, Icons.check_circle, Colors.green.shade600),
      ToolCallStatus.error => (Colors.red.shade400, Icons.error, Colors.red.shade600),
    };

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: border, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (entry.status == ToolCallStatus.pending)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(icon, color: iconColor, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${entry.name}(${_argsPreview(entry.argumentsRaw)})',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (entry.status == ToolCallStatus.pending) ...[
              const SizedBox(height: 6),
              Text('正在执行...', style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
            ],
            if (entry.result != null) ...[
              const Divider(height: 16),
              SelectableText(
                _resultPreview(entry.result!),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _argsPreview(String raw) {
    if (raw.length <= 80) return raw;
    return '${raw.substring(0, 77)}...';
  }

  String _resultPreview(String r) {
    // 已经在引擎层 truncate 过到 8000 char 了，这里再做一次 UI 截断防止占满屏幕
    if (r.length <= 600) return r;
    return '${r.substring(0, 600)}\n... [更多 ${r.length - 600} 字符]';
  }
}
