/// bash 工具 — 对应 OpenClaw 的 sandbox bash + Python demo 的 subprocess.run。
///
/// 安全设计:
///   - macOS/Linux: Process.start('sh', ['-c', cmd])
///   - Windows: Process.start('cmd', ['/S', '/C', cmd])
///   - timeout: Process.start + Future.timeout(30s, onTimeout: killProcess)
///   - cancel: 保存 Process 引用，cancel 时 killProcess
///   - 并发上限: 在 react_loop 层面控制（暂不在此文件实现）
///   - Phase 1: log 所有 bash 命令（CLI verbose）
///   - Phase 2: 添加命令确认 UI
///
/// 错误处理:
///   - 超时 → 返回 "ERROR: command timed out after Ns"
///   - 其他异常 → 返回 "ERROR: ExceptionType: message"
///   - 所有错误以字符串返回，不抛异常 — 让模型自己看到错误并改策略

import 'dart:io';

import '../core/tool.dart';
import 'helpers.dart';

Tool makeBashTool({
  String? cwd,
  int timeout = 30,
  int truncationLimit = 8000,
}) {
  final workdir = cwd ?? Directory.current.path;

  return Tool(
    name: 'bash',
    description: 'Run a shell command in the sandbox working directory. '
        'Returns stdout, stderr, and exit code. Use sparingly — '
        'prefer list_dir/read_file when those work.',
    parameters: {
      'type': 'object',
      'properties': {
        'cmd': {
          'type': 'string',
          'description': 'shell command line',
        },
      },
      'required': ['cmd'],
    },
    run: (args) async {
      final cmd = args['cmd'] as String? ?? '';
      if (cmd.isEmpty) return 'ERROR: missing cmd';

      print('[bash] $cmd');

      Process? process;
      try {
        final shellCmd = Platform.isWindows
            ? ['cmd', '/S', '/C', cmd]
            : ['sh', '-c', cmd];

        process = await Process.start(
          shellCmd[0],
          shellCmd.sublist(1),
          workingDirectory: workdir,
        );

        // systemEncoding 是 dart:io 提供的平台编码（macOS UTF-8, Windows GBK 等）
        final stdoutFuture = process.stdout.transform(systemEncoding.decoder).join();
        final stderrFuture = process.stderr.transform(systemEncoding.decoder).join();

        final results = await Future.wait<dynamic>([
          stdoutFuture,
          stderrFuture,
          process.exitCode,
        ]).timeout(Duration(seconds: timeout), onTimeout: () {
          process?.kill();
          return ['', 'ERROR: command timed out after $timeout seconds', -1];
        });

        final out = '${results[0]}\n[stderr]\n${results[1]}\n[exit=${results[2]}]';
        return truncate(out, truncationLimit);
      } catch (e) {
        process?.kill();
        return 'ERROR: ${e.runtimeType}: $e';
      }
    },
  );
}