/// CLI 入口 — 对应 Python demo 的 main.py。
///
/// 用法:
///     cd study-app/flutter_agent
///     dart run lib/cli/main.dart
///
///     # 默认任务: 总结当前目录是个什么项目
///     dart run lib/cli/main.dart
///
///     # 自定义任务 + 沙箱根
///     dart run lib/cli/main.dart --task "find all Python files" --root .
///
///     # verbose: 把每一轮 messages 演化都打印
///     dart run lib/cli/main.dart --verbose
///
///     # 换模型 / 调上限
///     dart run lib/cli/main.dart --model gpt-4o --max-iters 30
///
/// 环境变量:
///     OPENAI_API_KEY   必填
///     OPENAI_BASE_URL  可选（用于代理 / 兼容 endpoint）

import 'dart:io' as io;

import '../core/event.dart';
import '../core/react_config.dart';
import '../core/react_loop.dart';
import '../llm/openai_client.dart';
import '../system_prompt/system_prompt.dart';
import '../tools/bash.dart';
import '../tools/list_dir.dart';
import '../tools/read_file.dart';

void main(List<String> args) async {
  final parsed = _parseArgs(args);

  if (!io.Platform.environment.containsKey('OPENAI_API_KEY')) {
    print('ERROR: set OPENAI_API_KEY first');
    io.exit(1);
  }

  final client = OpenAIClient();

  final tools = [
    makeListDirTool(root: parsed.root),
    makeReadFileTool(root: parsed.root),
    makeBashTool(cwd: parsed.root, timeout: parsed.config.bashTimeout),
  ];

  final systemPrompt = buildSystemPrompt(
    toolNames: tools.map((t) => t.name).toList(),
    workspaceDir: parsed.root,
    model: parsed.config.model,
  );

  print('task:  ${parsed.task}');
  print('root:  ${parsed.root}');
  print('model: ${parsed.config.model}');
  print('tools: ${tools.map((t) => t.name).join(', ')}');
  print('---');

  try {
    final result = await reactLoop(
      client: client,
      tools: tools,
      userPrompt: parsed.task,
      systemPrompt: systemPrompt,
      config: parsed.config,
      onEvent: makeEventLogger(parsed.verbose),
    );
    print('---');
    print('FINAL ANSWER:');
    print(result);
  } on StateError catch (e) {
    print('\nFAILED: $e');
    io.exit(2);
  } on AgentException catch (e) {
    print('\nAPI ERROR: $e');
    io.exit(3);
  }

  io.exit(0);
}

/// 事件 logger — 对应 Python demo 的 make_event_logger。
/// 默认模式只打关键事件，verbose 模式打每轮细节。
OnEvent makeEventLogger(bool verbose) {
  return (kind, payload) {
    if (!verbose) {
      if (kind == toolCall) {
        print('  -> ${payload['name']}(${payload['arguments_raw']})');
      } else if (kind == toolResult) {
        final result = payload['result'] as String;
        final preview = result.split('\n').first;
        print('  <- ${preview.substring(0, preview.length.clamp(0, 120))}');
      }
      return;
    }

    // verbose 模式
    switch (kind) {
      case iterationStart:
        print('\n=== iteration ${payload['i']}  (history len: ${payload['history_len']}) ===');
      case assistantMessage:
        final text = payload['text'] as String?;
        if (text != null && text.isNotEmpty) {
          print('  text: ${text.substring(0, text.length.clamp(0, 300))}');
        }
        final toolCalls = payload['tool_calls'] as List?;
        if (toolCalls != null) {
          for (final tc in toolCalls) {
            print('  tool_use: ${tc['name']}(${tc['arguments']})  id=${(tc['id'] as String).substring(0, 12)}');
          }
        }
      case toolResult:
        final result = payload['result'] as String;
        print('  tool_result[${(payload['id'] as String).substring(0, 12)}]: ${result.substring(0, result.length.clamp(0, 300)).replaceAll('\n', ' | ')}');
      case finish:
        print('\n=== finished ===');
      case error:
        print('\n=== ERROR: ${payload['message']} ===');
    }
  };
}

class CliArgs {
  final String task;
  final String root;
  final ReActConfig config;
  final bool verbose;

  CliArgs({
    required this.task,
    required this.root,
    required this.config,
    required this.verbose,
  });
}

CliArgs _parseArgs(List<String> args) {
  String task = 'List the top-level files in the current directory and tell me '
      'what kind of project this is in 2-3 sentences.';
  String root = io.Directory.current.path;
  String model = 'GLM-5.1';
  int max_iters = 15;
  bool verbose = false;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--task':
        task = args[++i];
      case '--root':
        root = args[++i];
      case '--model':
        model = args[++i];
      case '--max-iters':
        max_iters = int.parse(args[++i]);
      case '--verbose':
        verbose = true;
      default:
        print('Unknown option: ${args[i]}');
    }
  }

  return CliArgs(
    task: task,
    root: root,
    config: ReActConfig(model: model, max_iters: max_iters, logRawApi: verbose),
    verbose: verbose,
  );
}