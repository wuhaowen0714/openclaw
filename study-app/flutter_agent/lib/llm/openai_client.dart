/// OpenAI-compatible API 客户端 — 基于 openai_dart SDK。
///
/// 设计决策:
///   - 使用 openai_dart package 而非手写 HTTP（手写 HTTP 是最没教育价值的部分）
///   - SDK 处理: HTTP 错误码、JSON 解析、tool_calls 提取、重试
///   - 支持 OpenAI-compatible endpoint（GLM 等通过 OPENAI_BASE_URL 配置）
///
/// HTTP 错误处理（给用户看的 problem+cause+fix）:
///   - 401 → "API key 无效。请设置 OPENAI_API_KEY 环境变量。"
///   - 403 → "API key 没有权限访问此模型。请检查 key 的 model access。"
///   - 429 → "请求太频繁。等待几秒后重试。"
///   - 500/502/503 → "模型服务暂时不可用。稍后重试。"
///
/// Phase 3 会用 SDK 的 createChatCompletionStream() 实现 SSE streaming。

import 'dart:io' as io;

import 'package:openai_dart/openai_dart.dart' as sdk;

/// chat completion 的结构化响应 — 把 SDK 对象转成引擎可用的简单结构。
class ChatCompletionResponse {
  final List<Choice> choices;
  final Map<String, dynamic>? raw;

  ChatCompletionResponse({required this.choices, this.raw});
}

class Choice {
  final String finishReason;
  final AssistantMessage message;

  Choice({required this.finishReason, required this.message});
}

class AssistantMessage {
  final String? content;
  final List<ToolCall>? toolCalls;

  AssistantMessage({this.content, this.toolCalls});

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'role': 'assistant',
    };
    if (content != null) map['content'] = content;
    if (toolCalls != null) {
      map['tool_calls'] = toolCalls!.map((tc) {
        return {
          'id': tc.id,
          'type': 'function',
          'function': {
            'name': tc.name,
            'arguments': tc.arguments,
          },
        };
      }).toList();
    }
    return map;
  }
}

/// 引擎内部的简化 ToolCall — 对应 SDK 的 ChatCompletionMessageToolCall。
/// 扁平结构（name/arguments 直接在顶层），方便 react_loop 操作。
class ToolCall {
  final String id;
  final String name;
  final String arguments;

  ToolCall({required this.id, required this.name, required this.arguments});
}

/// OpenAI-compatible API 客户端。
/// 内部用 openai_dart SDK，外部暴露引擎需要的简化接口。
class OpenAIClient {
  late final sdk.OpenAIClient _sdkClient;

  OpenAIClient({String? apiKey, String? baseUrl}) {
    final key = apiKey ?? io.Platform.environment['OPENAI_API_KEY'] ?? '';
    final url = baseUrl ?? io.Platform.environment['OPENAI_BASE_URL'];
    _sdkClient = sdk.OpenAIClient(
      apiKey: key,
      baseUrl: url,
    );
  }

  /// 发送 chat completion 请求。
  /// 对应 Python demo 的 client.chat.completions.create()。
  Future<ChatCompletionResponse> chatCompletion({
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required double temperature,
    required bool parallelToolCalls,
  }) async {
    try {
      final sdkMessages = messages.map(_convertMessage).toList();
      final sdkTools = tools.map(_convertToolSpec).toList();

      final request = sdk.CreateChatCompletionRequest(
        model: sdk.ChatCompletionModel.modelId(model),
        messages: sdkMessages,
        tools: sdkTools.isNotEmpty ? sdkTools : null,
        temperature: temperature,
        parallelToolCalls: parallelToolCalls,
      );

      final response = await _sdkClient.createChatCompletion(request: request);

      final choices = response.choices.map((c) => Choice(
            finishReason: _finishReasonToWire(c.finishReason),
            message: AssistantMessage(
              content: c.message.content,
              toolCalls: c.message.toolCalls?.map((tc) => ToolCall(
                    id: tc.id,
                    name: tc.function.name,
                    arguments: tc.function.arguments,
                  )).toList(),
            ),
          )).toList();

      return ChatCompletionResponse(choices: choices);
    } on sdk.OpenAIClientException catch (e) {
      final statusCode = e.code;
      final errorMsg = _httpErrorMessage(statusCode, e.message);
      throw AgentException(errorMsg);
    } catch (e) {
      throw AgentException('ERROR: ${e.runtimeType}: $e');
    }
  }

  /// SDK 的 ChatCompletionFinishReason enum 用 camelCase（toolCalls），
  /// 但 OpenAI wire format 用 snake_case（tool_calls）。
  /// react_loop 比较 wire-format 字符串，所以这里要做映射。
  String _finishReasonToWire(sdk.ChatCompletionFinishReason? reason) {
    switch (reason) {
      case sdk.ChatCompletionFinishReason.stop:
        return 'stop';
      case sdk.ChatCompletionFinishReason.length:
        return 'length';
      case sdk.ChatCompletionFinishReason.toolCalls:
        return 'tool_calls';
      case sdk.ChatCompletionFinishReason.contentFilter:
        return 'content_filter';
      case sdk.ChatCompletionFinishReason.functionCall:
        return 'function_call';
      case null:
        return 'stop';
    }
  }

  String _httpErrorMessage(int? statusCode, String message) {
    switch (statusCode) {
      case 401:
        return 'API key 无效。请设置 OPENAI_API_KEY 环境变量。($message)';
      case 403:
        return 'API key 没有权限访问此模型。请检查 key 的 model access。($message)';
      case 429:
        return '请求太频繁。等待几秒后重试。($message)';
      case 500:
      case 502:
      case 503:
        return '模型服务暂时不可用。稍后重试。($message)';
      default:
        return 'API 错误 (status=$statusCode): $message';
    }
  }

  /// 把引擎的 Map message 转成 SDK 的 ChatCompletionMessage 对象。
  sdk.ChatCompletionMessage _convertMessage(Map<String, dynamic> m) {
    final role = m['role'] as String;
    final content = m['content'] as String?;

    switch (role) {
      case 'system':
        return sdk.ChatCompletionMessage.system(content: content ?? '');
      case 'user':
        return sdk.ChatCompletionMessage.user(
          content: sdk.ChatCompletionUserMessageContent.string(content ?? ''),
        );
      case 'assistant':
        final toolCalls = m['tool_calls'] as List?;
        if (toolCalls != null) {
          return sdk.ChatCompletionMessage.assistant(
            content: content,
            toolCalls: toolCalls.map((tc) => sdk.ChatCompletionMessageToolCall(
                  id: tc['id'] as String,
                  type: sdk.ChatCompletionMessageToolCallType.function,
                  function: sdk.ChatCompletionMessageFunctionCall(
                    name: tc['function']['name'] as String,
                    arguments: tc['function']['arguments'] as String,
                  ),
                )).toList(),
          );
        }
        return sdk.ChatCompletionMessage.assistant(content: content);
      case 'tool':
        return sdk.ChatCompletionMessage.tool(
          toolCallId: m['tool_call_id'] as String,
          content: m['content'] as String,
        );
      default:
        throw AgentException('unsupported message role: $role');
    }
  }

  /// 把引擎的 tool spec 转成 SDK 的 ChatCompletionTool 对象。
  sdk.ChatCompletionTool _convertToolSpec(Map<String, dynamic> spec) {
    final function = spec['function'] as Map<String, dynamic>;
    return sdk.ChatCompletionTool(
      type: sdk.ChatCompletionToolType.function,
      function: sdk.FunctionObject(
        name: function['name'] as String,
        description: function['description'] as String?,
        parameters: function['parameters'] as sdk.FunctionParameters,
      ),
    );
  }
}

/// Agent 专用异常 — 跟 OpenAI SDK 异常分开。
class AgentException implements Exception {
  final String message;
  AgentException(this.message);

  @override
  String toString() => message;
}