/// ReAct loop 核心 — 对应 OpenClaw 的 pi-agent-core session.prompt()。
///
/// 这就是 ReAct 范式的最小实现: 模型→工具→模型 循环。
/// 去掉注释、错误处理、event hook，精确就是文档第 4 节那 50 行伪代码的 Dart 翻译。
///
/// OpenClaw 的完整 loop 有多层包装:
///   run.ts 的 while(true) 外层 → retry + model fallback + compaction
///   attempt.ts 的 activeSession.prompt() → 实际调模型
///   pi-agent-core 内部 → ReAct loop 本体（本文件）
///
/// 本引擎只实现最内层。retry/fallback/compaction 等工程化层不在这里。
///
/// OpenAI vs Anthropic 协议差异（重要）:
///   - 文档里说 "tool_result 是 user 角色" 指的是 Anthropic 协议
///     (assistant message 有 tool_use block, user message 有 tool_result block)
///   - OpenAI 协议是单独的 role="tool" 消息，概念上等价
///     都代表 "外部世界回喂给模型的输入"，只是 schema 不同。
///   - 本文件用 OpenAI 协议（role="tool" + tool_call_id 配对）

import 'dart:convert';

import '../llm/openai_client.dart';
import 'event.dart';
import 'react_config.dart';
import 'tool.dart';

/// 跑一次 ReAct loop，返回最终 assistant text。
///
/// 流程:
///   for i in 0..max_iters:
///     resp = openai.chat.completions.create(messages, tools=...)
///     msg = resp.choices[0].message
///     messages.append(msg)
///
///     if finish_reason == "stop":
///       return msg.content                    # 完成
///     if finish_reason == "tool_calls":
///       for tc in msg.tool_calls:
///         result = run_tool(tc)
///         messages.append({role: "tool", tool_call_id: tc.id, content: result})
///       continue
Future<String> reactLoop({
  required OpenAIClient client,
  required List<Tool> tools,
  required String userPrompt,
  String? systemPrompt,
  ReActConfig? config,
  OnEvent? onEvent,
}) async {
  final cfg = config ?? const ReActConfig();
  final emit = onEvent ?? ((_, __) {});
  final toolsByName = {for (final t in tools) t.name: t};
  final toolSpecs = [for (final t in tools) t.toToolSpec()];

  final messages = <Map<String, dynamic>>[];
  if (systemPrompt != null) {
    messages.add({'role': 'system', 'content': systemPrompt});
  }
  messages.add({'role': 'user', 'content': userPrompt});

  for (var i = 0; i < cfg.max_iters; i++) {
    emit(iterationStart, {'i': i, 'history_len': messages.length});

    if (cfg.logRawApi) {
      emit(apiRequest, {
        'iteration': i,
        'model': cfg.model,
        'messages': messages,
        'tools': toolSpecs,
        'temperature': cfg.temperature,
        'parallel_tool_calls': cfg.parallelToolCalls,
      });
    }

    final resp = await client.chatCompletion(
      model: cfg.model,
      messages: messages,
      tools: toolSpecs,
      temperature: cfg.temperature,
      parallelToolCalls: cfg.parallelToolCalls,
    );

    if (cfg.logRawApi) {
      emit(apiResponse, {'iteration': i, 'messages_len': messages.length});
    }

    final choice = resp.choices.first;
    final finishReason = choice.finishReason;
    final msg = choice.message;

    // 把 assistant message append 进 history。
    messages.add(msg.toMap());

    emit(assistantMessage, {
      'finish_reason': finishReason,
      'text': msg.content ?? '',
      'tool_calls': msg.toolCalls
          ?.map((tc) => {
                'id': tc.id,
                'name': tc.name,
                'arguments': tc.arguments,
              })
          .toList() ?? [],
    });

    // 终止: 模型给出最终答案（finish_reason=stop 且无 tool_calls）
    if (finishReason == 'stop') {
      emit(finish, {'text': msg.content ?? ''});
      return msg.content ?? '';
    }

    // 还有 tool calls，要执行
    if (finishReason == 'tool_calls' && msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
      for (final tc in msg.toolCalls!) {
        emit(toolCall, {
          'id': tc.id,
          'name': tc.name,
          'arguments_raw': tc.arguments,
        });

        String result;
        final tool = toolsByName[tc.name];
        if (tool == null) {
          result = 'ERROR: tool ${tc.name} not found';
        } else {
          try {
            final args = jsonDecode(tc.arguments.isNotEmpty ? tc.arguments : '{}') as Map<String, dynamic>;
            result = await tool.run(args);
          } on FormatException catch (e) {
            result = 'ERROR: malformed JSON args: $e; raw=${tc.arguments}';
          } catch (e) {
            result = 'ERROR: ${e.runtimeType}: $e';
          }
        }

        // OpenAI 协议的 tool result 消息（role="tool" + tool_call_id 配对）
        messages.add({
          'role': 'tool',
          'tool_call_id': tc.id,
          'content': result,
        });
        emit(toolResult, {'id': tc.id, 'result': result});
      }
      continue;
    }

    // length / content_filter 等其他终止原因
    emit(error, {
      'finish_reason': finishReason,
      'message': 'unexpected finish_reason: $finishReason',
    });
    return 'ERROR: unexpected finish_reason: $finishReason';
  }

  emit(error, {'message': 'exceeded max iterations (${cfg.max_iters})'});
  throw StateError('exceeded max iterations (${cfg.max_iters})');
}