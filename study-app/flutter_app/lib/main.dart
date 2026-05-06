library;

/// FlutterAgent 桌面 app 入口。
///
/// 启动流程:
///   1. 读环境变量 OPENAI_API_KEY / OPENAI_BASE_URL
///   2. 沙箱目录默认 = 用户 home（学习场景；生产应该让用户选择）
///   3. 构造 AgentController 并交给 ChatScreen
///
/// 缺 API key 时显示一个引导页，告诉用户怎么设。

import 'dart:io' as io;

import 'package:flutter/material.dart';

import 'agent/agent_controller.dart';
import 'ui/chat_screen.dart';

void main() {
  runApp(const FlutterAgentApp());
}

class FlutterAgentApp extends StatelessWidget {
  const FlutterAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FlutterAgent',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.grey.shade50,
      ),
      home: const _Bootstrap(),
    );
  }
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  AgentController? _controller;
  String? _missingKey;
  late String _workspaceDir;
  static const _model = 'GLM-5.1';

  @override
  void initState() {
    super.initState();
    _workspaceDir = io.Platform.environment['HOME'] ??
        io.Platform.environment['USERPROFILE'] ??
        io.Directory.current.path;

    final key = readApiKeyFromEnv();
    if (key == null) {
      _missingKey = '未检测到 OPENAI_API_KEY 环境变量';
    } else {
      _controller = AgentController(
        workspaceDir: _workspaceDir,
        apiKey: key,
        baseUrl: readBaseUrlFromEnv(),
        model: _model,
      );
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null) {
      return _MissingKeyScreen(message: _missingKey ?? '初始化失败');
    }
    return ChatScreen(
      controller: _controller!,
      workspaceDir: _workspaceDir,
      model: _model,
    );
  }
}

/// 缺 API key 时的引导页。
class _MissingKeyScreen extends StatelessWidget {
  final String message;
  const _MissingKeyScreen({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.key_off, size: 56, color: Colors.orange),
              const SizedBox(height: 16),
              Text(message, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 24),
              const SelectableText(
                '请设置环境变量后重新启动:\n'
                '  export OPENAI_API_KEY="your-key"\n'
                '  export OPENAI_BASE_URL="https://open.bigmodel.cn/api/paas/v4"  # GLM\n\n'
                '然后从同一个 shell 运行:\n'
                '  cd study-app/flutter_app && flutter run -d macos',
                style: TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
