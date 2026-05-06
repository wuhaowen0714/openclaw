/// 工具辅助函数 — 路径越界防护和输出截断。
///
/// 对应 Python demo 的 _resolveSafe 和 _truncate。
/// 也对应 OpenClaw 的 sandbox 路径校验和 tool-result-truncation。

import 'package:path/path.dart' as p;

/// 截断策略: 保留 head + tail，不是只截前面。
/// 这样模型能看到文件开头和错误位置（通常在尾部）。
/// 对应 OpenClaw 的 tool-result-truncation.ts。
String truncate(String s, int limit) {
  if (s.length <= limit) return s;
  final head = limit ~/ 2;
  final tail = limit - head;
  return '${s.substring(0, head)}\n... [truncated ${s.length - limit} chars, showing tail]\n${s.substring(s.length - tail)}';
}

/// 路径越界防护 — 防止 ../../etc/passwd 之类。
/// 对应 Python demo 的 _resolveSafe。
/// resolve rel under base, refusing escapes.
/// Returns resolved path on success, error string on failure.
String resolveSafe(String base, String rel) {
  final target = p.normalize(p.join(base, rel));
  final normalizedBase = p.normalize(base);

  // Allow exact match with base
  if (target == normalizedBase) return target;

  // Target must be under base. 用 p.isWithin 跨平台判断，不依赖 '/' 分隔符
  // （Windows 用 \, *nix 用 /，硬编码会在 Windows 上失败）
  if (!p.isWithin(normalizedBase, target)) {
    return 'ERROR: path $rel escapes sandbox $normalizedBase';
  }
  return target;
}