library;

/// AgentController — 包装 reactLoop，把 OnEvent 回调翻译成状态流。
///
/// 设计要点:
///   - 单一 `StreamController<AgentSnapshot>` 管理状态（autoplan 决策 #10）
///   - 不可变 snapshot：每次更新生成新的 AgentSnapshot 实例
///   - 错误不抛异常，全部翻译成 AgentPhase.error + errorMessage
///   - submit() 是 fire-and-forget，调用方通过订阅 stream 拿结果
///
/// 状态机走线（对应 docs/ui-state-machine.md）:
///   submit → loading → assistantMessage(text) → idle / streaming → finish
///   submit → loading → assistantMessage(tool_calls) → toolExecuting
///                    → toolResult → loading（下一轮）→ ... → finish

import 'dart:async';
import 'dart:io' as io;

import 'package:flutter_agent/core/event.dart';
import 'package:flutter_agent/core/react_config.dart';
import 'package:flutter_agent/core/react_loop.dart';
import 'package:flutter_agent/core/tool.dart';
// engine 的 openai_client 也导出 AssistantMessage（wire-format 的内部类），
// 跟 agent_state.dart 的 UI AssistantMessage 命名冲突，hide 掉。
import 'package:flutter_agent/llm/openai_client.dart' hide AssistantMessage;
import 'package:flutter_agent/system_prompt/system_prompt.dart';
import 'package:flutter_agent/tools/bash.dart';
import 'package:flutter_agent/tools/list_dir.dart';
import 'package:flutter_agent/tools/read_file.dart';

import 'agent_state.dart';

class AgentController {
  final OpenAIClient _client;
  final List<Tool> _tools;
  final String _systemPrompt;
  final ReActConfig _config;

  final _ctrl = StreamController<AgentSnapshot>.broadcast();
  AgentSnapshot _snapshot = AgentSnapshot.empty;
  bool _running = false;

  AgentController({
    required String workspaceDir,
    String? apiKey,
    String? baseUrl,
    String model = 'GLM-5.1',
    int maxIters = 15,
  })  : _client = OpenAIClient(apiKey: apiKey, baseUrl: baseUrl),
        _tools = [
          makeListDirTool(root: workspaceDir),
          makeReadFileTool(root: workspaceDir),
          makeBashTool(cwd: workspaceDir),
        ],
        _systemPrompt = buildSystemPrompt(
          toolNames: const ['list_dir', 'read_file', 'bash'],
          workspaceDir: workspaceDir,
          model: model,
        ),
        _config = ReActConfig(model: model, max_iters: maxIters);

  Stream<AgentSnapshot> get stream => _ctrl.stream;
  AgentSnapshot get snapshot => _snapshot;
  bool get isRunning => _running;

  /// 用户提交一个新任务。返回 Future 用于等待完成（也可以不 await）。
  /// 期间所有状态变化通过 stream 推送。
  Future<void> submit(String userPrompt) async {
    if (_running) {
      // 已经在跑，忽略新请求（Phase 2 不支持取消/排队）
      return;
    }
    _running = true;

    // 立即追加用户消息 + 切到 loading
    _emit(_snapshot.copyWith(
      phase: AgentPhase.loading,
      messages: [..._snapshot.messages, UserMessage(userPrompt)],
      errorMessage: null,
    ));

    try {
      await reactLoop(
        client: _client,
        tools: _tools,
        userPrompt: userPrompt,
        systemPrompt: _systemPrompt,
        config: _config,
        onEvent: _handleEvent,
      );
    } on AgentException catch (e) {
      // HTTP / API key / quota 等运行时错误 — 翻译成 error phase
      _emit(_snapshot.copyWith(phase: AgentPhase.error, errorMessage: e.message));
    } on StateError catch (e) {
      // max_iters 耗尽
      _emit(_snapshot.copyWith(phase: AgentPhase.error, errorMessage: e.message));
    } catch (e) {
      _emit(_snapshot.copyWith(
        phase: AgentPhase.error,
        errorMessage: 'unexpected: ${e.runtimeType}: $e',
      ));
    } finally {
      _running = false;
    }
  }

  void _handleEvent(EventKind kind, Map<String, dynamic> payload) {
    switch (kind) {
      case iterationStart:
        _emit(_snapshot.copyWith(
          phase: AgentPhase.loading,
          iteration: payload['i'] as int,
        ));

      case assistantMessage:
        final text = payload['text'] as String? ?? '';
        final toolCalls = payload['tool_calls'] as List? ?? const [];
        final messages = [..._snapshot.messages];

        // 模型可能同时返回 text + tool_calls（罕见但合法）
        if (text.isNotEmpty) {
          messages.add(AssistantMessage(text));
        }
        for (final tc in toolCalls) {
          messages.add(ToolCallEntry(
            id: tc['id'] as String,
            name: tc['name'] as String,
            argumentsRaw: tc['arguments'] as String,
            status: ToolCallStatus.pending,
          ));
        }

        _emit(_snapshot.copyWith(
          phase: toolCalls.isEmpty ? AgentPhase.streaming : AgentPhase.toolExecuting,
          messages: messages,
        ));

      case toolResult:
        // 找到 pending 的 ToolCallEntry，更新成 done/error
        final id = payload['id'] as String;
        final result = payload['result'] as String;
        final isError = result.startsWith('ERROR:');

        final messages = [..._snapshot.messages];
        for (var i = messages.length - 1; i >= 0; i--) {
          final m = messages[i];
          if (m is ToolCallEntry && m.id == id) {
            messages[i] = m.copyWith(
              status: isError ? ToolCallStatus.error : ToolCallStatus.done,
              result: result,
            );
            break;
          }
        }
        _emit(_snapshot.copyWith(messages: messages));

      case finish:
        _emit(_snapshot.copyWith(phase: AgentPhase.idle));

      case error:
        _emit(_snapshot.copyWith(
          phase: AgentPhase.error,
          errorMessage: payload['message'] as String?,
        ));

      case toolCall:
        // 工具调用本身已经在 assistantMessage 时记录了 ToolCallEntry，
        // 这里不重复记录。Phase 3 的时间线可视化会用到。
        break;

      case apiRequest:
      case apiResponse:
        // verbose 事件，UI 不消费
        break;
    }
  }

  void _emit(AgentSnapshot newSnapshot) {
    _snapshot = newSnapshot;
    if (!_ctrl.isClosed) {
      _ctrl.add(newSnapshot);
    }
  }

  void dispose() {
    _ctrl.close();
  }
}

/// 从 Platform.environment 读 API key；缺失返回 null。
/// UI 会显示一个友好的提示让用户去设置环境变量。
String? readApiKeyFromEnv() {
  final key = io.Platform.environment['OPENAI_API_KEY'];
  return (key == null || key.isEmpty) ? null : key;
}

String? readBaseUrlFromEnv() {
  final url = io.Platform.environment['OPENAI_BASE_URL'];
  return (url == null || url.isEmpty) ? null : url;
}
