/// read_file 工具 — 对应 Python demo 的 make_read_file_tool。
///
/// 功能: 读取 UTF-8 文本文件内容。
/// 安全: 路径越界防护（resolveSafe），防止读取 sandbox 外的文件。
/// 截断: head 4000 + tail 4000，让模型能看到文件开头和尾部错误位置。
/// 错误: 以字符串返回，不抛异常。

import 'dart:io';

import '../core/tool.dart';
import 'helpers.dart';

Tool makeReadFileTool({
  String? root,
  int truncationLimit = 8000,
}) {
  final base = root ?? Directory.current.path;

  return Tool(
    name: 'read_file',
    description: 'Read a UTF-8 text file under the sandbox root. '
        'Output is truncated past 8000 chars, keeping head and tail.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'file path relative to sandbox root',
        },
      },
      'required': ['path'],
    },
    run: (args) async {
      final rel = args['path'] as String?;
      if (rel == null || rel.isEmpty) return 'ERROR: missing path';

      final target = resolveSafe(base, rel);
      if (target.startsWith('ERROR:')) return target;

      final file = File(target);
      if (!await file.exists()) return 'ERROR: file not found: $rel';
      if (await FileSystemEntity.isDirectory(target)) {
        return 'ERROR: is a directory, use list_dir: $rel';
      }

      try {
        final data = await file.readAsString();
        return truncate(data, truncationLimit);
      } catch (e) {
        return 'ERROR: ${e.runtimeType}: $e';
      }
    },
  );
}