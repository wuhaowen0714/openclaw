/// list_dir 工具 — 对应 Python demo 的 make_list_dir_tool。
///
/// 功能: 列出目录下的文件和子目录。
/// 安全: 路径越界防护（resolveSafe），防止 ../../etc/passwd。
/// 错误: 以字符串返回，不抛异常。

import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/tool.dart';
import 'helpers.dart';

Tool makeListDirTool({
  String? root,
  int truncationLimit = 8000,
}) {
  final base = root ?? Directory.current.path;

  return Tool(
    name: 'list_dir',
    description: 'List entries in a directory under the sandbox root. '
        'Returns one line per entry as "file|dir <TAB> name".',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'directory path relative to sandbox root; defaults to "."',
        },
      },
      'required': [],
    },
    run: (args) async {
      final rel = args['path'] as String? ?? '.';
      final target = resolveSafe(base, rel);
      if (target.startsWith('ERROR:')) return target;

      final dir = Directory(target);
      if (!await dir.exists()) return 'ERROR: not found: $rel';

      final stat = await dir.stat();
      if (stat.type != FileSystemEntityType.directory) {
        return 'ERROR: not a directory: $rel';
      }

      // Stream 没有 sorted()，先 collect 再手动排序
      final entries = await dir.list().toList();
      entries.sort((a, b) => a.path.compareTo(b.path));

      final items = <String>[];
      for (final entry in entries) {
        final kind = entry is File ? 'file' : 'dir';
        // 用 path package 的 basename，跨平台兼容（Windows 用 \, *nix 用 /）
        final name = p.basename(entry.path);
        items.add('$kind\t$name');
      }

      final result = items.isEmpty ? '(empty)' : items.join('\n');
      return truncate(result, truncationLimit);
    },
  );
}