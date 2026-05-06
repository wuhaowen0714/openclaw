library;

/// ChatScreen — 主屏幕，纵向布局: 状态栏 + 消息列表 + 输入框。
///
/// 通过 StreamBuilder 订阅 AgentController.stream，每次 snapshot 变化
/// 整个 widget tree 重建（成本可控因为消息列表只增不变）。

import 'package:flutter/material.dart';

import '../agent/agent_controller.dart';
import '../agent/agent_state.dart';
import 'input_box.dart';
import 'message_list.dart';
import 'status_bar.dart';

class ChatScreen extends StatelessWidget {
  final AgentController controller;
  final String workspaceDir;
  final String model;

  const ChatScreen({
    super.key,
    required this.controller,
    required this.workspaceDir,
    required this.model,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FlutterAgent'),
        backgroundColor: Colors.blueGrey.shade50,
        elevation: 1,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 6),
            child: Row(
              children: [
                Text(
                  'workspace: $workspaceDir',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(width: 16),
                Text(
                  'model: $model',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
        ),
      ),
      body: StreamBuilder<AgentSnapshot>(
        stream: controller.stream,
        initialData: controller.snapshot,
        builder: (context, snap) {
          final s = snap.data ?? AgentSnapshot.empty;
          final running = s.phase == AgentPhase.loading ||
              s.phase == AgentPhase.streaming ||
              s.phase == AgentPhase.toolExecuting;

          return Column(
            children: [
              StatusBar(snapshot: s),
              Expanded(child: MessageList(messages: s.messages)),
              InputBox(
                enabled: !running,
                onSubmit: (text) => controller.submit(text),
              ),
            ],
          );
        },
      ),
    );
  }
}
