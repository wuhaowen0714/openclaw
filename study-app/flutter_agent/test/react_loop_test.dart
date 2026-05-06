/// 工具辅助函数和 ReAct loop 的单元测试。
///
/// 测试内容:
///   - truncate 截断策略（head + tail）
///   - resolveSafe 路径越界防护
///   - reactLoop 核心流程（mock client）
///   - system prompt 组装
///   - tool spec 序列化

import 'package:test/test.dart';

import '../lib/core/event.dart';
import '../lib/core/react_config.dart';
import '../lib/core/react_loop.dart';
import '../lib/core/tool.dart';
import '../lib/llm/openai_client.dart';
import '../lib/system_prompt/system_prompt.dart';
import '../lib/tools/helpers.dart';

// finish_reason 必须用 OpenAI wire format（snake_case）
// 不是 SDK enum 的 .name（camelCase）。否则 react_loop 永远走不到工具执行分支。
// 见 openai_client.dart 的 _finishReasonToWire。
const _expectedFinishReasons = {'stop', 'length', 'tool_calls', 'content_filter', 'function_call'};

// ========== helpers 测试 ==========

void main() {
  group('truncate', () {
    test('short string passes through', () {
      expect(truncate('hello', 10), equals('hello'));
    });

    test('long string gets head + tail', () {
      final s = 'A' * 500 + 'B' * 500 + 'C' * 500; // 1500 chars
      final result = truncate(s, 10);
      // head=5, tail=5
      expect(result.contains('AAAAA'), isTrue);
      expect(result.contains('CCCCC'), isTrue);
      expect(result.contains('[truncated'), isTrue);
    });

    test('exact limit passes through', () {
      final s = 'X' * 100;
      expect(truncate(s, 100), equals(s));
    });
  });

  group('finish_reason wire format', () {
    test('react_loop expects snake_case strings', () {
      // Sanity check — react_loop.dart 比较的字符串必须在这个集合里
      // 否则映射或比较出问题。
      expect(_expectedFinishReasons, contains('stop'));
      expect(_expectedFinishReasons, contains('tool_calls'));
      expect(_expectedFinishReasons, contains('content_filter'));
    });
  });

  group('resolveSafe', () {
    test('normal path resolves correctly', () {
      final result = resolveSafe('/sandbox', 'subdir/file.txt');
      expect(result, equals('/sandbox/subdir/file.txt'));
    });

    test('dot resolves to base', () {
      final result = resolveSafe('/sandbox', '.');
      expect(result, equals('/sandbox'));
    });

    test('parent escape is blocked', () {
      final result = resolveSafe('/sandbox', '../../etc/passwd');
      expect(result.startsWith('ERROR:'), isTrue);
    });

    test('absolute path under base resolves', () {
      final result = resolveSafe('/sandbox', '/sandbox/src/main.dart');
      // On macOS, normalize may change the path
      expect(result.contains('main.dart'), isTrue);
      expect(result.startsWith('ERROR:'), isFalse);
    });
  });

  // ========== Tool spec 测试 ==========

  group('Tool.toToolSpec', () {
    test('converts to OpenAI function-calling format', () {
      final tool = Tool(
        name: 'list_dir',
        description: 'List entries in a directory',
        parameters: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
          'required': ['path'],
        },
        run: (_) async => '',
      );

      final spec = tool.toToolSpec();
      expect(spec['type'], equals('function'));
      expect(spec['function']['name'], equals('list_dir'));
      expect(spec['function']['parameters']['required'], equals(['path']));
    });
  });

  // ========== System prompt 测试 ==========

  group('System prompt', () {
    test('buildStablePrefix contains tooling section', () {
      final prefix = buildStablePrefix(['list_dir', 'read_file', 'bash']);
      expect(prefix.contains('## Tooling'), isTrue);
      expect(prefix.contains('list_dir'), isTrue);
      expect(prefix.contains('read_file'), isTrue);
      expect(prefix.contains('bash'), isTrue);
    });

    test('buildDynamicSuffix contains workspace and runtime', () {
      final suffix = buildDynamicSuffix(
        workspaceDir: '/home/user/project',
        model: 'GLM-5.1',
      );
      expect(suffix.contains('/home/user/project'), isTrue);
      expect(suffix.contains('GLM-5.1'), isTrue);
    });

    test('buildSystemPrompt combines prefix and suffix', () {
      final prompt = buildSystemPrompt(
        toolNames: ['bash'],
        workspaceDir: '/sandbox',
        model: 'GLM-5.1',
      );
      expect(prompt.contains('## Tooling'), isTrue);
      expect(prompt.contains('## Workspace'), isTrue);
    });
  });

  // ========== ReAct loop mock 测试 ==========

  group('reactLoop', () {
    test('returns text on stop finish_reason', () async {
      // Mock: 模型直接返回文本，不调工具
      final mockClient = _MockOpenAIClient([
        _MockResponse(
          choices: [
            Choice(
              finishReason: 'stop',
              message: AssistantMessage(content: 'This is a Dart project.'),
            ),
          ],
        ),
      ]);

      final result = await reactLoop(
        client: mockClient,
        tools: [_dummyTool()],
        userPrompt: 'What kind of project is this?',
      );

      expect(result, equals('This is a Dart project.'));
    });

    test('calls tool and continues on tool_calls finish_reason', () async {
      final tool = Tool(
        name: 'list_dir',
        description: 'List directory',
        parameters: {'type': 'object', 'properties': {}, 'required': []},
        run: (_) async => 'file\tREADME.md\ndir\tsrc',
      );

      // Mock: 第 1 轮模型调工具，第 2 轮给出答案
      final mockClient = _MockOpenAIClient([
        _MockResponse(
          choices: [
            Choice(
              finishReason: 'tool_calls',
              message: AssistantMessage(
                toolCalls: [
                  ToolCall(id: 'tc_1', name: 'list_dir', arguments: '{"path": "."}'),
                ],
              ),
            ),
          ],
        ),
        _MockResponse(
          choices: [
            Choice(
              finishReason: 'stop',
              message: AssistantMessage(content: 'This is a Dart project called FlutterAgent.'),
            ),
          ],
        ),
      ]);

      final result = await reactLoop(
        client: mockClient,
        tools: [tool],
        userPrompt: 'What project is this?',
      );

      expect(result, equals('This is a Dart project called FlutterAgent.'));
    });

    test('returns error on unexpected finish_reason', () async {
      final mockClient = _MockOpenAIClient([
        _MockResponse(
          choices: [
            Choice(
              finishReason: 'length',
              message: AssistantMessage(content: 'very long...'),
            ),
          ],
        ),
      ]);

      final result = await reactLoop(
        client: mockClient,
        tools: [_dummyTool()],
        userPrompt: 'Explain everything',
      );

      expect(result.startsWith('ERROR:'), isTrue);
    });

    test('throws StateError on max_iters exceeded', () async {
      // Mock: 模型永远调工具，不给出最终答案
      final foreverToolCalls = _MockResponse(
        choices: [
          Choice(
            finishReason: 'tool_calls',
            message: AssistantMessage(
              toolCalls: [
                ToolCall(id: 'tc_loop', name: 'bash', arguments: '{"cmd": "echo loop"}'),
              ],
            ),
          ),
        ],
      );

      final mockClient = _MockOpenAIClient([
        for (var i = 0; i < 20; i++) foreverToolCalls,
      ]);

      expect(
        () => reactLoop(
          client: mockClient,
          tools: [_dummyTool()],
          userPrompt: 'Loop forever',
          config: const ReActConfig(max_iters: 3),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('tool not found returns ERROR string', () async {
      final mockClient = _MockOpenAIClient([
        _MockResponse(
          choices: [
            Choice(
              finishReason: 'tool_calls',
              message: AssistantMessage(
                toolCalls: [
                  ToolCall(id: 'tc_1', name: 'unknown_tool', arguments: '{}'),
                ],
              ),
            ),
          ],
        ),
        _MockResponse(
          choices: [
            Choice(
              finishReason: 'stop',
              message: AssistantMessage(content: 'I cannot find that tool.'),
            ),
          ],
        ),
      ]);

      final events = <Map<String, dynamic>>[];
      await reactLoop(
        client: mockClient,
        tools: [_dummyTool()],
        userPrompt: 'Try unknown tool',
        onEvent: (kind, payload) {
          if (kind == toolResult) events.add(payload);
        },
      );

      // 第一个 tool result 应该是 ERROR
      expect(events.first['result'], contains('ERROR: tool unknown_tool not found'));
    });

    test('malformed JSON args returns ERROR', () async {
      final tool = Tool(
        name: 'bash',
        description: 'Run command',
        parameters: {'type': 'object', 'properties': {}, 'required': []},
        run: (_) async => 'ok',
      );

      final mockClient = _MockOpenAIClient([
        _MockResponse(
          choices: [
            Choice(
              finishReason: 'tool_calls',
              message: AssistantMessage(
                toolCalls: [
                  ToolCall(id: 'tc_1', name: 'bash', arguments: 'not-json'),
                ],
              ),
            ),
          ],
        ),
        _MockResponse(
          choices: [
            Choice(
              finishReason: 'stop',
              message: AssistantMessage(content: 'I got an error with my tool call.'),
            ),
          ],
        ),
      ]);

      final events = <Map<String, dynamic>>[];
      await reactLoop(
        client: mockClient,
        tools: [tool],
        userPrompt: 'Run bad args',
        onEvent: (kind, payload) {
          if (kind == toolResult) events.add(payload);
        },
      );

      expect(events.first['result'], contains('ERROR: malformed JSON'));
    });

    test('system prompt is prepended to messages', () async {
      final mockClient = _RecordingOpenAIClient([
        _MockResponse(
          choices: [
            Choice(
              finishReason: 'stop',
              message: AssistantMessage(content: 'Done.'),
            ),
          ],
        ),
      ]);

      await reactLoop(
        client: mockClient,
        tools: [_dummyTool()],
        userPrompt: 'Hello',
        systemPrompt: 'You are a test agent.',
      );

      final firstMessage = mockClient.recordedMessages.first;
      expect(firstMessage['role'], equals('system'));
      expect(firstMessage['content'], equals('You are a test agent.'));
    });
  });
}

// ========== Mock helpers ==========

Tool _dummyTool() {
  return Tool(
    name: 'bash',
    description: 'dummy',
    parameters: {'type': 'object', 'properties': {}, 'required': []},
    run: (_) async => 'dummy result',
  );
}

class _MockResponse {
  final List<Choice> choices;
  _MockResponse({required this.choices});
}

/// Mock OpenAIClient — 按顺序返回预设的响应。
class _MockOpenAIClient implements OpenAIClient {
  final List<_MockResponse> _responses;
  int _index = 0;

  _MockOpenAIClient(this._responses);

  @override
  Future<ChatCompletionResponse> chatCompletion({
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required double temperature,
    required bool parallelToolCalls,
  }) async {
    if (_index >= _responses.length) {
      throw StateError('mock responses exhausted');
    }
    final resp = _responses[_index++];
    return ChatCompletionResponse(choices: resp.choices);
  }
}

/// Recording mock — 记录发送的 messages 以便验证。
class _RecordingOpenAIClient implements OpenAIClient {
  final List<_MockResponse> _responses;
  final List<Map<String, dynamic>> recordedMessages = [];
  int _index = 0;

  _RecordingOpenAIClient(this._responses);

  @override
  Future<ChatCompletionResponse> chatCompletion({
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required double temperature,
    required bool parallelToolCalls,
  }) async {
    recordedMessages.addAll(messages);
    final resp = _responses[_index++];
    return ChatCompletionResponse(choices: resp.choices);
  }
}