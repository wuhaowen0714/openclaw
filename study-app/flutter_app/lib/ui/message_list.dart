library;

/// MessageList — 滚动的消息列表，按类型分发到不同 widget。
///
/// 用户消息: 右对齐蓝色气泡
/// 助手消息: 左对齐灰色气泡
/// 工具调用: ToolCallCard

import 'package:flutter/material.dart';

import '../agent/agent_state.dart';
import 'tool_call_card.dart';

class MessageList extends StatefulWidget {
  final List<ChatMessage> messages;
  const MessageList({super.key, required this.messages});

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  final _scrollCtrl = ScrollController();

  @override
  void didUpdateWidget(covariant MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.messages.length != oldWidget.messages.length) {
      // 新消息到了，自动滚到底部
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '输入一个任务开始对话\n例如: 看看当前目录是什么项目',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: widget.messages.length,
      itemBuilder: (context, i) => _buildMessage(widget.messages[i]),
    );
  }

  Widget _buildMessage(ChatMessage m) {
    return switch (m) {
      UserMessage() => _bubble(m.text, isUser: true),
      AssistantMessage() => _bubble(m.text, isUser: false),
      ToolCallEntry() => ToolCallCard(entry: m),
    };
  }

  Widget _bubble(String text, {required bool isUser}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: const BoxConstraints(maxWidth: 600),
              decoration: BoxDecoration(
                color: isUser ? Colors.blue.shade100 : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                text,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
