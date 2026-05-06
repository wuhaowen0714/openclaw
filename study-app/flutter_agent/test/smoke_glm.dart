/// Phase 0.5: GLM API 兼容性验证。
///
/// 验证两个关键能力:
///   1. tool_calls 支持 — 模型是否返回 finish_reason: "tool_calls" + tool_use
///   2. 纯文本请求 — 模型是否正常返回 finish_reason: "stop"
///
/// 用法:
///   export OPENAI_API_KEY="your-key"
///   export OPENAI_BASE_URL="https://open.bigmodel.cn/api/paas/v4"  # GLM
///   dart run test/smoke_glm.dart
///
/// 如果 GLM 不支持 tool_calls → 需要换模型（GPT-4o-mini / Claude Haiku）。
/// 如果 GLM 不支持 SSE → Phase 3 先走非流式路径。

import 'dart:io';

import 'package:openai_dart/openai_dart.dart' as sdk;

void main() async {
  final apiKey = Platform.environment['OPENAI_API_KEY'] ?? '';
  final baseUrl = Platform.environment['OPENAI_BASE_URL'];

  if (apiKey.isEmpty) {
    print('ERROR: set OPENAI_API_KEY first');
    exit(1);
  }

  final client = sdk.OpenAIClient(apiKey: apiKey, baseUrl: baseUrl);

  // Test 1: tool_calls 支持
  print('=== Test 1: tool_calls support ===');
  try {
    final request = sdk.CreateChatCompletionRequest(
      model: sdk.ChatCompletionModel.modelId('GLM-5.1'),
      messages: [
        sdk.ChatCompletionMessage.system(
          content: 'You are a helpful assistant that can list files.',
        ),
        sdk.ChatCompletionMessage.user(
          content: sdk.ChatCompletionUserMessageContent.string(
            'What files are in the current directory?',
          ),
        ),
      ],
      tools: [
        sdk.ChatCompletionTool(
          type: sdk.ChatCompletionToolType.function,
          function: sdk.FunctionObject(
            name: 'list_dir',
            description: 'List files in a directory',
            parameters: {
              'type': 'object',
              'properties': {
                'path': {'type': 'string'},
              },
              'required': ['path'],
            },
          ),
        ),
      ],
    );

    final response = await client.createChatCompletion(request: request);
    final choice = response.choices.first;
    final finishReason = choice.finishReason;
    final hasToolCalls = choice.message.toolCalls != null && choice.message.toolCalls!.isNotEmpty;

    print('finish_reason: $finishReason');
    print('has_tool_calls: $hasToolCalls');
    if (hasToolCalls) {
      for (final tc in choice.message.toolCalls!) {
        print('  tool_use: ${tc.function.name}(${tc.function.arguments})');
      }
      print('✅ GLM supports tool_calls!');
    } else {
      print('❌ GLM did NOT return tool_calls. Need a different model.');
    }
  } catch (e) {
    print('❌ API error: $e');
  }

  // Test 2: 纯文本请求
  print('\n=== Test 2: plain text response ===');
  try {
    final request = sdk.CreateChatCompletionRequest(
      model: sdk.ChatCompletionModel.modelId('GLM-5.1'),
      messages: [
        sdk.ChatCompletionMessage.user(
          content: sdk.ChatCompletionUserMessageContent.string(
            'Say "hello" in one word.',
          ),
        ),
      ],
    );

    final response = await client.createChatCompletion(request: request);
    final choice = response.choices.first;
    final finishReason = choice.finishReason;
    final content = choice.message.content;

    print('finish_reason: $finishReason');
    print('content: $content');
    if (finishReason == sdk.ChatCompletionFinishReason.stop) {
      print('✅ GLM supports plain text completion!');
    } else {
      print('❌ Unexpected finish_reason: $finishReason');
    }
  } catch (e) {
    print('❌ API error: $e');
  }

  print('\n=== Summary ===');
  print('If both tests pass, you can proceed with Phase 1 (engine).');
  print('If tool_calls test fails, switch to GPT-4o-mini or Claude Haiku.');
}